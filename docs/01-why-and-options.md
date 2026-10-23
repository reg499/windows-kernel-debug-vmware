# 1. Which method, and why

There are roughly five ways to debug the Windows kernel. Which one you want depends on whether you need to stop the machine and step through code, or just look at what went wrong.

**Crash dump analysis.** If you already have a `.dmp`, open it in WinDbg and run `!analyze -v`. It's the fastest way to start, and often all you need. You can't set breakpoints or step, though, because the machine is already dead.

**A VM as the target, debugged from the host.** This is what this repo covers. It's great for driver work and for learning, because you can snapshot, break things and roll back. The catch is that virtual hardware doesn't always behave like the real thing.

**Two physical PCs over Ethernet (KDNET).** The standard setup for bugs that only show up on real hardware. You need a second machine and a network card Microsoft supports for KDNET.

**Looking at the live kernel on the same machine** (LiveKd, or WinDbg's local kernel mode). Handy for a quick look. It's a snapshot, though: no breakpoints, and the data can shift under you while you read it.

**USB 3 debug cables or a serial null-modem.** For special hardware setups. USB debugging needs chipset support, and serial is painfully slow.

A few things that confused me at first:

- "WinDbg Preview" was renamed in 2023. There's now just **WinDbg** (from the Store or `winget install Microsoft.WinDbg`) and **WinDbg Classic**, which ships with the Windows SDK. Either works here.
- Time Travel Debugging only works in user mode. You can't use it for the kernel.
- FireWire (1394) kernel debugging isn't supported on current Windows anymore.
- Microsoft's public symbol server covers Windows itself. For your own driver you need your own PDBs.

## Why KDNET for a VMware VM

With a VMware guest you realistically have three choices.

A **virtual serial port mapped to a named pipe** is the old way. It's easy to set up and it does work, but at 115200 baud it's slow. It also happens to be what I was using when my host started crashing. It turned out not to be the cause (see [docs/05](05-case-study-host-bsod.md)), but I removed it anyway and haven't missed it.

**KDNET over the VM's network adapter** is what Microsoft recommends now, and it's much faster. VMware's `vmxnet3` adapter is on Microsoft's supported list for Windows 11 build 26006 and later. On older builds the emulated Intel `e1000e` (device 8086:10D3) works.

VMware also has a **gdb stub**, but that means gdb instead of WinDbg, so I didn't go there.

## A few choices I made, and why

**A separate host-only adapter just for KDNET.** When KDNET is active it takes over the adapter it's bound to. Giving it its own adapter on VMware's host-only network means the VM's normal networking keeps working. The debug traffic also stays off my LAN, and the host's address on that network doesn't change.

**A separate boot entry.** I copy the boot entry, turn debugging on only for the copy, and select it with `bcdedit /bootsequence`, which only applies to the next boot. If I mess something up, the next normal reboot brings back a regular Windows. I never end up with a VM that sits waiting for a debugger every time it starts.

**Nothing touches the host's boot config.** Every `bcdedit /debug` in this repo runs inside the guest.

**Snapshot and back up the `.vmx` before changing anything.** It takes ten seconds, and I used those backups more than once.

**Watch kernel memory while experimenting.** I only started doing this after the crashes. Docs [05](05-case-study-host-bsod.md) and [06](06-automation-and-ai-agents.md) explain why.

Next: [2. Setup, step by step](02-setup-kdnet-vmware.md)
