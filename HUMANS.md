# HUMANS.md

A guide for human developers who did not write this code. Written
from a fresh read of the sources on 2026-11-18, per the Owner's
order that agents explain AI-developed codebases.

## What this is

loophabits is a single-file Emacs Lisp package (990 lines) that
reimplements the features of the Android app Loop Habit Tracker
(iSoron/uhabits) on top of one plain Org file. Habits are level-1
Org headings with a property drawer for settings and a LOGBOOK of
dated check-in entries; the package parses that file, computes
Loop's scores and streaks, offers a dashboard buffer, reminders,
CSV/JSON export and import, and feeds an Android home-screen widget
through the sibling elwidget package.

The scoring and streak math deliberately copies uhabits' core
algorithms (Score.kt / StreakList.kt / Entry.kt), down to the
recurrence constants. The README and AGENTS.md make keeping that
behavior byte-compatible a rule: changes to that math must cite the
Loop source in the commit message.

There is no database, no cache file, no network. The Org file is
the only source of truth; the only in-memory cache keys on the
file's mtime.

## Mental model

One file, one struct, two directions of flow.

The file (default `~/org/habits.org`, `loophabits-file`) holds one
level-1 heading per habit:

    * Read a book                                             :habit:
    :PROPERTIES:
    :TYPE: yesno
    :FREQ: 1/1
    :COLOR: #7dcfff
    :END:
    :LOGBOOK:
    - [2026-11-15 Sat 21:32] 1
    - [2026-11-14 Fri] s   was traveling
    :END:

Properties: `TYPE` (yesno, measurable, measurable-at-most),
`TARGET`/`UNIT` for measurable habits, `FREQ` as `N/D` (N times per
D days), `COLOR`, `REMINDER` (HH:MM), `PAUSED`, `ORDER`,
`CREATED`. LOGBOOK lines are `- [DATE [TIME]] VALUE [note]` with
VALUE = 1 (yes), 0 (no), s (skip), q (questionable), or a number.

Reading: `loophabits-load` checks an mtime-keyed cache and, on a
miss, parses the file with org-element into a list of `lh/habit`
structs. Each habit's entries become proper 3-lists
`(DATE VALUE NOTE)` sorted by date. All queries (score, streaks,
due-ness, dashboard) are computed from these structs; nothing is
stored derived.

Writing: every mutation (`loophabits-set`, `loophabits-new`,
`loophabits-archive`, pause toggle) opens the real file with
`find-file-noselect`, edits it with regexps / Org commands, saves,
and calls `loophabits-load 'force`. So the file is authoritative
both ways, and hand edits are picked up on the next load (or after
`g` in the dashboard, which forces a reload).

The dashboard (`M-x loophabits`) renders one line per active
(non-archived) habit, ordered by `:ORDER:` then name, with the
habit name attached to each line as a text property so commands can
find the habit at point. `RET` opens a details buffer with score,
streaks, per-weekday completion rates, and a 365-day history grid.

## Code map

