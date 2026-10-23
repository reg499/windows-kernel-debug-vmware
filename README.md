# Kernel debugging a Windows 11 VM in VMware with KDNET

These are my notes from setting up live kernel debugging of a Windows 11 guest in VMware Workstation, with WinDbg running on the Windows host. I wrote them up because getting there took longer than it should have, and most of what I hit isn't covered in one place.

It wasn't a smooth ride. My host blue-screened four times. Every dump blamed the graphics driver, so I updated it, and the next crash happened on the new driver anyway. My first theory about the real cause turned out to be wrong too. The second half of this repo is about how I tracked it down, because I think the method is more useful than the specific bug.

If you just want it working, here's the short version:

- Use KDNET over a second, host-only network adapter. Skip the virtual serial port.
- Make a copy of the boot entry for debugging and leave the normal one alone.
- Never run `bcdedit /debug` on the host. Only inside the VM.
- If anything other than you starts the debugger (a script, CI, an AI agent), don't run `kd.exe` attached to that process's shell. Start it in its own console. This one bit me hard; see [docs/05](docs/05-case-study-host-bsod.md).
- While you're experimenting, run something that watches kernel memory. Mine is in [`scripts/host/watchdog.ps1`](scripts/host/watchdog.ps1). It saved the host twice.

## What I used

- Host: Windows 10 or 11 with VMware Workstation 17, Debugging Tools for Windows from a current Windows SDK, and the new WinDbg
- Guest: Windows 11 x64, 24H2 or later (needed for KDNET on vmxnet3, see docs/01)
- KDNET over a vmxnet3 adapter on VMware's host-only network (VMnet1)

I haven't tried other hypervisors.

## The docs

1. [Which method, and why](docs/01-why-and-options.md). The usual ways to kernel-debug Windows, and why I ended up on KDNET for a VM.
2. [Setup, step by step](docs/02-setup-kdnet-vmware.md). The part most people want.
3. [Using WinDbg](docs/03-using-windbg.md). Symbols, breakpoints, catching a driver as it loads, dumps.
4. [Troubleshooting](docs/04-troubleshooting.md). Everything that went wrong for me, and the fix.
5. [Case study: four host BSODs](docs/05-case-study-host-bsod.md). How I found the real cause when the dumps pointed somewhere else.
6. [Automating it (scripts, CI, AI agents)](docs/06-automation-and-ai-agents.md). How I let an agent run debug sessions without taking the host down again.

## Scripts

All PowerShell. Host scripts read their settings from `config.local.ps1`, a copy of [`config.example.ps1`](config.example.ps1) with your values. It's in `.gitignore` because it holds your VM password and KDNET key.

On the host:
- `scripts/host/watchdog.ps1` samples kernel pool usage every 100 ms and kills the debugger and the VM if it starts running away.
- `scripts/host/kd_session.ps1` runs one scripted `kd` session over KDNET and exits. This is what I let automation use.
- `scripts/host/vm_debug_boot.ps1` reboots the VM once into the debug entry and checks that it came up right.

In the guest:
- `scripts/guest/setup_kdnet.ps1` creates the debug boot entry and configures KDNET. It can also put the settings back when Windows resets them (it did, see [docs/04](docs/04-troubleshooting.md#43-startup-repair-silently-resets-kdnet-to-serial)).
- `scripts/guest/kd_state.ps1` tells you whether a kernel debugger is enabled and attached.

## Quick version

If you've done this before:

1. Power the VM off and take a snapshot.
2. In VMware: add a second network adapter set to host-only (vmxnet3), turn off Secure Boot, and I'd also turn off 3D acceleration.
3. Boot the guest, copy `kdnet.exe` and `VerifiedNICList.xml` over from the host's Debuggers folder, run `kdnet.exe` and write down the busparams of the host-only adapter.
4. In the guest, as admin: `scripts\guest\setup_kdnet.ps1 -HostIp <host VMnet1 IP> -BusParams <b.d.f>`. Save the key it prints.
5. On the host: WinDbg, File > Attach to kernel > Net, port 50000, paste the key.
6. Reboot the guest into "Win11 KDebug". WinDbg connects and breaks in. Type `g`.

## A word of caution

Kernel debugging freezes machines on purpose, and sometimes not on purpose. Use a VM you don't mind losing, keep snapshots, and leave your host's boot config alone. No warranty, see the licenses.

## License

Code (`scripts/`, `config.example.ps1`) is [MIT](LICENSE). The docs are [CC BY 4.0](LICENSE-DOCS.md).

If something here is wrong or out of date, please open an issue. I'd especially like to hear from anyone who knows *why* the problem in docs/05 happens.
