# NotchLog

A background system monitor that hides in your MacBook's notch. Move the pointer there
and it expands to show what is using your CPU, memory and network **right now**. It logs
that activity continuously so you can answer "what was my Mac doing at 3am?", and exports
the last 24 hours as a plain text file.

Two-finger swipe to the second page for a calendar: a month grid tinted by how hard your
Mac worked each day, beside that day's events and busiest applications.

**It has no network code at all.** Not "it doesn't phone home" — there is no networking
in the binary, CI fails the build if any appears, and you can verify it on your own machine
in one command.

```
                    ┌─────────────┐
   ═════════════════┤   ▓▓▓▓▓▓▓   ├═════════════════   ← resting: invisible, in the notch
                    └──────┬──────┘
                    ┌──────┴────────────────────┐
                    │ CPU      MEMORY   NETWORK │      ← hover: live top consumers
                    │ Chrome   Chrome   Chrome  │
                    │ Xcode    Slack    Dropbox │
                    │ [ Export last 24 hours ]  │
                    └──────────── ● ○ ──────────┘
                             ↕ two-finger swipe
                    ┌───────────────────────────┐
                    │ M T W T F S S │ Sat, 19   │      ← page 2: activity heat map
                    │ ░▓█░▓░░       │ 10:00 …   │        + your calendar events
                    │ █░▓█░░▓       │ Chrome 2h │
                    └───────────────────────────┘
```

## Privacy and security

This tool watches everything your computer does, so it is worth being precise about what
it does with that.

| | |
|---|---|
| Network access | **None.** No `URLSession`, no `Network` framework, no sockets. |
| Dependencies | **None.** `Package.swift` declares zero packages — no supply chain. |
| Privileges | **None.** No root helper, no privileged daemon, no `sudo` at install. |
| Permission prompts | **None for monitoring.** Calendar access is the one exception — see below. |
| Subprocesses | Exactly two, by absolute path: `/bin/ps` and `/usr/bin/nettop`. |
| Where data lives | `~/Library/Application Support/NotchLog/`, directory `0700`, database `0600`. |

### The one permission, and how to avoid it

Everything on page 1 — all the monitoring, logging and exporting — runs with **no
permission of any kind**. No Accessibility, no Input Monitoring, no Screen Recording, no
Full Disk Access. Hover detection and the two-finger swipe both work through ordinary
event delivery, which needs no approval.

Page 2 shows events from your Calendar, and that needs macOS Calendar access. It is:

- **Lazy** — asked for the first time you open page 2, never at launch. If you never swipe
  to the calendar, you are never asked.
- **Optional** — deny it and the page still works. The month grid and the activity heat
  map come from NotchLog's own database; only the event list stays empty.
- **Read-only, and nothing is kept.** Events are read for display and dropped. They are
  never written to the database, never exported, and there is no network to send them to.

If you would rather the capability did not exist at all, delete
`Sources/NotchLogKit/UI/CalendarService.swift` and the `NSCalendarsFullAccessUsageDescription`
key from `Resources/Info.plist.template` before installing. Everything else still builds.

### Verify it yourself

Do not take the above on trust — check it:

```bash
./Scripts/verify-no-network.sh
```

Or directly:

```bash
/usr/sbin/lsof -nP -i -a -p "$(pgrep -x notchlog)"
```

A process that holds no sockets cannot send anything anywhere. If that command prints
nothing, the guarantee holds on your machine, today, regardless of what this README claims.

CI enforces the same property on every commit: it greps the sources for networking
symbols, asserts `Package.swift` has no dependencies, and asserts that no subprocess is
launched outside the two-binary allowlist.

### What the database contains

A detailed, timestamped record of which applications you ran and what they did — which is
inherently sensitive, even though it never leaves your machine. It is capped at 7 days and
kept at `0600`. Delete it any time:

```bash
rm -rf ~/Library/Application\ Support/NotchLog
```

### Why it is not sandboxed

App Sandbox would be the obvious hardening, and it is deliberately not used: a sandboxed
process cannot exec `/usr/bin/nettop`, which needs the kernel's network-statistics control
socket, and no public entitlement grants it. Sandboxing would break the core function.
The hardened runtime *is* enabled, which blocks `DYLD_INSERT_LIBRARIES` and unsigned code
injection.

## Requirements

- macOS 14 or later (built and tested on macOS 27, Apple Silicon)
- Xcode **not** required — the Command Line Tools are enough:
  ```bash
  xcode-select --install
  ```

A notch is optional. On a Mac without one, NotchLog rests as a slim pill just below the
menu bar and behaves identically.

## Install

```bash
git clone https://github.com/mucahit26/notchlog.git
cd notchlog
./Scripts/install.sh
```

The script builds from source, runs the self-test, assembles the app bundle, signs it
ad-hoc and registers a LaunchAgent so it starts at login and stays running.

