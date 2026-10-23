# vm_debug_boot.ps1 — Boot the VM once into the debug entry (or normally) and verify state.
#   -Mode debug  : re-apply KDNET settings (same key), set one-shot bootsequence, clean restart
#   -Mode normal : clean restart into the default (non-debug) entry
#   -Mode check  : just report state (VM must be running)
# Uses vmrun guest operations (needs VMware Tools in the guest).
# Note: if a debugger connects with break-in, the guest stops at the logo and Tools stop responding.
#       That is expected. The script then exits 3; the boot continues after the debugger sends 'g'.
param([ValidateSet('debug', 'normal', 'check')][string]$Mode = 'check', [int]$ReadyTimeoutSec = 300)

$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'config.local.ps1')
$guestDir = Join-Path $root 'scripts\guest'
$EMPTY = '""'   # Windows PowerShell 5.1 drops '' when calling native exes; vmrun needs an (empty) interpreter arg

function Say($m) { '{0:HH:mm:ss} {1}' -f (Get-Date), $m }
function VmArgs { if ($Cfg.VmPassword) { @('-vp', $Cfg.VmPassword) } else { @() } }
function G([string[]]$a) { & $Cfg.VmRun @(VmArgs) -gu $Cfg.GuestUser -gp $Cfg.GuestPass -T ws @a 2>&1 }
function Ready([int]$sec) {
    $end = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $end) { G 'runScriptInGuest', $Cfg.Vmx, $EMPTY, 'exit 0' | Out-Null; if ($LASTEXITCODE -eq 0) { return $true }; Start-Sleep 3 }
    $false
}
function Push($name) { G 'copyFileFromHostToGuest', $Cfg.Vmx, (Join-Path $guestDir $name), "$($Cfg.GuestWorkDir)\$name" | Out-Null }
function Report {
    Push 'kd_state.ps1'
    G 'runScriptInGuest', $Cfg.Vmx, $EMPTY, "powershell -NoProfile -ExecutionPolicy Bypass -File $($Cfg.GuestWorkDir)\kd_state.ps1 -Out $($Cfg.GuestWorkDir)\kd_state.txt" | Out-Null
    $local = Join-Path $Cfg.LogDir 'kd_state.txt'
    G 'copyFileFromGuestToHost', $Cfg.Vmx, "$($Cfg.GuestWorkDir)\kd_state.txt", $local | Out-Null
    Get-Content $local | Where-Object { $_.Trim() }
}

New-Item -ItemType Directory -Force -Path $Cfg.LogDir | Out-Null
if (-not ((& $Cfg.VmRun list) -match [regex]::Escape($Cfg.Vmx))) {
    Say 'VM is off, starting (nogui)...'
    & $Cfg.VmRun @(VmArgs) -T ws start $Cfg.Vmx nogui | Out-Null
}
if (-not (Ready 180)) { Say 'ERROR: guest not ready. Check the VM console (Startup Repair? docs/04 §4.3).'; exit 1 }
G 'createDirectoryInGuest', $Cfg.Vmx, $Cfg.GuestWorkDir | Out-Null

if ($Mode -eq 'check') { Report; exit 0 }

if ($Mode -eq 'debug') {
    Push 'setup_kdnet.ps1'
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $($Cfg.GuestWorkDir)\setup_kdnet.ps1 -Reapply " +
           "-HostIp $($Cfg.HostIp) -Port $($Cfg.Port) -Key $($Cfg.Key) -BusParams $($Cfg.BusParams) -EntryGuid $($Cfg.KDebugGuid) -BootOnce"
    G 'runScriptInGuest', $Cfg.Vmx, $EMPTY, $cmd | Out-Null
    Say 'KDNET settings re-applied, one-shot bootsequence = debug entry.'
}
Say 'Clean restart (shutdown /r)...'
G 'runScriptInGuest', $Cfg.Vmx, '-noWait', $EMPTY, 'shutdown /r /t 3' | Out-Null
Start-Sleep -Seconds 30
if (Ready $ReadyTimeoutSec) { Report; exit 0 }
Say 'Guest not ready yet. If a debugger is attached and broken in, this is expected.'
exit 3
