# 5. Case study: four host BSODs, and a GPU driver that wasn't guilty

I'm writing this one down because every clue pointed confidently in the wrong direction, and I nearly went off and replaced hardware.

## The setup at the time

- Host: a Windows desktop with a discrete graphics card, running VMware Workstation 17
- Guest: Windows 11, kernel debugging over a VMware virtual serial port mapped to a named pipe
- The debugger, `kd.exe`, wasn't started by me. An AI coding agent I was working with started it from its shell.

## What happened

The host crashed four times in about four hours:

1. `0x1000007E` (SYSTEM_THREAD_EXCEPTION_NOT_HANDLED) in the graphics card's HDMI audio driver. It was a write to address `0x1FE`, so a NULL pointer plus an offset.
2. `0x3B` (SYSTEM_SERVICE_EXCEPTION) in the graphics display driver, with `nt!ExAllocatePool2` on the stack.
3. A reset that looked like a power loss (Kernel-Power 41, no dump).
4. `0x116` (VIDEO_TDR_FAILURE) in the graphics display driver, with the third argument `c000009a`, which is STATUS_INSUFFICIENT_RESOURCES.

Every dump pointed at the graphics driver, so I updated it to the latest version. The next crash happened on the new driver.

## First clue: the timeline

VMware writes `vmware.log` in UTC, while the Windows event log uses local time, which hid the pattern for a while. Once I lined them up (times below are relative to the first line of each crash):

```
Crash A
T+0 s     vmx  serial0: Overrun
T+2 s     vmx  IOCTL_VMX86_GET_MEM_INFO failed: Insufficient system resources ...
T+3 s     host bugchecks

Crash B
T+0 s     kd   Opened \\.\pipe\kd_pipe ... Waiting to reconnect...
T+27 s    vmx  IOCTL_VMX86_GET_MEM_INFO failed: Insufficient system resources ...
T+28 s    host bugchecks (0x116, c000009a)
```

VM sessions without a debugger never had these lines.

Then I went back to the dumps. `ExAllocatePool2` on the stack, a write to NULL plus an offset, and `c000009a` all mean the same thing: something asked for memory and didn't get it. Graphics drivers allocate memory all the time, so they were simply first in line when the kernel ran out.

## Second clue: actually measuring it

So I wrote a small watchdog (it's [`scripts/host/watchdog.ps1`](../scripts/host/watchdog.ps1) now). Every 100 ms it reads the kernel pool sizes via `GetPerformanceInfo`. Once a second it logs the biggest pool tags via `NtQuerySystemInformation(SystemPoolTagInformation)`. If non-paged pool gets too big, it kills the debugger and the VM before the host goes down.

With that running, I repeated the exact same setup:

```
T+0.0 s  NP=548 MB    guest in debug boot, no debugger: flat
T+1.0 s  NP=989 MB    kd opens the pipe           Irp =339 MB  NpFr=74 MB
T+2.0 s  NP=1971 MB                                Irp =1077 MB NpFr=234 MB
T+2.1 s  threshold crossed: kd and vmware-vmx killed
T+4.1 s  NP=474 MB    memory released, host still up
```

About a gigabyte per second of non-paged pool, almost all of it tagged `Irp ` (I/O request packets) and `NpFr` (named pipe data entries). Without the watchdog, the host would have been out of memory in 15 to 30 seconds, which matched the crashes.

## My first theory was wrong

The obvious suspect was the serial pipe: some runaway I/O loop between VMware's end of the pipe and kd's end. So I removed the serial port entirely and moved to KDNET.

The watchdog fired again. Same tags, and this time the guest wasn't even in debug mode. So the pipe wasn't the cause.

## Narrowing it down

What changed the outcome was *how kd was started*:

- Started from the agent's shell (`& kd.exe ...` inside a background PowerShell), with the serial pipe and a debug boot: about 1 GB/s of non-paged pool.
- Started the same way, with KDNET and the guest in a *normal* boot: the same explosion.
- Started with `Start-Process` in its own console window, no VM: flat at 412 MB.
- Started with `Process.Start` and its own redirected stdin, no VM: flat at 413 MB.
- Me, using the WinDbg UI over KDNET while connected: flat at around 575 MB.
- The agent again, this time launching kd with `Start-Process` in its own console, over KDNET: three sessions, connected and ran commands each time, flat at 576 to 579 MB.

So the trigger was `kd.exe` running attached to the agent's shell. Something about the stdin/stdout it inherited there made it pile up pending I/O requests until the kernel ran out of memory. The same kd.exe in its own console was perfectly fine.

I didn't track down the exact mechanism. Once I had a safe, tested alternative, deliberately exhausting kernel memory again to dig deeper didn't seem worth the risk. If you know what's going on here, I'd really like to hear it; please open an issue.

## What I took away from it

- **A minidump names the victim, not the culprit.** If different drivers keep crashing on failed allocations (`c000009a`, writes to NULL plus an offset, `ExAllocatePool*` on the stack), suspect pool exhaustion and go measure the pool.
- **Line up your clocks.** VMware logs are in UTC.
- **Measure before you theorize.** A 100 ms pool sampler with tag names turned four mystery crashes into one very obvious graph.
- **Test a theory by removing the suspect.** My first theory failed that test, and I'm glad I ran it before writing anything down.
- **Automation needs its own rules.** A tool that behaves when a person runs it can misbehave when a script or an agent runs it. That's what [docs/06](06-automation-and-ai-agents.md) is about.

Next: [6. Automating it](06-automation-and-ai-agents.md)