There are no binary releases on purpose. An ad-hoc signature cannot be notarized (that
needs a paid Developer ID), so a downloadable build would trip Gatekeeper — a poor look
for a tool whose whole argument is that you can trust it. Building locally produces no
quarantine flag and no warning, and you get to read exactly what you are running.

macOS lists the agent under **System Settings → General → Login Items → Allow in the
Background**. That entry is how it starts at login; it is not a permission prompt.

### Uninstall

```bash
./Scripts/uninstall.sh           # removes the app, keeps your data
./Scripts/uninstall.sh --purge   # removes the data too
```

## Usage

Move the pointer to the notch. After a brief delay the panel expands with live top-five
lists for CPU, memory and network, a disk summary, and an export button. Move away and it
collapses. There is nothing to click to open it and nothing to dismiss.

**Two pages.** Swipe horizontally with two fingers to move between them, or click the page
dots. Swiping left goes forward, matching Safari's page gesture.

1. **Live** — what is using CPU, memory and network right now.
2. **Calendar** — a month grid where each day is tinted by how much CPU your Mac burned
   that day, with the selected day's calendar events and busiest applications beside it.
   Daily summaries are kept for a year, so the heat map fills in as you use it; the
   detailed tables behind page 1 still only go back 7 days.

```bash
notchlog selftest         # verify the parsers against your own system
notchlog export 24        # write a report without using the UI
notchlog sample 3         # print three live samples to the terminal
notchlog retention        # force a rollup + purge now
notchlog preview out.png  # render the panel to a PNG (--light for light mode)
```

Exports land in `~/Library/Application Support/NotchLog/exports/` and are revealed in
Finder. They are written there rather than to `~/Downloads` because writing to Downloads
from a non-sandboxed app triggers a permission prompt, and this app asks for nothing.

## What it measures, and how accurately

Honesty here matters more than a nice feature table, because several of these numbers have
real limits imposed by macOS.

| Metric | Source | Accuracy |
|---|---|---|
| **CPU** | Δ of cumulative CPU time from `ps` | Accurate. Reported as a percentage of **one core**, so a multi-threaded app can exceed 100%. |
| **Memory** | Resident size from `ps` | Helpers are summed into their parent app, which double-counts shared framework pages. Activity Monitor has the same artefact. |
| **Network** | Per-socket counters from `nettop` | A **lower bound** — see below. |
| **Disk I/O** | `proc_pid_rusage` | **Your own processes only.** Root-owned daemons return `EPERM` and there is no unprivileged way around it. Measured: 411 of 595 processes readable. |
| **App launch/quit** | `NSWorkspace` notifications | Accurate for GUI applications. |
| **Calendar events** | EventKit, if you allow it | Exactly what Calendar.app shows. Read-only, never stored. |

**Why CPU does not come from `ps %CPU`.** That column is a kernel *decayed average*, not an
instantaneous reading, and it is badly wrong on bursts — during development one process
reported `76.3%` while its true five-second usage was `9.4%`. NotchLog computes
`Δcputime / Δwalltime` instead and stores CPU-milliseconds, which are additive and exact.

**Why network totals are a lower bound.** `nettop` reports cumulative bytes per *open
socket*. When a socket closes it simply stops appearing, so bytes moved between the last
sample and the close are never counted, and a connection that opens and closes entirely
between two samples is missed completely. Totals are therefore an undercount, never an
overcount. The export says so in its header.

**No energy metric.** `top`'s `POWER` column is a verbatim copy of `%CPU` on Apple Silicon,
so shipping it would have meant showing the same number twice under a different name.
Activity Monitor's "Energy Impact" comes from private IOReport data and `powermetrics`
requires root, so there is no honest unprivileged version of it.

## Storage and retention

Sampling runs every 10 seconds, and every 2 seconds while the panel is open.

Storage is tiered, because a flat week at 10-second resolution would cost roughly 500 MB:

- **Last 24 hours** — full 10-second resolution. This is exactly the window the export
  covers, so the export never loses detail.
- **Days 2 to 7** — rolled down to one row per minute.
- **Older than 7 days** — deleted from the detailed tables.
- **Daily summaries** — one small row per app per day, kept for **a year** so the calendar
  heat map has history. A few dozen rows a day costs well under a megabyte annually.

Rows that are simultaneously idle on every axis are not stored at all — on a typical
desktop that takes roughly 400 running applications down to **64 stored rows per sample**.

Measured on a real install: **38 bytes per row**, which works out to about 21 MB for the
last 24 hours at full resolution plus 12 MB for the six rolled-down days — roughly
**35 MB** in steady state.

The purge is *rolling* rather than a weekly wipe, so the file stays a steady size instead
of sawtoothing to a weekly peak. Freed pages are returned to the filesystem with
`PRAGMA incremental_vacuum` rather than a full `VACUUM`, which would need twice the
database size in temporary space.

