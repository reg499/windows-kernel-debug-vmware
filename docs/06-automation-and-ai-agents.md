# 6. Automating it: scripts, CI and AI agents

I use AI coding agents for a lot of my work, and I wanted them to be able to run kernel-debug sessions on their own: set a breakpoint, boot the VM, collect a stack, report back. That works fine now. But after docs/05 I set some firm rules, and I wrote a small set of scripts so an agent (or a CI job, or me at 2 a.m.) doesn't have to remember them.

## The rules

1. **Never run `kd.exe` attached to the automation's own shell.** No `& kd.exe ...`, no `kd.exe ... &`, nothing that inherits the caller's stdin/stdout. Start it with `Start-Process` so it gets its own console. This is the one that crashed my host (docs/05).
2. **Run the watchdog during every live session.** It stopped two runaway sessions before they took the host down.
3. **Automation doesn't touch the host's security or boot settings**: no `bcdedit` on the host, no firewall rules, no group policy, no Secure Boot. If one of those needs changing, a human does it.
4. **Don't hard-reset the VM** (`vmrun stop hard`, killing `vmware-vmx`) unless it's an emergency. Two of those in a row put Windows into Startup Repair, which resets KDNET to serial ([docs/04, 4.3](04-troubleshooting.md#43-startup-repair-silently-resets-kdnet-to-serial)).
5. **No `.crash`, `.reboot`, or writing to memory or registers** unless the task really calls for it. It wrecks the state you're trying to look at.
6. **Don't try to reproduce the host memory exhaustion.** I know how to avoid it now, and reproducing it is just risky.
7. **When unsure, stop and ask a human.** That includes: the watchdog tripped, the host shows a new bugcheck, or the VM is stuck on a recovery screen.

## The flow that works

First, copy `config.example.ps1` to `config.local.ps1` and fill in your values. It's in `.gitignore`.

```powershell
# 1. Watchdog in the background. Its thresholds are relative to where memory starts.
Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File scripts\host\watchdog.ps1 -MaxSeconds 3600'

# 2. Start a one-shot kd session. It waits for the guest to connect.
#    Commands go in ONE string, separated by ';'. For longer lists use -CommandFile.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\host\kd_session.ps1 -Commands 'vertarget; lm m nt' -TimeoutSec 420

# 3. A few seconds later, in a separate call, reboot the guest once into the debug entry.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\host\vm_debug_boot.ps1 -Mode debug
```

`kd_session.ps1` does the following:

- It won't start unless the watchdog has written to its log in the last 5 seconds, UDP 50000 is free, and no other kd or WinDbg engine is running.
- It writes a command file: a start marker, your commands, `bc *`, a done marker, and `g`.
- It starts `kd.exe -k net:port=50000,key=... -b -logo <log> -cf <command file>` with `Start-Process`, minimized, in its own console.
- It waits for "Kernel Debugger connection established", then for the done marker, then closes kd. The guest keeps running.
- Exit codes: 0 means it worked, 2 means no watchdog, 3 means the port or another debugger was in the way, 4 means it never connected, 5 means the commands timed out.

The output you want is in the log between `===KD_SESSION_START===` and `===KD_SESSION_DONE===`.

In my runs, it connected about 30 seconds into the guest's boot, the commands took a few seconds, and the guest finished booting a minute or two after the `g`.

## The watchdog

Every 100 ms it reads non-paged pool, paged pool, free RAM and commit. Every second it logs those plus the biggest non-paged pool tags.

It trips when non-paged pool grows 1.5 GB past where it started, when paged pool grows 3 GB, or when free RAM drops under 1 GB. When it trips, it kills `kd`, `EngHost`, `DbgX.Shell` and `vmware-vmx`.

The thresholds are relative because "normal" moves around a lot. On a typical desktop non-paged pool might sit at a few hundred MB when idle and climb past a gigabyte after a day of heavy builds. A fixed 2 GB limit would have tripped for no reason.

It also warns at startup if you have less than 12 GB free, because an 8 GB VM won't leave much room. To stop it, create `watchdog.stop` next to its log.

What the debugger problem looks like, if you ever see it: non-paged pool climbing by hundreds of MB per second, with `Irp ` and `NpFr` as the top tags. Slow growth over hours with tags like `File`, `MmSt` or `NtfF` is just file-system activity.

## Limitations

- Sessions are one-shot. If you need to wait hours for a breakpoint to hit, this isn't the right tool; you'd want something like `kd -server` with clients connecting separately. I haven't built that.
- Attaching to a guest that's already running is unreliable. Boot into the debug entry while the session is waiting.
- I still don't know the exact mechanism behind rule 1. It comes from measurements, not from understanding.

## What I tell my agents

I paste something like this into the agent's instructions:

> Before doing any kernel-debug work, read docs/06-automation-and-ai-agents.md and docs/04-troubleshooting.md, and follow the rules in docs/06 exactly. Talk to the kernel debugger only through scripts/host/kd_session.ps1, and only while the watchdog is running. Revert the VM to the post-setup snapshot before you start. If the watchdog trips, the host shows a new bugcheck, or something needs a change to host security settings, stop and tell me.
