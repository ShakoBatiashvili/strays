# Design notes

Strays came out of a design interview: the author kept starting dev servers, Python scripts and Claude Code
sessions across terminal tabs and forgetting them. On the machine it was designed on there were seven Claude
sessions open (the oldest six days, each with about five MCP helper processes), and one `npm start` that had lost
its terminal nine hours earlier and was still serving a port. These are the decisions, and why.

## Shape

- **Menu-bar item + popover**, not a window app. A window you have to remember to open defeats the purpose. The
  icon shows the number of listening servers and gets an orange dot when something is stale.
- **CLI too**, sharing all logic (`StraysCore`, `StraysSystem`) and settings with the app.

## What is listed

- **Dev filter**: your processes that listen on a port, plus known dev runtimes without one. Apple and app
  processes appear only if they hold a port, in a collapsed *System & apps* section (port 5000 = AirPlay is the
  classic trap).
- Things **apps start for themselves** (editor language servers, browser bridges) are hidden unless they hold a
  port: they are the app's business, not forgotten work.

## Grouping: what is "one thing"

A row is rooted at the top-most process below something the user interacts with: an interactive shell, a
terminal multiplexer, an AI session, an app, or launchd (after the terminal went away). Everything below the root
belongs to the row, so `npm start → sh -c → tsx → node` is one row named after its project with port 5317.

- **AI sessions are boundaries.** Their port-less children (MCP servers) fold under the session as helpers; a
  child that listens on a port (a dev server Claude started) becomes its own server row that remembers which
  session started it.
- **Project name** comes from the git root above the working directory (`mono › web` inside a monorepo), never
  climbing above the home folder.
- **Labels** prefer what a person typed: rewritten titles (`npm start`, `next-server`), package names from
  `node_modules`, console scripts from `bin/`, `python -m` modules, and the command inside Claude Code's
  `zsh -c "… eval '<command>' …"` wrapper.

## Stale

- **Orphaned**: parent gone, adopted by launchd, and not a launchd job (`launchctl list` tells brew services
  apart).
- **Idle**: under 0.5% of a core over the last 3 h (observed history; falls back to the lifetime average), or, for
  Claude Code, the session's own `idle` status and last activity.
- **Old**: running over 24 h.
- launchd services and system rows are never stale. All thresholds are settings.

## Stopping

- **Graceful, whole tree**: `SIGTERM` root first then level by level (so supervisors don't restart children),
  `SIGKILL` after 5 s.
- **Inline two-click confirm** that names the count ("Stop 4"), no modal dialog. There is no undo for a killed
  process, so the friction is proportional: one extra click, and the strip disarms itself after 6 s.
- Bulk *Stop stale…* and *Stop everything in &lt;project&gt;* show the list before the one confirm.

## Extras that made the cut

Open in browser (only for ports that answered a `HEAD /` with HTTP), show the terminal tab (Terminal / iTerm2 via
AppleScript, by tty), open the project in Cursor (or VS Code, Zed, Xcode), copy menu, port lookup in the filter
(`:3000` shows the holder or "free"), daily reminder at 18:00, global shortcut ⌃⌥P, open at login, Docker
containers over the local socket.

## Deliberately not done

- **Restarting** a stopped process: its environment, stdin and output are gone; a "restart" would be a guess.
- **Logs** of running processes: their stdout belongs to the terminal that started them.
- **Other users' processes**: would need root, which this project never asks for.
