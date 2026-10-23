# watchdog.ps1 — Host kernel-memory watchdog for kernel-debugging experiments.
#
# Samples non-paged pool, paged pool, available RAM and commit every 100 ms.
# Logs once per second, including the top non-paged pool tags.
# If a threshold is crossed it kills the debugger (kd / WinDbg engine) and the VM process,
# so the host survives a runaway kernel-memory leak. See docs/05 and docs/06.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\host\watchdog.ps1 [-MaxSeconds 3600]
# Stop:   create the file given by -StopFile (default: <LogDir>\watchdog.stop)
param(
    [int]$TripNonPagedMB = 0,      # 0 = auto: start value + 1536 MB
    [int]$TripPagedMB    = 0,      # 0 = auto: start value + 3072 MB
    [int]$TripAvailMB    = 1024,   # trip if available RAM drops below this
    [int]$MaxSeconds     = 3600,
    [string]$LogDir      = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'logs'),
    [string]$Log         = '',
    [string]$StopFile    = '',
    [string[]]$KillOnTrip = @('kd', 'EngHost', 'DbgX.Shell', 'vmware-vmx')
)

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
if (-not $Log)      { $Log      = Join-Path $LogDir ('watchdog_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date)) }
if (-not $StopFile) { $StopFile = Join-Path $LogDir 'watchdog.stop' }

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class KMem {
    [StructLayout(LayoutKind.Sequential)]
    public struct PERF_INFO {
        public uint cb;
        public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable,
                       SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize;
        public uint HandleCount, ProcessCount, ThreadCount;
    }
    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool GetPerformanceInfo(out PERF_INFO pi, uint cb);
    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int retLen);

    // [0]=non-paged MB, [1]=paged MB, [2]=available MB, [3]=commit MB, [4]=handles
    public static double[] Snap() {
        PERF_INFO p;
        GetPerformanceInfo(out p, (uint)Marshal.SizeOf(typeof(PERF_INFO)));
        double pg = (double)p.PageSize.ToUInt64() / 1048576.0;
        return new double[] {
            p.KernelNonpaged.ToUInt64() * pg, p.KernelPaged.ToUInt64() * pg,
            p.PhysicalAvailable.ToUInt64() * pg, p.CommitTotal.ToUInt64() * pg, p.HandleCount };
    }

    // SystemPoolTagInformation (22). x64: 8-byte header, 40-byte entries, NonPagedUsed at +32.
    public static string TopNonPaged(int n) {
        int len = 1 << 20; IntPtr buf = IntPtr.Zero; int ret = 0, st = 0;
        for (int i = 0; i < 6; i++) {
            buf = Marshal.AllocHGlobal(len);
            st = NtQuerySystemInformation(22, buf, len, out ret);
            if (st == 0) break;
            Marshal.FreeHGlobal(buf); buf = IntPtr.Zero; len = Math.Max(len * 2, ret + 65536);
        }
        if (buf == IntPtr.Zero) return "pooltag-error 0x" + st.ToString("X");
        try {
            int count = Marshal.ReadInt32(buf);
            var list = new List<KeyValuePair<string, long>>();
            for (int i = 0; i < count; i++) {
                IntPtr e = IntPtr.Add(buf, 8 + i * 40);
                byte[] t = new byte[4]; Marshal.Copy(e, t, 0, 4);
                list.Add(new KeyValuePair<string, long>(
                    System.Text.Encoding.ASCII.GetString(t).Replace('\0', ' '), Marshal.ReadInt64(e, 32)));
            }
            list.Sort((a, b) => b.Value.CompareTo(a.Value));
            var sb = new System.Text.StringBuilder();
            for (int i = 0; i < Math.Min(n, list.Count); i++)
                sb.AppendFormat("{0}={1:N0}MB ", list[i].Key, list[i].Value / 1048576.0);
            return sb.ToString();
        } finally { Marshal.FreeHGlobal(buf); }
    }
}
'@

function W($s) { $line = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $s; Add-Content -Path $Log -Value $line; $line }
function ProcMB($name) {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($p) { '{0:N0}MB/h{1}' -f (($p | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB), (($p | Measure-Object HandleCount -Sum).Sum) } else { '-' }
}

Remove-Item $StopFile -ErrorAction SilentlyContinue
$base = [KMem]::Snap()
if ($TripNonPagedMB -le 0) { $TripNonPagedMB = [int]$base[0] + 1536 }
if ($TripPagedMB -le 0)    { $TripPagedMB    = [int]$base[1] + 3072 }
W ("START trip: NP>{0}MB or paged>{1}MB or avail<{2}MB | base NP={3:N0}MB paged={4:N0}MB avail={5:N0}MB" -f $TripNonPagedMB, $TripPagedMB, $TripAvailMB, $base[0], $base[1], $base[2])
if ($base[2] -lt 12288) { W ("WARNING: available RAM {0:N0} MB < 12 GB. Starting a VM may leave little headroom." -f $base[2]) }
W ("base tags: " + [KMem]::TopNonPaged(8))

$sw = [Diagnostics.Stopwatch]::StartNew()
$lastSec = -1
while ($sw.Elapsed.TotalSeconds -lt $MaxSeconds) {
    if (Test-Path $StopFile) { W 'stop file found, exiting'; break }
    $s = [KMem]::Snap()
    if ($s[0] -gt $TripNonPagedMB -or $s[1] -gt $TripPagedMB -or $s[2] -lt $TripAvailMB) {
        W ("!!! TRIPPED NP={0:N0}MB paged={1:N0}MB avail={2:N0}MB" -f $s[0], $s[1], $s[2])
        Stop-Process -Name $KillOnTrip -Force -ErrorAction SilentlyContinue
        W ("killed: {0} | tags: {1}" -f ($KillOnTrip -join ', '), [KMem]::TopNonPaged(10))
        Start-Sleep -Seconds 2
        $a = [KMem]::Snap()
        W ("2 s later NP={0:N0}MB avail={1:N0}MB | tags: {2}" -f $a[0], $a[2], [KMem]::TopNonPaged(6))
        break
    }
    $sec = [int][Math]::Floor($sw.Elapsed.TotalSeconds)
    if ($sec -ne $lastSec) {
        $lastSec = $sec
        W ("NP={0,6:N0} paged={1,6:N0} avail={2,7:N0} commit={3,7:N0} handles={4:N0} | vmx={5} dbg={6} | {7}" -f $s[0], $s[1], $s[2], $s[3], $s[4], (ProcMB 'vmware-vmx'), (ProcMB 'kd'), [KMem]::TopNonPaged(5))
    }
    Start-Sleep -Milliseconds 100
}
W 'END'
