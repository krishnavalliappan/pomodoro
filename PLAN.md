# Pomodoro — plan

A fast, native macOS **menu-bar** Pomodoro app with simple task management and
calendar time-blocking. It has no Dock icon, like Raycast: it lives in the menu bar,
and the planner window opens on demand.

## Product goals

1. **Start focus in one click**, with a task or without one.
2. **Flow-friendly breaks.** When a focus session ends, the timer does not stop. It
   chimes, asks "Take a break?", and keeps counting overtime (`+03:12`) until you
   choose *Start break*, *+5 min*, or *Keep going*.
3. **Default profile, presets, and one-off overrides.** For example, "this one is 50/10"
   applies once and doesn't change your defaults.
4. **Simple tasks:** quick-add, estimates in pomodoros, and actual pomodoros tracked
   per task.
5. **Time-blocking:** a day timeline where you drag tasks into blocks or drag-create a
   block, then start a pomodoro from a block.
6. **Feels native and instant:** about 30 MB RAM, near-zero idle CPU, no beachballs,
   and correct behaviour across sleep and wake.

## Non-goals for v1

Sync or accounts, iOS, team features, Apple Calendar *write*, recurring tasks, and
complex projects or subtasks.

## Inspiration (GitHub research)

| Project | What to borrow |
|---|---|
| [ivoronin/TomatoBar](https://github.com/ivoronin/TomatoBar) (Swift, MIT, ~3k★) | The gold standard for a minimal menu-bar timer: actionable notifications, global hotkey, sounds, and a JSON state log. Its timer state machine and polish are worth studying. |
| [andev0x/CapyTimer](https://github.com/andev0x/CapyTimer) (SwiftUI) | Menu bar timer combined with a todo list and quick notes. A good reference for the popover layout. |
| [iammayron/pour](https://github.com/iammayron/pour) (SwiftUI) | Menu bar pomodoro bound to Todoist tasks, with Today/Overdue filters. Shows the UX for picking a task and starting a timer on it. |
| [stevenselcuk/Pomosh-macOS](https://github.com/stevenselcuk/Pomosh-macOS) (SwiftUI) | Small SwiftUI menu bar app with a clean visual timer. |
| [fausto95/potem](https://github.com/fausto95/potem) (SwiftUI) | Native timeline view combined with pomodoro. A reference for drawing the planner timeline. |
| [super-productivity](https://github.com/johannesjo/super-productivity) (Electron) | Feature reference for timeboxing, pomodoro, estimates vs. actuals, and a daily planner. Borrow ideas, not the stack. |
| [enzodevs/timeboxd](https://github.com/enzodevs/timeboxd) (web) | Drag to-dos onto a day timeline and resize in 15-minute steps. The interaction model we want. |
| [saranshbarua/flumen](https://github.com/saranshbarua/flumen) (TS) | Free pomodoro with tasks and reports. A reference for the stats screens. |

No existing open-source app combines **native menu bar, pomodoro with overtime flow,
tasks, and time-blocking**. That gap is what this app fills.

## Tech stack

- **Swift 6 + SwiftUI**, with AppKit where SwiftUI falls short (the status item title,
  window activation, drag and drop on the timeline). Targets **macOS 14+**, which
  gives us `@Observable`, `MenuBarExtra`, and `SMAppService`.
- **No Dock icon:** set `LSUIElement = YES`. The planner and settings windows are
  activated explicitly with `NSApp.activate`.
- **XcodeGen** (`project.yml`) instead of a committed `.xcodeproj`, so diffs stay
  readable and agents don't fight merge conflicts in `pbxproj`.
- **`PomodoroCore` local Swift package** holds all logic: the timer state machine,
  models, the quick-add parser, scheduling math, and stats. It has no SwiftUI or
  AppKit imports, so it's heavily unit-tested and fast to test.
- **Persistence:** [GRDB](https://github.com/groue/GRDB.swift) (SQLite) for tasks,
  blocks, and sessions, with explicit migrations. It's fast and predictable, and it
  avoids SwiftData's rough edges. Settings use `Codable` in `UserDefaults`.
- **Dependencies** (kept minimal):
  [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) for global
  hotkeys, GRDB, and [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
  as a test-only dependency.
- **Sounds:** generated procedurally by a script in the repo (`scripts/gen_sounds.py`,
  which writes `.caf`/`.wav` files). They're original and license-free. Playback uses
  preloaded `AVAudioPlayer` instances, so there's no latency.

### Architecture

```
App (SwiftUI/AppKit)
 ├─ MenuBarController   status item title (time / task), popover (MenuBarExtra .window)
 ├─ PlannerWindow       day timeline + task list (drag & drop)
 ├─ SettingsWindow
 ├─ NotificationService UNUserNotificationCenter + action categories
 ├─ SoundService        preloaded players, volume, optional tick
 └─ SystemEvents        sleep/wake, screen lock → TimerEngine.reconcile(now)
PomodoroCore (pure Swift, unit-tested)
 ├─ TimerEngine         state machine, wall-clock anchored, injectable Clock
 ├─ Profiles/Presets    default profile, named presets, one-off override
 ├─ Models              TaskItem, TimeBlock, FocusSession
 ├─ Store               GRDB repositories + migrations
 ├─ QuickAddParser      "Write spec ~3 @14:00 45m #work"
 └─ Stats               daily/weekly totals, per-task actuals, streaks
```

**Timer correctness rule:** never count ticks. Store `phaseStartedAt` and
`pausedAccumulated`, and derive the remaining time from the wall clock. The UI
refreshes once per second only while it's visible or the menu bar shows seconds.
Otherwise one timer fires at the phase boundary. This keeps idle CPU near zero and
makes sleep and wake correct.

## Feature spec (v1)

### Timer
- Phases: focus, short break, long break. A long break comes every N focus sessions
  (default 4).
- Defaults are 25/5/15. You can save named presets such as *Deep 50/10* and
  *Quick 15/3*.
- One-off override at start: pick a duration chip or type `40` for this session only.
- Controls: start, pause, resume, skip, reset, +1 and +5 min, and *Stop & log*.
- **Overtime/flow mode** (default on): when focus ends, the app plays the chime and
  shows a notification with *Start break*, *+5 min*, and *Keep going*. The menu bar
  shows `+mm:ss` overtime, and the overtime counts toward the task's actual time.
  A gentle re-nudge plays every N minutes (configurable, default 10, can be turned off).
- Breaks end the same way: *Start focus*, *+2 min*, or *Done for now*.
- Auto-start toggles for breaks and the next focus.
- Sleep or lid close is reconciled on wake. If the phase ended while asleep, the app
  shows the correct state and overtime.

### Menu bar
- The title shows `🍅 18:42`, `☕ 03:10`, or `+02:15`. Display options: icon only,
  time, or time plus a truncated task name.
- Popover: big timer and controls, current task, a task picker (Today and scheduled
  now first), preset and one-off chips, today's progress dots, and an *Open Planner*
  button.
- Global hotkeys: start/pause, skip, and open the popover.

### Tasks
- Quick-add field in the popover and the planner, with `~N` for estimated pomodoros,
  `@HH:mm` for a block start, `Nm`/`Nh` for block length, and `#tag`.
- The task list shows today and inbox, with check-off, reordering, and estimate vs.
  actual dots.
- Starting a pomodoro on a task attaches its sessions to that task.

### Planner (time-blocking)
- A day timeline from 06:00 to 24:00 that snaps to 15 minutes. A *now* line
  auto-scrolls into view.
- Drag a task from the list onto the timeline to create a block. Drag on empty space
  to create a block, then name it or pick a task. Blocks can be moved, resized,
  and deleted.
- When the current time is inside a block, the popover suggests that block's task.
  A ▶ on a block starts focus for that task.
- Stretch goal: a week view.

### Sounds
- Built-in sounds for focus end, break end, start, and an optional soft tick. Each is
  previewable, with master volume, and each can be set to *None*.

### Settings and system
- Settings for durations, presets, overtime and nudges, auto-start, sounds, menu bar
  display, hotkeys, launch at login (`SMAppService`), and first weekday.
- Stats: focus minutes today and this week, per-task actuals, and the daily streak.

## Delivery: milestones → GitHub issues

| # | Issue | Depends on |
|---|---|---|
| **M0** | | |
| 1 | Scaffold: XcodeGen app (LSUIElement), `PomodoroCore` package, macOS CI (build + test + screenshot artifacts), lint/format | — |
| **M1 (parallel)** | | |
| 2 | Core: TimerEngine state machine with overtime, wall-clock, injectable clock, exhaustive tests | 1 |
| 3 | Core: Profiles, presets, one-off overrides, settings model | 1 |
| 4 | Core: GRDB store (TaskItem, TimeBlock, FocusSession) + migrations + tests | 1 |
| 5 | Sounds: procedural generator script + SoundService | 1 |
| 6 | Core: QuickAddParser + tests | 1 |
| **M2** | | |
| 7 | Menu bar status item + popover UI wired to TimerEngine | 2, 3, 5 |
| 8 | Notifications with actions + overtime nudges + sleep/wake reconcile | 2, 5 |
| 9 | Task list + quick-add UI + start-on-task | 4, 6, 7 |
| 10 | Planner window: day timeline, drag-create/move/resize, task drag-in, start from block | 4, 9 |
| **M3** | | |
| 11 | Settings window + global hotkeys + launch at login | 3, 7 |
| 12 | Stats: today/week/per-task/streak | 4, 7 |
| 13 | Release: app icon, unsigned/ad-hoc `.app` zip artifact on tag, README | 7 |
| Backlog | Apple Calendar read-only overlay (EventKit), App Intents/Shortcuts, Focus-mode filter, idle detection, ambient sounds, iCloud sync | |

## Agent workflow

```
issue ──► implementer agent (Claude, own git worktree, branch issue-N-slug)
            └─ pushes, opens PR "Closes #N"
        ──► macOS CI on GitHub Actions: xcodegen → xcodebuild build + test,
            uploads snapshot PNGs + xcresult
        ──► code review: Codex gpt-6.1-sol, reasoning=high → PR review comment
        ──► visual QA: cheaper model (Claude Haiku 5.5) downloads the CI screenshot
            artifacts and checks them against the issue's acceptance criteria
        ──► fix round(s) by a new implementer task (max 3 rounds)
        ──► green CI + no blocking findings → squash-merge → next issues unblock
```

- **Why not browser testing?** This is a native app, and the dev sandbox is Linux,
  so nothing can run the UI here. Instead, CI on a `macos` runner renders the views
  through snapshot tests and XCUITest and uploads the PNGs. A cheap vision model
  reviews those images. This is the native equivalent of browser QA.
- At most 3 implementers run at once, because the sandbox has a 5 GB RAM limit.
- `main` is protected: changes go through PRs only, and merging requires green CI.
- Manual QA on a real Mac happens at the end of each milestone. Download the CI
  `.app` artifact to do it.
