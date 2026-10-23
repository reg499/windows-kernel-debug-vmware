# 2. Setup, step by step

You'll need a Windows host with VMware Workstation 17, a Windows 11 x64 guest (24H2 or later), and a current Debugging Tools for Windows.

I use a few placeholders below. Swap in your own values:

- `<VMX>` is your VM's config file, e.g. `C:\VMs\Win11Test\Win11Test.vmx`
- `<HOST_IP>` is the host's address on VMware's host-only network (VMnet1), e.g. `192.168.150.1`
- `<BUSPARAMS>` is the PCI location of the guest's debug adapter, e.g. `27.0.0`
- `<KEY>` is the KDNET key the guest generates, four dot-separated parts
- `<KDEBUG_GUID>` is the GUID of the debug boot entry you'll create

## Step 0: before you start

Install **Debugging Tools for Windows** on the host. It's an optional component of the Windows SDK installer. It puts `kd.exe`, `cdb.exe`, `windbg.exe`, `kdnet.exe` and `VerifiedNICList.xml` into `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\`. I also installed the new WinDbg (`winget install Microsoft.WinDbg`) because its UI is nicer, but you don't strictly need it.

Make sure the **host** isn't in debug mode. In PowerShell on the host:

```powershell
bcdedit /enum '{current}'     # you want "debug  No", or no debug line at all
```

Don't ever turn kernel debugging on for the host itself. Everything here happens inside the VM.

Check your RAM, too. You need the guest's memory plus a few GB to spare, because VMware may lock the guest's memory.

If you use Git Bash, `bcdedit /enum {current}` fails with "The specified command line is not valid" because Bash mangles the braces. Run it from PowerShell with quotes instead.

## Step 1: snapshot and back up

Power the VM off, then:

```powershell
$vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
& $vmrun -T ws snapshot '<VMX>' 'before_kdebug'
Copy-Item '<VMX>' '<VMX>.bak-before-kdebug'
```

If your VM is encrypted (VMs with a vTPM are), every `vmrun` call needs `-vp <VM password>`. Snapshots of a running encrypted VM fail with "Authentication for encrypted virtual machine failed", so power it off first.

## Step 2: VMware settings

With the VM still off, open VM > Settings. I'd use the UI rather than editing the `.vmx`, especially for encrypted VMs.

1. **Add a network adapter** and set it to *Host-only*. VMware calls it `ethernet1`. It should be vmxnet3. On recent guest OS types that's the default; if not, set `ethernet1.virtualDev = "vmxnet3"` in the `.vmx`.
2. **Turn off Secure Boot** under Options > Advanced. With it on, Windows refuses `bcdedit /debug on` with "The value is protected by Secure Boot policy". Windows 11 needs Secure Boot to *install*, but runs fine without it afterwards.
3. **Turn off 3D acceleration** under Display. It's optional, but with 3D on, the guest's rendering goes through your host's GPU driver, and I didn't want the host GPU involved while debugging.
4. **Don't add a serial port.** KDNET doesn't need one.

When you're done, the `.vmx` should contain something like:

```
ethernet1.present = "TRUE"
ethernet1.connectionType = "hostonly"
ethernet1.virtualDev = "vmxnet3"
uefi.secureBoot.enabled = "FALSE"
```

If you do edit the `.vmx` by hand, back it up, keep the CRLF line endings, and make sure VMware doesn't have the VM open.

To find `<HOST_IP>`, run this on the host:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | ? InterfaceAlias -like '*VMnet1*'
```

## Step 3: find the debug adapter in the guest

Boot the guest normally. Copy `kdnet.exe` and `VerifiedNICList.xml` from the host's Debuggers folder into the guest, say into `C:\KDNET\`. Then run this from an elevated prompt in the guest:

```bat
cd C:\KDNET
kdnet.exe
```

You should get something like:

```
Network debugging is supported on the following NICs:
busparams=27.0.0, vmxnet3 Ethernet Adapter #2, Plugged in.
busparams=3.0.0, vmxnet3 Ethernet Adapter, Plugged in.
```

You want the host-only adapter. If you're not sure which one that is, look at the IP addresses: the host-only one is in the same subnet as `<HOST_IP>`. This one-liner shows each adapter's PCI location:

```powershell
Get-PnpDevice -Class Net -PresentOnly | % { "{0} | {1}" -f $_.FriendlyName, (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_LocationInfo).Data }
# "PCI bus 27, device 0, function 0" means busparams 27.0.0
```

While you're in the guest, `ping <HOST_IP>` to make sure the host answers.

## Step 4: configure KDNET and the debug boot entry (guest, elevated)

By hand:

```bat
:: copy the current entry, and note the GUID it prints
bcdedit /copy {current} /d "Win11 KDebug"

