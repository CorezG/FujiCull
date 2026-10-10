# FujiCull — Session Handoff

## Where we stopped (end of day, 2026-10-09)

**Read this section first.** The original requirements-session handoff is kept below for history.

- **Phases 0–2 are done; phase 3 is code-complete.** Checkpoints A (browse) and B (culling, filmstrip, resume) were passed on the real card. T11 grid, T12 zoom, T13 EXIF + film simulation and T14 RAF-only frames are confirmed by the owner. **T15** (smoother holding of arrows, the strip layout warning fix, open/zoom timing) is built in `e2fe1b9` but not yet verified.
- **Next step: the checkpoint C test run.** The owner closes any open source (⇧⌘W), opens Fuji SD, turns on View → Show Timings (⌥⌘T), steps ~20 photos, zooms 3–4, holds → for 5–10 s, then reports. Then:
  1. Read the timings with `/usr/bin/log show --last 30m --info --style compact --predicate 'subsystem == "com.github.corezg.FujiCull"'`. Use the full path: in zsh, `log` is a shell builtin.
  2. Check that `processID == <pid> AND eventMessage CONTAINS "behavior of the"` returns no strip layout warnings.
  3. Write `docs/spikes/perf.md` against the NFRs: open < 2 s, next frame < 100 ms, zoom < 300 ms. The last run already showed key→photo median 14 ms, p90 25, 72/75 preloaded.
  4. Tick T15 and checkpoint C in `tasks/todo.md`.
- **Then phase 4 (Apply engine).** Run doubt-review round 3 on DESIGN §5.7 first (fresh Claude subagent; the owner has no other models), then T16–T20 test-first.
- **Open items:**
  - **One intermittent test-run crash** (signal 5) during T13. It didn't reproduce in 33 reruns. Watch for it.
  - **T3 hands-on checks:** the SD lock switch (read-only detection), and the volume UUID after an in-camera format.
  - **Coverage baseline:** the owner hasn't approved raising it from 94.2% (now ~96%). CONSTRAINTS.md changes need explicit approval (kept loud).
  - **`.claude/skills/`, `.agents/` and `skills-lock.json`** are still uncommitted; the owner hasn't decided.
- **Working agreements learned today:**
  - Rebuild and relaunch the app (`make app && open build/FujiCull.app`) after every change, so Finder and the Dock get the latest build.
  - Gate commits on `make check`'s real exit status, never through a pipe.
  - The owner prefers native data only; recipe-name inference was declined.
  - Spec changes go into REQUIREMENTS with an "amended" note: R12 (zoom resets on move), R26/R27, Esc, scroll zoom, double-click.

---

_Written 2026-10-09 at the end of the requirements-gathering session. Read this first in a new session._

## TL;DR

- **Product:** a lightweight, keyboard-driven macOS app to cull Fujifilm X-T50 RAW+JPEG shoots **straight from the SD card**, offload keepers to an external SSD, and delete rejects from the card.
- **Status:** requirements are **agreed and signed off** → [`docs/REQUIREMENTS.md`](REQUIREMENTS.md) is the source of truth. All four assumptions (A1–A4) were confirmed.
- **Next step:** technical design (not started — no `docs/DESIGN.md` yet, no code).
- **Branch:** `claude/focused-faraday-3idg5b` (no PR opened).

## How we got here (interview summary)

Three interview rounds, PM-style. Key facts and the reasoning behind each decision:

