# kd_session.ps1 — One-shot, scripted kernel-debug session over KDNET. Safe for automation.
#
# - Refuses to run without a live watchdog, or if UDP <Port> / another debugger is busy.
# - Builds a command file: START marker + your commands + 'bc *' + DONE marker + 'g'.
# - Launches kd.exe with Start-Process in ITS OWN CONSOLE. Never attached to the caller's
#   stdin/stdout: that pattern exhausted host kernel memory (see docs/05).
# - Waits for the connection and the DONE marker, then closes kd. The target keeps running.
#
# Recommended order: start this first, then boot the guest into the debug entry
# (scripts\host\vm_debug_boot.ps1 -Mode debug).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\host\kd_session.ps1 -Commands 'vertarget; lm m nt'
#   powershell ... -File scripts\host\kd_session.ps1 -CommandFile my_commands.txt
# Exit codes: 0 ok | 2 no watchdog | 3 port/process conflict | 4 no connection | 5 command timeout
param(
    [string]$Commands    = 'vertarget',  # ONE string, ';'-separated (powershell -File flattens arrays)
    [string]$CommandFile = '',           # alternative: one kd command per line
    [int]$TimeoutSec     = 420,
    [string]$Log         = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'config.local.ps1')

$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$sessDir = Join-Path $Cfg.LogDir 'sessions'
New-Item -ItemType Directory -Force -Path $sessDir | Out-Null
if (-not $Log) { $Log = Join-Path $sessDir "kd_$stamp.log" }
$cmdFile = Join-Path $sessDir "kd_$stamp.cmd.txt"
function Say($m) { '{0:HH:mm:ss} {1}' -f (Get-Date), $m }

# 1) Pre-flight
$fresh = Get-ChildItem $Cfg.LogDir -Filter 'watchdog*.log' -ErrorAction SilentlyContinue |
         Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-5) }
if (-not $fresh) { Say 'ERROR: watchdog not running (no watchdog*.log updated in the last 5 s).'; exit 2 }
if (Get-NetUDPEndpoint -LocalPort $Cfg.Port -ErrorAction SilentlyContinue) { Say "ERROR: UDP $($Cfg.Port) already in use (close WinDbg?)."; exit 3 }
if (Get-Process kd, EngHost -ErrorAction SilentlyContinue) { Say 'ERROR: another kd/WinDbg engine is running.'; exit 3 }

# 2) Command file
$user = if ($CommandFile) { Get-Content -LiteralPath $CommandFile } else { @($Commands) }
@('.echo ===KD_SESSION_START===') + $user + @('bc *', '.echo ===KD_SESSION_DONE===', 'g') |
    Set-Content -Path $cmdFile -Encoding ASCII

# 3) Launch kd in its own console
$kdArgs = "-k net:port=$($Cfg.Port),key=$($Cfg.Key) -b -y `"$($Cfg.SymbolPath)`" -logo `"$Log`" -cf `"$cmdFile`""
$p = Start-Process -FilePath $Cfg.Kd -ArgumentList $kdArgs -WindowStyle Minimized -PassThru
Say "kd PID $($p.Id) started, log: $Log"

# 4) Wait
$deadline = (Get-Date).AddSeconds($TimeoutSec); $connected = $false; $done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($p.HasExited) { Say "kd exited unexpectedly (watchdog?) code $($p.ExitCode)"; break }
    $t = Get-Content $Log -Raw -ErrorAction SilentlyContinue
    if (-not $connected -and $t -match 'Kernel Debugger connection established') { $connected = $true; Say 'Connected.' }
    if ($t -match '===KD_SESSION_DONE===') { $done = $true; Start-Sleep -Seconds 2; break }
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Say 'kd closed (target keeps running).' }

if ($done)           { Say 'OK'; exit 0 }
if (-not $connected) { Say 'ERROR: no connection. Debug entry booted? dbgsettings NET? Same key? (docs/04 §4.1)'; exit 4 }
Say 'ERROR: commands timed out, see log.'; exit 5