## Cost

Measured on a MacBook Air M3 (8 cores), running as the installed LaunchAgent:

| | |
|---|---|
| CPU, panel closed | **~0.5% of one core** — ≈50 ms per 10-second sample |
| CPU, panel open | a few percent, while sampling speeds up to 2 s and SwiftUI redraws |
| Memory | ~60 MB resident |
| Disk | **~35 MB** steady state, hard-capped at 7 days |

Sampling is single-shot polling, not a persistent child process. A continuously running
`nettop` was measured burning **~145% CPU** regardless of its sample interval, while a
single-shot poll costs 0.01 CPU-seconds. The remaining cost is mostly the SQLite write
and reading per-process disk counters for every PID on the system.

## How it works

```
  ps ──┐                                    ┌── SQLite (tiered, 7-day rolling purge)
       ├── Sampler ── deltas ── Monitor ────┤
 nettop┘       │                            └── LiveModel ── SwiftUI ── NSPanel @ level 25
               │
   proc_pid_rusage (own-user disk I/O)
```

The panel is an `NSPanel` at `NSWindow.Level.statusBar` (25), one above the menu bar (24),
with `.canJoinAllSpaces` and `.fullScreenAuxiliary` so it persists across Spaces and over
full-screen apps. When collapsed it sits exactly behind the camera housing, where there are
no pixels — so the resting state is genuinely invisible rather than merely small.

Each column ranks apps on one metric and draws a bar relative to the busiest app in
**that** column — bars are never compared across columns, because percent, bytes and
bytes-per-interval share no common scale. The three hues are slots 1–3 of a validated
categorical palette with separate steps for light and dark, checked against colour-vision
deficiency simulation rather than chosen by eye; every column and row also carries a text
label, so identity never depends on colour alone.

Hover uses an `NSTrackingArea` with `.activeAlways`, which fires while other apps are
frontmost and needs no permission. Closing does **not** use the tracking area: once the
panel expands, its bounds move under the cursor and enter/exit oscillates (an early
experiment produced 18 cycles in 25 seconds). Instead the cursor position is polled and the
panel closes only after the cursor has been outside continuously for 350 ms.

### Repo layout

```
Sources/NotchLogKit/
  Collect/   ProcessRunner, PSSource, NettopSource, DiskIOSource, AppIdentity, Sampler
  Storage/   Database, Retention, Queries, Exporter
  UI/        NotchGeometry, HoverTracker, NotchController, LiveModel, Views,
             Palette, PanelState, CalendarPage, CalendarModel, CalendarService
  Monitor.swift, SelfTest.swift
Sources/NotchLog/     main.swift, AppDelegate.swift
Scripts/              install.sh, uninstall.sh, bundle.sh, verify-no-network.sh
Fixtures/             real ps/nettop output the parsers are tested against
```

There is no test target. Neither XCTest nor swift-testing ships with the Command Line
Tools, so `swift test` cannot run without Xcode — and building without Xcode is the point.
The suite is `notchlog selftest`, which runs everywhere and doubles as a way to check the
parsers against your own system.

## Troubleshooting

**The panel does not appear.** Check it is running with `pgrep -x notchlog`, then look at
`~/Library/Logs/NotchLog.log`. If it is not running, `launchctl bootstrap gui/$(id -u)
~/Library/LaunchAgents/com.mucahit26.notchlog.plist`.

**It opens when I reach for the menu bar.** The open delay is 120 ms specifically to avoid
this. If it still triggers, the cursor is resting on the notch rather than passing through.

**Numbers do not match Activity Monitor.** Expected for memory (helper double-counting) and
network (lower bound). CPU should agree closely — if it does not, please open an issue with
`notchlog sample 3` output.

**Nothing in the export.** It only contains what has been collected since installation.
Coverage is stated in the report header.

**The calendar heat map is mostly blank.** Daily summaries are written by the retention
pass, which first runs on data older than 24 hours — so a fresh install shows today only,
and fills in from there. `notchlog retention` forces a pass immediately.

**macOS asks for Calendar access again after I reinstall.** Expected. The app is ad-hoc
signed — there is no Developer ID to anchor the grant to — so macOS identifies it by the
hash of the binary, and rebuilding produces a different hash. Reinstalling after a code
change can therefore look like a new app and ask once more. This is a consequence of
shipping as source rather than as a notarized download; see *Install*.

**Two-finger swipe does nothing.** It requires a trackpad or a Magic Mouse; a classic
wheel mouse can scroll horizontally if it has a tilt wheel, and the page dots are always
clickable. The gesture is ignored unless it is clearly more horizontal than vertical, so
vertical scrolling never flips pages by accident.

## License

MIT — see [LICENSE](LICENSE).