:: debugging on for the copy only
bcdedit /debug <KDEBUG_GUID> on
bcdedit /debug {current} off

:: KDNET settings. "newkey" generates a random key and prints it
bcdedit /dbgsettings net hostip:<HOST_IP> port:50000 newkey
bcdedit /set {dbgsettings} busparams <BUSPARAMS>

:: give yourself time to pick an entry at boot
bcdedit /timeout 10
```

Or run [`scripts/guest/setup_kdnet.ps1`](../scripts/guest/setup_kdnet.ps1), which does the same thing.

Write down the key (`Key=...`). You'll need it on the host, and you'll need it again if Windows ever resets these settings. Keep it out of anything you publish.

Check the result:

```bat
bcdedit /dbgsettings
bcdedit /enum OSLOADER
```

`dbgsettings` should show `debugtype NET`, your host IP, port 50000, the key and the busparams. The normal "Windows 11" entry should have no debug line, and "Win11 KDebug" should say `debug Yes`.

If BitLocker or device encryption is on in the guest, changing the boot config will make it ask for the recovery key on the next boot. Check with `manage-bde -status C:` and suspend it first: `manage-bde -protectors -disable C: -RebootCount 1`.

## Step 5: connect

Start the debugger first, then boot the guest into the debug entry. In my tests, connecting during boot worked every time. Attaching to a guest that was already running worked once after about 30 seconds and timed out once after three minutes.

1. On the host, start the debugger:
   - WinDbg: File > Attach to kernel > Net, port `50000`, key `<KEY>`, OK. It shows "Waiting to reconnect...".
   - Or kd in a console: `kd.exe -k net:port=50000,key=<KEY> -b`. The `-b` makes it break in as soon as it connects.
2. In the guest, boot once into the debug entry:
   ```bat
   bcdedit /bootsequence <KDEBUG_GUID>
   shutdown /r /t 0
   ```
   Or just pick "Win11 KDebug" from the boot menu.
3. About 30 seconds later the debugger should print:
   ```
   Connected to target 192.168.150.x on port 50000 on local IP <HOST_IP>.
   Connected to Windows 10 26100 x64 target ...
   Kernel Debugger connection established.
   ```
4. If it broke in, the VM will sit frozen at the Windows logo. That's normal: Windows is waiting for the debugger. Set up symbols and let it go:
   ```
   .sympath srv*C:\symbols*https://msdl.microsoft.com/download/symbols
   .reload
   vertarget
   g
   ```

`/bootsequence` only applies to the next boot, so the reboot after that goes back to the normal, non-debug entry.

## Step 6: check from inside the guest (optional)

[`scripts/guest/kd_state.ps1`](../scripts/guest/kd_state.ps1) asks Windows directly (`NtQuerySystemInformation`, class `SystemKernelDebuggerInformation`) and prints two flags:

- `KernelDebuggerEnabled=0`: normal boot, no debugging.
- `KernelDebuggerEnabled=1, KernelDebuggerNotPresent=1`: debug boot, but no debugger attached.
- `KernelDebuggerEnabled=1, KernelDebuggerNotPresent=0`: a debugger is attached.

## Step 7: take a new baseline snapshot

Once it all works, shut the VM down from the normal boot and take a fresh snapshot. I called mine "clean + KDNET". Revert to that one from now on. If you revert to an older snapshot, you'll most likely lose the second adapter and get Secure Boot back.

One gotcha: on an encrypted VM the snapshot file doesn't store the config in readable form, so you can't just grep it to see what's inside. To make sure a snapshot kept your settings, revert to it with the VM off and grep the live `.vmx`.

## A note on the firewall

The new WinDbg's engine (`EngHost.exe`) usually installs an inbound firewall rule that covers all network profiles. The SDK's `kd.exe` rule may only cover the Private profile. VMware's host-only adapter often has no network profile at all ("unidentified network"). In my case `kd.exe` connected anyway, but if you never see "Connected to target", this narrow rule should fix it (run as admin on the host):

```powershell
New-NetFirewallRule -DisplayName "KDNET VMnet1 kd.exe" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 50000 `
  -Program "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe" -InterfaceAlias "VMware Network Adapter VMnet1"
```

Next: [3. Using WinDbg](03-using-windbg.md)
