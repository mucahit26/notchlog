# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

NotchLog is a macOS background system monitor that lives in the MacBook notch, plus a task
list tied to applications. See `README.md` for the user-facing description.

## Commands

```bash
swift build -c release                    # canonical build — no Xcode, Command Line Tools only
./.build/release/notchlog selftest        # the test suite
./Scripts/install.sh                      # build, self-test, bundle, sign, install LaunchAgent, restart
./Scripts/uninstall.sh [--purge]          # --purge also deletes the database
./Scripts/verify-no-network.sh            # proves the running process holds no sockets
```

**`swift test` does not work and there is no test target.** Neither XCTest nor
swift-testing ships with the Command Line Tools, and building without Xcode is the point
of this package. The suite is a subcommand — `notchlog selftest` — which runs everywhere
and also exercises the parsers against the live system. Add coverage there, in
`Sources/NotchLogKit/SelfTest.swift`.

**Check strict concurrency before pushing:**

```bash
swift build -c release -Xswiftc -strict-concurrency=complete
```

CI's toolchain rejects what the local default only warns about. This has broken CI twice
(`Monitor` and `NSImage` crossing actor boundaries), and a clean local build is not
evidence.

### Development aids

```bash
notchlog preview out.png [--light --calendar --new-task --tasks]   # render a page to PNG
notchlog sample 3            # print live samples to the terminal
notchlog export 24           # write a report without the UI
notchlog retention           # force a rollup + purge now
notchlog calendar-test       # TCC diagnostic (not listed in `help`)
```

`preview` renders offscreen through a real `NSHostingView`, so UI changes can be reviewed
without a screen-recording permission or asking the user to look at their display. Use it.
It renders through AppKit rather than `ImageRenderer` on purpose: `ImageRenderer` does not
resolve a bare `Image(systemName:)` and substitutes a placeholder, inventing icon bugs that
do not exist.

## Architecture

One `.accessory` executable started by a LaunchAgent. `NotchLogKit` holds everything;
`NotchLog` is a thin `main.swift` + `AppDelegate`.

```
ps ──┐                                    ┌── SQLite (tiered, rolling purge)
     ├── Sampler ── deltas ── Monitor ────┤
nettop┘      │                            └── LiveModel ── SwiftUI ── NSPanel @ level 25
             │
 proc_pid_rusage (own-user disk I/O)
```

`Monitor` owns the sampling loop, the database, retention and workspace observation.
`NotchController` owns the panel, the four pages and the reminders.

### Collection (`Sources/NotchLogKit/Collect/`)

Single-shot polling of `/bin/ps` and `/usr/bin/nettop` every 10 s — 2 s only on the live
page while the panel is open.

- **Never turn these into persistent children.** Continuous `nettop` burns ~145 % CPU
  regardless of its interval, and `-L 0` piped to anything emits nothing at all. Single-shot
  is ~1500× cheaper.
- **CPU is `Δcputime / Δwalltime`**, persisted as `cpu_ms`. `ps %CPU` is a kernel decayed
  average and is badly wrong on bursts — measured 76.3 % against a true 9.4 %. Never display it.
- `ProcessRunner` enforces a **two-binary allowlist** and **drains the pipe before waiting**;
  `ps` output sits at ~64 KB, so waiting first deadlocks. CI asserts nothing else is spawned.
- **`nettop -n` is mandatory.** Without it nettop reverse-DNSes every remote address — the
  monitor would generate its own network traffic. CI asserts the flag is present.
- Join `ps` and `nettop` rows **on PID, never on name**: nettop truncates names to 15 chars.
- Helper processes roll up by the **leftmost `.app`** component of the executable path.
- Disk I/O is sampled for every PID deliberately. Restricting it to "busy" processes was
  tried and reverted: `prevDisk` then holds only that subset and processes moving in and out
  of the filter lose their baseline and report zero.

### Storage (`Sources/NotchLogKit/Storage/`)

System SQLite via `import SQLite3` directly — no C target, no module map.

| Table | Resolution | Kept |
|---|---|---|
| `sample_fine` | 10 s | 24 h |
| `sample_minute` | 1 min | 7 days |
| `sample_day` | local day, `YYYYMMDD` key | 365 days |
| `task`, `task_app`, `task_reminder` | — | **never purged** |

