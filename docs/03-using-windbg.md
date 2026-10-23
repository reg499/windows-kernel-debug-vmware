# 3. Using WinDbg

This isn't a full WinDbg tutorial. It's the set of commands I actually use, plus a couple of things I wish someone had told me earlier.

## Getting started

```
.sympath srv*C:\symbols*https://msdl.microsoft.com/download/symbols
.reload
vertarget
```

The first line points WinDbg at Microsoft's symbol server and caches everything in `C:\symbols`. For your own driver, add its PDB folder with `.sympath+ C:\path\to\pdbs`. If symbols won't load, `!sym noisy` followed by `.reload` shows you where it's looking and why it fails.

## Running and stopping

- `g` continues.
- Ctrl+Break in WinDbg (or starting kd with `-b`) breaks in.
- `p` steps over, `t` steps into, `gu` runs until the current function returns.
- `bp <address or symbol>` sets a breakpoint. The module has to be loaded already.
- `bu MyDriver!SomeFunction` sets a *deferred* breakpoint, which resolves when the module loads. For drivers this is usually what you want.
- `bp X ".echo hit; k; gc"` runs commands when the breakpoint hits, then keeps going. Good for logging without stopping.
- `ba e1 <addr>`, `ba w4 <addr>`, `ba r4 <addr>` are hardware breakpoints on execute, write or read.
- `bl` lists breakpoints, `bc *` clears them all, `bd 0` disables number 0.
- `sxe ld:MyDriver.sys` breaks as soon as that driver loads. `sxd ld` turns that off again.

## Looking around

- `lm` lists modules. `lm m nt` shows one, `lmvm MyDriver` shows details.
- `k` (or `kb`, `kv`, `kP`) shows the call stack. `r` shows registers.
- `u <addr>` disassembles; `uf <function>` does the whole function.
- `dd`, `dq`, `db` and `du` dump memory as dwords, qwords, bytes or Unicode.
- `dt nt!_EPROCESS <addr>` displays a structure.
- `x MyDriver!*` searches symbols. `ln <addr>` gives the nearest symbol to an address.
- `!process 0 0` lists processes. `!process <EPROCESS> 7` includes threads and stacks.
- `!thread <ETHREAD>` shows one thread.
- `!drvobj MyDriver 7` shows a driver object and its dispatch routines. `!devobj` and `!devstack` cover device objects.
- `!irp <addr>` decodes an IRP.
- `!pool <addr>` identifies a pool block. `!poolused 2` shows pool usage by tag.
- `!analyze -v` analyzes a bugcheck or exception. `!error <code>` explains an NTSTATUS or Win32 error code.

## Catching a driver as it loads

This is what I do most often:

```
sxe ld:MyDriver.sys
bu MyDriver!DriverEntry
g
```

When it stops, I look around with `k`, `r`, `lmvm MyDriver` and `!drvobj MyDriver 7`. When I'm done, `bc *` and `g`.

To load unsigned test drivers you also need `bcdedit /set testsigning on` in the guest and a reboot. Secure Boot has to be off for that too, which it already is if you followed the setup.

## The boot-time break is really early

This confused me the first time. If the debugger connects during boot with `-b`, it stops a fraction of a second after the kernel starts, in `nt!DebugService2`, with an uptime under a second. At that point `!process 0 0` just says "NULL value in PsActiveProcess List", and almost no drivers are loaded.

That's actually the perfect moment to set `bu` and `sxe ld:` breakpoints. It's a useless moment for looking at system state. If that's what you want, hit `g`, let it boot, and break in again later.

## Crash dumps

If the guest bugchecks while the debugger is attached, the debugger stops right there and you can run `!analyze -v`, `k` and `.bugcheck`.

If nothing was attached, the guest writes `C:\Windows\MEMORY.DMP` or a minidump in `C:\Windows\Minidump\`. Copy it to the host (`vmrun copyFileFromGuestToHost` works) and open it:

```powershell
cdb.exe -z C:\dumps\guest.dmp -y "srv*C:\symbols*https://msdl.microsoft.com/download/symbols" -c "!analyze -v; q"
```

Dump analysis doesn't talk to a live machine, so it's safe to script.

## Ending a session

Clear your breakpoints (`bc *`), type `g`, and only then close the debugger. The guest keeps running.

If you close the debugger while the guest is broken in, the guest stays frozen until a debugger connects again and sends `g`.

Next: [4. Troubleshooting](04-troubleshooting.md)
