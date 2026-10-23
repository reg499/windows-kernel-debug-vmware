# kd_state.ps1 — Run inside the guest. Reports whether kernel debugging is enabled / a debugger is attached.
#   Enabled=1 NotPresent=0  -> debugger attached
#   Enabled=1 NotPresent=1  -> debug boot, no debugger
#   Enabled=0               -> normal boot
param([string]$Out = '')
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class KdState {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int c, byte[] b, int l, out int r);
    public static string Get() {
        byte[] b = new byte[2]; int r;
        int st = NtQuerySystemInformation(35, b, 2, out r);   // SystemKernelDebuggerInformation
        return string.Format("status=0x{0:X} KernelDebuggerEnabled={1} KernelDebuggerNotPresent={2}", st, b[0], b[1]);
    }
}
'@
$r = @(
    [KdState]::Get()
    (cmd /c 'bcdedit /enum {current}' | Select-String 'description|debug' | Out-String).Trim()
    (cmd /c 'bcdedit /dbgsettings' | Select-String 'debugtype|hostip|port|busparams' | Out-String).Trim()
)
if ($Out) { $r | Out-File $Out -Encoding utf8 }
$r