**Disjointness rule.** Rows older than 24 h are written into *both* `sample_minute` and
`sample_day` by the same retention pass. Anything aggregating by day must read
`sample_fine` + `sample_day` only — including the minute table double-counts every day but
today.

**`task_app` stores app name and bundle id, not a foreign key to `app`.** Retention deletes
`app` rows once an application stops appearing in samples; a foreign key would silently
break the association for any app you had not opened in a week. `SelfTest` proves a task
survives a full retention pass.

`PRAGMA auto_vacuum = INCREMENTAL` must run **before the first `CREATE TABLE`** — it is a
file-format property and cannot be changed later. Purging uses `incremental_vacuum`, not
`VACUUM`, which would need twice the file size in temp space.

Adding a column to a shipped table goes through `Database.addColumn(_:type:to:)`, which
inspects `PRAGMA table_info` first — SQLite has no `ADD COLUMN IF NOT EXISTS` and `migrate()`
runs on every open against databases written by any earlier version.

### UI (`Sources/NotchLogKit/UI/`)

Four pages in `PanelState.Page`: `tasks`, `newTask`, `live`, `calendar`. Page order,
titles, per-page panel heights and preview flags all resolve through that enum — three
places used to hold the order independently and silently disagreed.

Things that will bite again:

- **Set `panel.level` *after* `isFloatingPanel`.** That setter forces the level back to
  `.floating` (3), below the menu bar (24). The panel needs `.statusBar` (25).
- **Use `NotchGeometry.preferredScreen()`, never `NSScreen.main`.** Main follows the active
  window, so it changes as the user moves around, and an external monitor makes it a display
  with no notch — the panel then draws a fallback pill in the wrong place.
- **Never call `NSApp.hide(_:)`.** For an accessory app it hides every window including the
  notch panel, and nothing brings it back: the app looks like it quit while its launchd job
  is perfectly healthy. `NotchController` carries a watchdog for this.
- **All timers must use `RunLoop.main.add(_:forMode: .common)`.** In the default mode they
  stop firing while a list is scrolled, which silently disabled the panel's close poll.
- The panel becomes key only on the New task page — that activates the whole app, so it is
  acquired where typing is the point and released on leaving. `TaskModel.isEditing` (text
  field focus, not page) gates the hover lock; drafts survive a collapse, so pinning the
  panel open for the whole page protects nothing.
- Closing uses a cursor-position poll, not the tracking area: once the panel resizes under
  the pointer, enter/exit oscillates.
- **Flatten icons to their display size.** `NSWorkspace.icon(forFile:)` carries every
  representation up to 1024 px and setting `.size` only changes how it draws — 14.5 MB
  versus 5.5 MB across ~85 apps.
- `Palette` hues are validated against colour-vision-deficiency simulation, and
  `Palette.overdue` is a reserved *status* colour — do not reuse it as a fourth series.

## Security posture

These are enforced by CI (`.github/workflows/ci.yml`), not just convention: no networking
symbols in `Sources/`, no package dependencies, `nettop -n` present, and no subprocess
launched outside `ProcessRunner`'s allowlist. Keep them passing rather than working around
them.

The app is ad-hoc signed with the hardened runtime and **exactly one entitlement**,
`com.apple.security.personal-information.calendars`. Without it macOS refuses Calendar
access *before TCC ever prompts*: the request returns `granted=false` with **no error** and
the status stays `notDetermined` — indistinguishable from an app bug. `Scripts/bundle.sh`
asserts the entitlement survived signing.

App Sandbox is not viable and should not be attempted: a sandboxed process cannot exec
`/usr/bin/nettop`, which needs the network-statistics kernel control socket, and no public
entitlement grants it.

Calendar access is read-only except for one opt-in all-day event per task, and nothing is
ever deleted from the user's calendar.

### Testing anything TCC-related

Running the binary from a terminal makes the **terminal** the responsible process, so
Calendar requests fail in a way that looks exactly like an app bug. Read the
`responsible parent` line from `notchlog calendar-test`: it must say
`com.mucahit26.notchlog`. If it names a terminal or host app, that run proves nothing —
only the launchd-started instance is a valid test.

## Measurements

Figures in the README are measured, not estimated, and are stated with the conditions that
produced them (CPU scales with process count: ~0.5 % of one core at ~550 processes, ~0.8 %
at ~860). If you change sampling or storage, re-measure and update them rather than leaving
a number that was true once.
