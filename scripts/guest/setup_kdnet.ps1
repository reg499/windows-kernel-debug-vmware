# setup_kdnet.ps1 — Run INSIDE THE GUEST, elevated.
#
# First-time setup (creates the "Win11 KDebug" entry and a NEW key):
#   .\setup_kdnet.ps1 -HostIp 192.168.150.1 -BusParams 27.0.0
#
# Re-apply after Startup Repair reset dbgsettings to serial (keeps your key):
#   .\setup_kdnet.ps1 -Reapply -HostIp ... -Key a.b.c.d -BusParams ... -EntryGuid {...} [-BootOnce]
#
# The default boot entry is always left with debugging OFF.
param(
    [Parameter(Mandatory)][string]$HostIp,
    [Parameter(Mandatory)][string]$BusParams,
    [int]$Port = 50000,
    [string]$Key = '',
    [string]$EntryGuid = '',
    [string]$EntryName = 'Win11 KDebug',
    [switch]$Reapply,
    [switch]$BootOnce,
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$log = New-Object System.Collections.Generic.List[string]
function Run([string]$cmdline) { $r = (cmd /c "bcdedit $cmdline" 2>&1 | Out-String).Trim(); $log.Add("> bcdedit $cmdline`n$r"); $r }

if ((Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) -eq $true) { throw 'Secure Boot is ON. Disable it in the VM settings first.' }

if (-not $Reapply) {
    $copy = Run "/copy {current} /d `"$EntryName`""
    if ($copy -notmatch '\{[0-9a-fA-F-]{36}\}') { throw "Could not create entry: $copy" }
    $EntryGuid = $Matches[0]
    Run "/timeout 10" | Out-Null
    $netArgs = "net hostip:$HostIp port:$Port newkey"
} else {
    if (-not $Key -or -not $EntryGuid) { throw '-Reapply needs -Key and -EntryGuid' }
    $netArgs = "net hostip:$HostIp port:$Port key:$Key"
}

Run "/dbgsettings $netArgs" | Out-Null
Run "/set {dbgsettings} busparams $BusParams" | Out-Null
Run "/debug $EntryGuid on" | Out-Null
$default = (cmd /c 'bcdedit /enum {bootmgr}' | Select-String 'default\s+(\S+)').Matches[0].Groups[1].Value
Run "/debug $default off" | Out-Null
if ($BootOnce) { Run "/bootsequence $EntryGuid" | Out-Null }

$summary = @(
    "Debug entry : $EntryGuid ($EntryName)"
    (cmd /c 'bcdedit /dbgsettings' | Out-String).Trim()
)
if ($Out) { ($summary + $log) | Out-File $Out -Encoding utf8 }
$summary
'Save the key and the entry GUID in config.local.ps1 on the host. Do not publish the key.'
