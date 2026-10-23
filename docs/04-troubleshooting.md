# 4. Troubleshooting

All of these happened to me at some point during this setup.

### 4.1 The debugger sits at "Waiting to reconnect..."

I'd check these in order:

1. Is the guest actually booted into the debug entry? In the guest, `bcdedit /enum '{current}'` should say `description Win11 KDebug` and `debug Yes`.
2. Is the debug type still NET? Run `bcdedit /dbgsettings`. If it says Serial, COM1, 115200, read [4.3](#43-startup-repair-silently-resets-kdnet-to-serial).
3. Is the key exactly the same on both sides? A wrong key doesn't give an error. It just never connects.
4. Is something else already using UDP port 50000 on the host? `Get-NetUDPEndpoint -LocalPort 50000`. Only one debugger can listen at a time.
5. Can the guest reach the host? `ping <HOST_IP>` from the guest.
6. The firewall. See the end of [docs/02](02-setup-kdnet-vmware.md#a-note-on-the-firewall).
7. Was the guest already running when you started the debugger? Attaching late is hit-and-miss for me. Start the debugger first, then reboot the guest into the debug entry.

If you see "Connected to target ..." but never "Kernel Debugger connection established", the network is fine but the kernel session didn't start. Reboot the guest into the debug entry while the debugger waits.

### 4.2 The VM is stuck on the Windows logo

If the debugger connected and broke in, the guest is paused on purpose. Type `g` in the debugger. You can tell it's a break-in and not a hang because the debugger shows a `kd>` prompt and VMware Tools stops answering (every `vmrun` guest command times out).

### 4.3 Startup Repair silently resets KDNET to serial

This one cost me a while. After a couple of hard power-offs, the guest showed "Your device ran into a problem and couldn't be repaired. Click or press Enter to see other recovery options." I continued into Windows, everything looked normal, and the debugger never connected again.

Two interrupted boots in a row (`vmrun stop hard`, or a tool killing `vmware-vmx.exe` mid-boot) make Windows run Startup Repair on the next start. Its report in `C:\Windows\System32\LogFiles\Srt\SrtTrail.txt` said "Number of root causes = 0", and every disk test passed. So nothing was actually broken. But afterwards `bcdedit /dbgsettings` was back to Serial, COM1, 115200.

To fix it:

1. In the VM console, press Enter, then Continue > Exit and continue to Windows 11.
2. Put the KDNET settings back, with the same key (no `newkey`, or you'll have to update the host too):
   ```bat
   bcdedit /dbgsettings net hostip:<HOST_IP> port:50000 key:<KEY>
   bcdedit /set {dbgsettings} busparams <BUSPARAMS>
   ```
   `scripts/guest/setup_kdnet.ps1 -Reapply` does the same.
3. Stop hard-resetting the VM. Use `shutdown /r` in the guest or `vmrun stop soft`, or revert to your post-setup snapshot.

### 4.4 "The value is protected by Secure Boot policy"

You get this from `bcdedit /debug on` when Secure Boot is on. Turn it off in VM > Settings > Options > Advanced, with the VM powered off.

### 4.5 BitLocker asks for the recovery key after a boot-config change

Suspend it before you touch the boot config: `manage-bde -protectors -disable C: -RebootCount 1`.

### 4.6 kdnet.exe says no NIC is supported

Use vmxnet3 if the guest is Windows 11 build 26006 or newer, e1000e otherwise. Also make sure `VerifiedNICList.xml` is in the same folder as `kdnet.exe`.

### 4.7 The host blue-screens, and the dump blames the GPU driver

Read [docs/05](05-case-study-host-bsod.md). In short: the host ran out of kernel memory within seconds, and the GPU driver just happened to be the first thing that couldn't allocate. Updating the driver didn't change anything.

### 4.8 After a host crash, the main monitor stays black

Windows thought the monitor was on and running normally, but the monitor got no signal. What to try, in order:

1. Win + Ctrl + Shift + B, which restarts the graphics driver.
2. Turn the monitor off and on, and check its input source.
3. Unplug and replug the cable at the GPU end.
4. Win + P > Duplicate, to get a picture on another screen in the meantime.

### 4.9 vmrun calls from PowerShell fail for no obvious reason

Windows PowerShell 5.1 silently drops empty string arguments when it calls a native program. `vmrun runScriptInGuest <vmx> '' 'cmd'` (an empty interpreter means `cmd.exe /c`) then breaks. Pass `'""'` instead.

Another one: `powershell -File script.ps1 -Arr 'a','b'` passes a single string, `a,b`, not an array. Use one string separated by semicolons, or read the values from a file.

### 4.10 Backslashes disappear in Bash-based tooling

Some automation shells collapse `\\` to `\` in heredocs and `printf`. `\\.\pipe\x` becomes `\.\pipe\x`, and `\$` gets eaten. If a script contains Windows paths, save it as a file with an editor (or your tool's file-writing function) and run it with `powershell -File`.

### 4.11 vmrun captureScreen hangs

It needs VMware Tools running in the guest. If the guest is broken in or sitting in a recovery screen, look at the VMware window instead.

### 4.12 Snapshot fails with "Authentication for encrypted virtual machine failed"

The VM is encrypted and running. Power it off first.

### 4.13 Host kernel memory creeps up over hours

If paged and non-paged pool slowly grow over hours, and the biggest tags are `File`, `MmSt`, `MmCa`, `NtfF` or `FMfn`, that's file-system activity: builds, git, lots of shells. It's not the debugger. A user-mode handle leak in some unrelated utility can look similar; `Get-Process | Sort HandleCount -Desc` will show it.

The debugger problem from docs/05 looks completely different: hundreds of megabytes per *second*, almost all of it in the `Irp ` and `NpFr` tags.

Next: [5. Case study](05-case-study-host-bsod.md)
