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
| Read Claude Code session status and titles | `~/.claude/sessions/<pid>.json`; the first 256 KB and last 512 KB of that session's transcript, scanning only `custom-title` / `ai-title` / `summary` records | Read-only, regular files only (a FIFO or device there is skipped, not read). The `.key` files next to the status files hold tokens and are **never opened** |
| Check whether a port speaks HTTP | One `HEAD / HTTP/1.0` to `127.0.0.1` or `::1`, 0.4 s timeout, once per port | Loopback only |
| Check whether a port is free | `bind()` on a throwaway socket, closed immediately | Local only |
| List and stop Docker containers | Docker Engine API over the local unix socket (`~/.docker/run/docker.sock`, OrbStack, Colima, `/var/run/docker.sock`, or `DOCKER_HOST=unix://…`) | Never over TCP. Container ids are checked to be hex before they go into a request path |
| Stop a process tree | `SIGSTOP`, `SIGTERM`, `SIGCONT`, then `SIGKILL` after a grace period (5 s by default) | See *Stopping* below |
| Show a terminal tab | A fixed AppleScript for Terminal or iTerm2 that selects the tab whose `tty` matches | The tty must match `^ttys[0-9]{1,4}$` before it is put in the script; macOS asks you once (Apple Events permission) |
| Save settings | `UserDefaults` domain `io.github.shakobatiashvili.strays` | Values are clamped on every load and save |
| Notify you | Local `UNUserNotificationCenter` notifications | Only the daily reminder |

## Stopping

- **What a stop covers.** The selected row's process and everything below it, *except* what is not part of that
  row: other rows (a dev server an AI session started is its own row and keeps running unless you select it too),
  terminal tabs (a session leader with a terminal, or any shell that is not clearly running a command), apps,
  other AI sessions, Apple's processes, and other users' processes. The confirmation names what it leaves running.
- **What you confirm is what happens.** The first click plans the stop from a fresh snapshot and shows the exact
  number of processes; the CLI prints every PID. On confirm, Strays plans again from a fresh snapshot (the tree may
  have changed while you read) with the same rules.
- **Refused outright:** another user's process, Apple's processes (`/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`),
  Strays itself, and anything Strays runs inside (so the CLI never stops the shell or AI session it runs in). The
  CLI refuses to run a stop under `sudo`.
- **No recycled-PID accidents.** Immediately before **every** signal, the PID's start time (microseconds) and owner
  are re-read from the kernel and compared with the snapshot. A PID that now belongs to a different process, or a
  process that switched owner (exec'd a setuid program), is never signalled and is reported as not stopped.
- **No respawn escapes.** The tree is frozen with `SIGSTOP` (re-scanning until nothing new appears), sent `SIGTERM`,
  and resumed with `SIGCONT` so each process can shut down cleanly. While waiting, anything that appears below a
  survivor is stopped too. After the grace period (5 s by default) survivors are frozen again and `SIGKILL`ed. If
  the port is held again right after (a launchd `KeepAlive` job), the app says so instead of reporting success.
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
  JSON or in a notification: secret-named flags and variables (`--api-key x`, `--token=x`, `FOO_TOKEN=x`,
  `--env=API_KEY=x`), URL credentials (`postgres://user:pass@`, `https://ghp_…@github.com`), secret query
  parameters, `Authorization:` / `Bearer` / `X-Api-Key:` headers, `mysql -pX`, `sshpass -p`, `redis-cli -a`,
  `curl -u user:pass`, JSON bodies (`"password": "…"`), well-known token formats (`sk-`, `ghp_`, `AKIA`, JWTs…) and
  long random-looking strings. It is a best effort: a secret in a shape it doesn't know can still show. The only
  deliberate exception is *Copy full command line*, which copies your own process's exact arguments to your
  clipboard because you asked for them.
- **No build-machine details in binaries.** Debug symbols are stripped and `#file` is module-relative.

## Threat model

Strays runs with your user's rights and assumes your user account is not already compromised. What it defends
against is **its own mistakes**: stopping the wrong process (recycled PIDs, other users, macOS, itself), leaking
secrets from command lines into screenshots or logs, and growing a network or privilege surface over time.

It does not try to defend against a malicious process of yours that lies about itself (a process can rename its
own arguments). Strays shows what the kernel reports.

## Verify it yourself

```sh
make test     # 106 tests, including real processes being found, probed and stopped (respawning ones too)
make app
make audit    # greps the source and inspects the signed bundle for every claim above
```

`scripts/audit.sh` fails if network APIs, URLs other than localhost, listening sockets or other IPC, new
subprocesses, new signal or AppleScript call sites, `.key` file access, file writes, private APIs, dependencies or
binary targets appear in the source, or if the signed app has extra entitlements or privacy strings, bundled
frameworks, imports a system call beyond `kill`, `socket`, `connect`, `bind`, `inet_addr` (and `dlsym`, which
Swift's runtime support code uses), or contains URLs or home-folder paths. The source checks are pattern-based:
they catch the usual spellings, not a determined attempt to hide something, which is what reading the (small)
source is for.
