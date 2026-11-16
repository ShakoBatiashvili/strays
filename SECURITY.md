# Security

Strays has a Stop button, so its design goal is a **small, checkable trust footprint**. This document says what it
can do, what it cannot, how to verify that yourself, and how to report a problem.

## Reporting a vulnerability

Please report security issues **privately** through GitHub: on the repository's **Security** tab, choose
**Report a vulnerability**. Please do not open a public issue for anything exploitable.

This is a one-person project, so replies are best-effort, but reports are taken seriously. Only the latest release
is supported.

## What Strays can do

| Capability | How | Scope |
|---|---|---|
| List processes, their folders, arguments and listening TCP ports | `libproc` (`proc_pidinfo`, `proc_pidfdinfo`), `sysctl KERN_PROCARGS2` | Read-only. Full detail only for **your own** processes (the kernel's rule, not a setting) |
| Tell launchd services from orphans | Runs `/bin/launchctl list` by absolute path, fixed arguments, at most every 30 s | The **only** subprocess in the project |
| Read Claude Code session status and titles | `~/.claude/sessions/<pid>.json`; the first 256 KB and last 512 KB of that session's transcript, scanning only `custom-title` / `ai-title` / `summary` records | Read-only. The `.key` files next to the status files hold tokens and are **never opened** |
| Check whether a port speaks HTTP | One `HEAD / HTTP/1.0` to `127.0.0.1` or `::1`, 0.4 s timeout, once per port | Loopback only |
| Check whether a port is free | `bind()` on a throwaway socket, closed immediately | Local only |
| List and stop Docker containers | Docker Engine API over the local unix socket (`~/.docker/run/docker.sock`, OrbStack, Colima, `/var/run/docker.sock`, or `DOCKER_HOST=unix://…`) | Never over TCP. Container ids are checked to be hex before they go into a request path |
| Stop a process tree | `SIGTERM` to the tree (top first), then `SIGKILL` after a grace period (5 s by default) | See *Stopping* below |
| Show a terminal tab | A fixed AppleScript for Terminal or iTerm2 that selects the tab whose `tty` matches | The tty must match `^ttys[0-9]{1,4}$` before it is put in the script; macOS asks you once (Apple Events permission) |
| Save settings | `UserDefaults` domain `io.github.shakobatiashvili.strays` | Values are clamped on every load and save |
| Notify you | Local `UNUserNotificationCenter` notifications | Only the daily reminder |

## Stopping

- The set of processes is planned from **one fresh snapshot** taken when you confirm, and shown to you first (the
  CLI prints every PID; the app says how many).
- A target is refused if it belongs to another user, is one of Apple's processes (`/System`, `/usr/libexec`,
  `/usr/sbin`, `/sbin`), is Strays itself, or is an ancestor of Strays (so the CLI never stops the shell or AI
  session it runs in). Descendants owned by other users are skipped, not signalled.
- Immediately before **every** signal, the PID's start time (microseconds) and owner are re-read from the kernel
  and compared with the snapshot. A PID that was reused by a different process is never signalled.
- The CLI never stops anything without confirmation unless you pass `-y`, and refuses to guess when it has no
  terminal to ask on.

## What Strays does not do

- **No root and no privileged helper.** No `sudo`, no LaunchDaemon, no `SMJobBless`. "Open at login" is a standard
  per-user login item (`SMAppService.mainApp`), off by default.
- **No internet access.** No `URLSession`, no `Network.framework`, no WebKit, no DNS lookups, no update checker, no
  telemetry, no hard-coded URLs beyond `http(s)://localhost`.
- **No inter-process surface.** No custom URL scheme, no XPC, no listening sockets. The CLI and the app share only
  their settings.
- **No third-party code.** `Package.swift` has no dependencies.
- **No private APIs**, no `dlopen`, no Objective-C runtime tricks.
- **One entitlement**: `com.apple.security.automation.apple-events`, which hardened runtime requires for *Show
  terminal tab*. One privacy string, for the same feature. No Accessibility, Screen Recording, Full Disk Access.
- **No secrets on screen.** Command lines are passed through a redactor before they are shown, printed, put in
  JSON or in a notification. The only exception is *Copy full command line*, which copies your own process's
  exact arguments to your clipboard because you asked for them.
- **No build-machine details in binaries.** Debug symbols are stripped and `#file` is module-relative.

## Threat model

Strays runs with your user's rights and assumes your user account is not already compromised. What it defends
against is **its own mistakes**: stopping the wrong process (recycled PIDs, other users, macOS, itself), leaking
secrets from command lines into screenshots or logs, and growing a network or privilege surface over time.

It does not try to defend against a malicious process of yours that lies about itself (a process can rename its
own arguments). Strays shows what the kernel reports.

## Verify it yourself

```sh
make test     # 96 tests, including real processes being found, probed and stopped
make app
make audit    # greps the source and inspects the signed bundle for every claim above
```

`scripts/audit.sh` fails if network APIs, new subprocesses, new signal or AppleScript call sites, `.key` file
access, private APIs, dependencies, extra entitlements, privacy strings, bundled frameworks, URLs or home-folder
paths appear.
