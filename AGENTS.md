# AGENTS.md — local law for agents working in loophabits

This file adds repo-local rules on top of the Owner's GLOBAL AGENTS.md
(the copy in agent-team-ci).  Where the two disagree, the GLOBAL file
wins.

## Identity law (same as global)

- Commit author: `MODEL <MODEL@PROVIDER>` (e.g.
  `GLM 5.3 <glm-5.3@z.ai>`).  Never a harness/container identity.
- Both trailers on every commit:
  `Co-authored-by: Z.ai agent <agent@chat.z.ai>` and
  `Co-authored-by: Khalid Rafi <khaalidrafi@gmail.com>`.
- Never commit directly to `main`.  Work lands on `ai/main`; use
  `ai/<topic>--<member-contraction>` branches for long work.

## Repo rules

- Pure Elisp only: no external Emacs packages — org and json are
  built-in.  Must keep working on Linux, TTY and Android unchanged.
- Storage is ONE plain org file; the on-disk format (property
  drawers + LOGBOOK entry lines) is the compatibility contract.
  Never introduce a database, a cache file or a second source of
  truth.  The parse cache keys on mtime and nothing else.
- The score/streak/computed-value semantics must stay the uhabits
  recurrences (multiplier 0.5^(sqrt(freq)/13); skip/q excluded;
  non-due days auto-bridge).  Behavioral changes to that math need
  the Loop source cited in the commit message.
- Entries are proper 3-lists (DATE VALUE NOTE); accessors are
  `lh-entry-value`/`lh-entry-note` — never `(cdr entry)`.
- LOGBOOK always goes AFTER the PROPERTIES drawer: Org only reads a
  property drawer that directly follows the heading.
- `loophabits-set` must keep replacing (never duplicating) a date's
  entry, and must `loophabits-load 'force` after writing.
- `make compile` (warnings are errors) and `make test` (offline ERT,
  currently 21 tests) must stay green before every push.  New
  features ship with tests in the same commit.
- Keep it simple and light: this runs on a low-spec phone (Redmi
  8A-class).  No timers tighter than the 60 s reminder tick without
  an Owner order.