| Topic | What the user said | Resulting decision |
|---|---|---|
| Real workflow | 90% of the time picks JPGs (film-sim recipes) and uploads them to Google Photos; RAW edits in Fuji's app are rare; archives everything to an external SSD. No Lightroom/Capture One. | The **JPG is what gets judged**; the RAF just follows its JPG. No XMP/LR integration. |
| Volume | 1,500–2,000 frames per trip (~150–200 GB as uncompressed RAF ≈ 80 MB + JPG ≈ 15–20 MB). | Performance and storage design matter. |
| Disk space | 13" MacBook Air M2, upgraded RAM, **≤ 10 GB free** (often less). | **Never import the whole card.** Cull from the card; keep Mac-side cache tiny. |
| Transfer speed | Camera-over-USB felt slow. | Use a **UHS-I card reader** (~90 MB/s). Culling JPGs directly from card is fast enough with prefetch. |
| Camera | X-T50, single SD slot, uncompressed RAW + JPEG. Never more than one card per trip. | Pair by base name in same folder; single-card sessions. (Tip given: lossless-compressed RAW halves size — user's call, not a requirement.) |
| Keepers | Only keepers (RAF + JPG) go to the external SSD. | Archive = keepers only. |
| Google Photos | Folder is fine for v1; upload later. | `Google Photos/` folder **on the SSD** (keeper JPGs would fill the Mac's free space). |
| Rejects | OK to delete from the card when culling from it. | Permanent delete from card, **only after keepers are copied and checksum-verified**, behind a confirmation (default = Cancel). macOS Trash isn't used — on an SD card it just hides files on the card. |
| States | Likes keep/reject plus an "undecided" state and a ♥ favourite. | Keep / Reject / Undecided + ♥ Favourite (implies Keep). |
| Favourites | — | Shown as a **Finder tag "Favourite"** on archived files. No separate folder. |
| Undecided at Apply | — | **Left on the card untouched**, with a warning count. |
| Keyboard | ↑ keep, ↓ discard, ←/→ browse without deciding; everything else near the arrows for one-handed use; auto-advance yes. | Full keymap in REQUIREMENTS §4.3 (`/` ♥, `.` reset, Return zoom, `'` undecided filter, ⌫ undo, Shift+←/→ jump 10, G grid, I EXIF). |
| Layout | — | Single large image + filmstrip; grid toggle; no compare view in v1. Overlay with filename/state/progress; toggleable EXIF line. |
| Bursts | Not needed. | No stacking. |
| Resume | — | Marks auto-saved on the Mac, keyed to the card; resume after eject. |
| SSD layout | — | `FujiCull Archive/YYYY/YYYY-MM-DD <Trip>/` (RAF+JPG together) + `Google Photos/` subfolder. Date = earliest capture on card. |
| Platform | — | macOS 14+, Apple Silicon, personal non-sandboxed build. |

Out of scope for v1: Google Photos upload, compare view, bursts, ratings/XMP, editing, camera-USB import, multi-card, key remapping, App Store.

## Tooling set up in this repo

- **agent-skills** (`addyosmani/agent-skills`) — enabled via `.claude/settings.json` (`extraKnownMarketplaces` + `enabledPlugins`). It did **not** auto-install in the follow-up session (`claude plugin list` showed none). If it's still missing, run in Claude Code:
  ```
  /plugin marketplace add addyosmani/agent-skills
  /plugin install agent-skills@addy-agent-skills
  ```
  Relevant skills for the next phase: `spec-driven-development` (Plan phase), `planning-and-task-breakdown` (→ `tasks/plan.md`, `tasks/todo.md`), `documentation-and-adrs` (→ `docs/decisions/ADR-NNN-*.md`).
- **Graphify** — `/graphify` skill committed at `.claude/skills/graphify/`, plus notes in `CLAUDE.md` and `.claude/CLAUDE.md`. The CLI is **not** in the repo: install with `uv tool install graphifyy` in each environment. Graphify's PreToolUse hooks were **deliberately left out** (they'd error wherever the CLI isn't installed, and there's no code to graph yet). Re-run `graphify install --project` once there's Swift code. There is no `graphify-out/` yet, so the CLAUDE.md "query the graph first" rules don't apply until one is built.
- **Ponytail** — dropped at the user's request.
- **Permissions** — the cloud session's Auto mode refused installers and edits to `.claude/`; use **Accept edits** mode (or Plan → approve) for that kind of step.
- The cloud container has **no Swift toolchain**, so building/testing the app has to happen on the Mac (or a macOS CI runner).

## Technical design: starting notes (not yet agreed — for discussion)

Draft direction I was about to propose; treat as input, not decisions:

1. **Stack:** Swift 6, SwiftUI shell + an AppKit `NSView` for the viewer (reliable keyDown/auto-repeat, smooth zoom). No third-party dependencies.
2. **Build:** Swift Package with a pure-Foundation `FujiCullCore` library (pairing, decisions, session persistence, Apply planner) + macOS app target; a `make app` script assembles and ad-hoc signs `FujiCull.app`. Core stays unit-testable without AppKit.
3. **Preview pipeline (ImageIO):** EXIF thumbnail for the filmstrip (reads only the file header) → downsampled-to-screen JPG decode for display → full decode only for 100% zoom (one at a time). Prefetch next 3 / previous 1; cancel stale loads. In-memory caches only, so the 500 MB disk cap is trivially met. Card read speed (~5 full JPGs/s) is the bottleneck. **Spike:** check whether X-T50 JPGs carry a larger MPF preview usable as a fast middle tier.
4. **Ordering:** by DCIM folder then filename (chronological on one card, and handles the DSCF9999 wrap because the folder number increments). Avoids an EXIF pre-scan.
5. **Session persistence:** JSON in `~/Library/Application Support/FujiCull/`, keyed by volume UUID (fallback: hash of file list), debounced atomic writes. Undo stack in memory.
6. **Apply engine (safety-critical):** pure planner → executor. Copy to a temp name, verify by reading back with `F_NOCACHE` (so the check hits the disk, not RAM) and comparing hashes, then rename without overwriting. A journal makes re-runs resumable. Copy Google Photos JPGs from the verified SSD copy, not the card. Set Finder tags via `URLResourceValues.tagNames`. Before deleting each reject, re-check it's unchanged. Cancel on unmount (NSWorkspace notifications).
7. **Risks to check early:** film-simulation name may not be exposed by ImageIO's Fuji MakerNote dictionary (fallback: omit it); Finder tags on an exFAT SSD create `._` files (APFS-formatted SSD recommended); 40 MP full decode is about 160 MB for 100% zoom.
8. **Proposed ADRs:** native Swift + SPM (no xcodeproj); JPEG-first preview pipeline with no disk cache; journaled copy → verify → delete; folder+filename ordering.

## Suggested opening prompt for the new session

> Read `docs/HANDOFF.md` and `docs/REQUIREMENTS.md`. Using the agent-skills workflow (`spec-driven-development` → Plan phase), write the technical design for FujiCull as `docs/DESIGN.md` with ADRs in `docs/decisions/`, starting from the "Technical design: starting notes" in the handoff. Surface assumptions and open questions, then stop for my review before breaking it into tasks.