| File / symbol | Role |
|---|---|
| `loophabits.el` | Everything (990 lines). |
| `lh/habit` struct (line 89) | Fields: name, type, target, unit, color, freq-num, freq-den, reminder, paused, archived, order, created, entries. |
| `lh-*` date helpers (97-139) | Dates are `(Y M D)` lists; conversion, compare, day-diff/shift, parse/format YYYY-MM-DD. `lh-parse-date` wraps in `save-match-data`. |
| `loophabits-load` (151) | Cached entry point; cache key is `(mtime . file)` in `lh--cache-key`. |
| `lh--parse-file` / `lh--parse-habit` (162 / 179) | org-element parse; per-habit property + FREQ + LOGBOOK extraction with regexps. |
| `lh-entry-value` / `lh-entry-note` (250 / 255) | Accessors into the 3-list entries (never `cdr` an entry; see gotchas). |
| `lh-due-p` (271) | Was the habit still due on a date: quota unmet in the `den`-day window ending the day before. |
| `lh-computed-value` (291) | The semantic core: raw entry -> `skip`/`q`/number/`yes`/`no`/`auto` (`auto` = before creation or quota already met). |
| `lh--score-day` (318) | One step of Loop's score recurrence over a sliding window. |
| `loophabits-score` (356) | Day-by-day replay from habit creation to the target date; returns 0-100. |
| `loophabits-streaks` / `-current-streak` / `-best-streak` (394 / 411 / 424) | Runs of completed days, walking backward from today. |
| `lh--entry-line` / `loophabits-set` (431 / 444) | Entry formatting and the replace-never-duplicate writer. |
| `loophabits-toggle` / `loophabits-bump` (499 / 517) | Loop's nextToggleValue cycle for widget taps and `SPC`; the stepper write path (+/- DELTA on today's entry, floored at zero). |
| `loophabits-new` / `-archive` (551 / 587) | Create a habit heading; archive moves it under an Archive heading plus the ARCHIVE tag. |
| `loophabits--active` / `loophabits--mark` (630 / 639) | Dashboard list (non-archived, ordered) and today's mark glyph. |
| `loophabits` / `loophabits-refresh` (651 / 687) | The dashboard buffer and forced redisplay. |
| `loophabits-list-mode` keymap (616) | `SPC` toggle, `s` skip, `v` value, `N` note, `n` new, `RET` details, `a` archive, `p` pause, `o` open file, `g` refresh. |
| `loophabits-show-details` (792) | Stats + 365-day grid (rows = weeks, cols = weekdays). |
| `loophabits-start-reminders` / `--remind` / `--notify` (863 / 877 / 898) | 60-second timer; fires when HH:MM matches, due, uncompleted, unpaused, once per day. Notification degrades: Android -> desktop -> message. |
| `loophabits--value-arg` / `--on-event` / `-elwidget-tree` / `-elwidget-state` / `--today-tree` / `--progress-tree` / `register-widgets` (913 / 919 / 937 / 961 / 981 / 1014 / 1055) | The widget face of this package: trees, dual-key shadow state (NAME for checks, NAME#value for steppers), inc/dec/toggle tap handling, spec registration (called by elwidget-org's org-habits widget). |
| `loophabits-export-csv` / `-export-json` / `-import-json` (1095 / 1111 / 1142) | Backups; JSON is the full round-trip format. |
| `tests/run.el` | Batch runner; loads `tests/test-*.el`, exits 0/1. |
| `tests/test-loophabits.el` | 30 ERT tests: parsing, set-replaces, computed values, due-ness, score math, streaks, toggle cycles, archive, JSON/CSV round trips, widget tree/state, glyphs. |

## Core algorithms

Score. `loophabits-score` replays Loop's recurrence day by day from
the habit's creation date:

    multiplier = 0.5 ^ (sqrt(frequency) / 13)
    score      = previous * multiplier + checkmark * (1 - multiplier)

where `frequency` is freq-num/freq-den. `skip` and `q` days are
skipped entirely (uhabits' ScoreList.recompute semantics). For
non-numerical habits with frequency below 1, numerator and
denominator are doubled to smooth irregular schedules. For
measurable habits, a sliding window of the last `den` values feeds
a rolling sum; the daily "checkmark" is the fraction of the target
met (clamped to 1), and for at-most habits being under target is
the success state (initial score is 1.0, and the percentage is
`1 - over-target-ratio`, clamped). The final value is clamped to
0..1 and reported times 100. Complexity is one pass over the habit's
lifetime, but each day's `lh-computed-value` may call `lh-due-p`,
which scans all entries; with D days and E entries a score costs
O(D*E) worst case. Nothing is memoized across the dashboard's
per-habit score/streak calls.

Computed values. `lh-computed-value` maps a stored raw value onto
Loop's entry semantics: `skip`/`q` pass through; numbers pass
through for measurable types but become `yes`/`no` for yes/no
habits; a day with no entry is `auto` when before creation or (for
yes/no habits) when the quota was already met, else `no` (expected,
missed). Every consumer (completion, streaks, scores, grids) works
off these symbols, which is why the raw 1/0 never leaks.

Streaks. `loophabits-streaks` walks backward from today to the
creation date collecting runs of days where `lh-completed-p` holds.
Because non-due days compute as `auto` and `lh-completed-p` counts
`auto` as completed for yes/no habits, non-due days bridge streaks
automatically (Loop's behavior). The current streak is the newest
run, and only if it ends today or yesterday; older runs are history.
Measurable completion compares against the target (>= for
at-least, <= for at-most).

Entry writing. `loophabits-set` locates the habit heading by
regexp, finds the LOGBOOK (creating it after the PROPERTIES drawer
if absent), deletes any existing line for the date, inserts the new
one, saves, and force-reloads the cache. The LOGBOOK-after-
PROPERTIES ordering is load-bearing: Org only reads a property
drawer that directly follows the heading.

Toggle cycle. `loophabits-toggle` implements Loop's
nextToggleValue: for yes/no habits today's value cycles
none -> yes -> skip -> no -> yes; measurable habits jump between 0
and the target.

Reminders. A 60-second timer compares each active habit's
`:REMINDER: HH:MM` against the current minute. A reminder fires
only when the habit is due, uncompleted, unpaused, and has not
already been reminded today; the "already reminded" flag lives on
the habit name's symbol plist and is therefore per-Emacs-session.

## Invariants and gotchas

- Entries are proper 3-lists `(DATE VALUE NOTE)`. AGENTS.md forbids
  accessing them as dotted pairs (`(cdr entry)`); the accessors are
  `lh-entry-value` and `lh-entry-note` (or `nth`).
- LOGBOOK must come after the PROPERTIES drawer. `loophabits-set`
  preserves this when creating a LOGBOOK; hand edits that reorder
  them will hide properties from `org-entry-get`.
- `loophabits-set` must keep replacing (never duplicating) a date's
  entry and must `loophabits-load 'force` after writing. Both are
  repo law in AGENTS.md and are pinned by tests
  (`loophabits-set-replaces-not-duplicates`).
- The parse cache keys on `(mtime . file)` and nothing else. Any
  second source of truth (a database, an index file) is forbidden
  by AGENTS.md.
- Habit names are the identity. `loophabits-find` matches by exact
  name, the dashboard and widget carry names, and the reminder
  dedup state lives on name symbols. Renaming a heading orphans
  its widget arg and reminder flag.
- Parsing re-reads the whole file once per habit
  (`lh--parse-habit` opens the file in its own temp buffer inside
  the per-headline loop), so a full load is quadratic in practice:
  O(habits x filesize). Fine at the intended scale (a phone with
  dozens of habits); do not assume it scales to thousands.
- Score and streak computations are recomputed from scratch on
  every dashboard render and every reminder; see the O(D*E) note
  above before adding hot paths that call them repeatedly.
- `loophabits-archive` both moves the subtree under the Archive
  heading and sets the ARCHIVE tag. The parser only looks at the
  tag, so moving without tagging would leave the habit listed as
  active (the code comments say this explicitly).
- The once-per-day reminder flag is in-memory; after an Emacs
  restart in the same minute a reminder could theoretically fire
  twice. The timer also matches the HH:MM string exactly, so a
  suspended phone that skips the minute misses that day's reminder.
- `loophabits-import-json` uses `let*` (not `let`) so that
  `json-read-file` runs with `json-array-type` bound to `list`;
  with parallel `let` binding the backup would parse as vectors.
  The comment in the source explains this; keep it that way.
- The elwidget integration is a soft dependency in both
  directions: elwidget-org `declare-function`s
  `loophabits-elwidget-tree` / `loophabits-toggle`, and this
  package's widget functions are plain data producers that never
  require elwidget.
- Notification delivery picks the first available of
  `android-notifications-notify`, `notifications-notify`, or a
  plain `message`. Tests stay offline because nothing here calls
  them directly.

## Developing

Commands (Makefile):

- `make compile` - byte-compile with warnings as errors
  (`byte-compile-error-on-warn t`).
- `make test` - offline ERT suite: `emacs --batch -l tests/run.el`;
  21 tests, exit code 0/1.
- `make clean` - remove `.elc` files.

Requirements: Emacs 27.1+, no external packages (org and json are
built in). Tests stub nothing external; they write real temp Org
files.

Repo law (AGENTS.md): `make compile` and `make test` must stay
green before every push, and new features ship with tests in the
same commit. Behavioral changes to the score/streak math must cite
the Loop (uhabits) source in the commit message. Never commit
directly to `main`; work lands on `ai/main`, with
`ai/<topic>--<member-contraction>` branches for long work. No
timers tighter than the 60-second reminder tick without an Owner
order.
