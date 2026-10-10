# FujiCull — Session Handoff

## Where we stopped (2026-10-10, evening)

**Read this section first.** The original requirements-session handoff is kept below for history.

- **Phases 0–3 are done, and phase 4 (the Apply core) is built: T15a and T16–T20.** Nothing is wired to the app yet, so FujiCull still cannot copy or delete anything.
  - The design had a third doubt review ([review](reviews/2026-10-09-apply-doubt-review.md)), and the exFAT behaviour it relies on was measured on a throwaway disk image ([spike](spikes/2026-10-10-exfat-fskit.md)). DESIGN §5.7 is the current design (rules SR1–SR28).
  - Code is in `Sources/FujiCullCore/Apply/`: `FileSystem` + `LocalFileSystem`, `SafeCopy`, `Ledger` + `LedgerJournal`, `ApplyPlanner` + `ApplyPlan`, `ApplyExecutor` (+ `ApplyExecutor+Remove`), `ApplySummary`.
  - 385 tests. Tests use `FaultyFileSystem` (fails or "unplugs" at any call) and `ApplyWorld` (a card, an archive and a journal in temp folders).
- **Paused mid-T21/T22 (2026-10-10, late).** Checkpoint D was accepted by the owner (code review skipped at their request). Built and committed, **compiles and passes `make check`, but never yet run by hand**:
  - Core: `ApplyRun` (the object the screens drive), `CullSession.removing`, `Ledger.framesDeletedFromCard`, `ArchiveLock`, `SessionStore.ledgerURL` — all tested (406 tests).
  - App: `Sources/FujiCullApp/Apply/ApplyModel.swift` and `ApplySheet.swift` (setup, pre-flight, copying, confirm, summary, failed), an **Apply…** toolbar button and File menu item (⌘↩), wiring in `CullModel` (`beginApply`, `applySetup`, `applyFinished`, culling frozen while the sheet is open, unmount cancels the copy), sleep assertion, Reveal and Eject buttons.
  - **Next:** `make run`, open the **throwaway card** (never Fuji SD), and walk the sheet with a temp folder or a test folder on C&J Archive as the archive; fix what the first hands-on run shows; add the ⌘↩ row to the REQUIREMENTS keymap; then tick T21/T22, write T23's note (the exFAT spike already answers it) and `docs/TESTING.md` (T24), and rehearse.
  - The installed app in `build/` is still the pre-Apply build.
- **Hardware for the rehearsal:** an 8 GB throwaway card, formatted in the X-T50, with 27 RAW+JPEG pairs. It reads at 22 MB/s and has **no volume UUID** (FAT32 formatted in camera), so it is keyed `card-<capacity>-<format time>`. The owner is also backing up the real card ("Fuji SD") to C&J Archive by hand. **Apply must not run on Fuji SD until the owner says its photos are safe.**
- **Not done inside the executor yet, for phase 5 to wire up:** building `ApplyExecutor.Context` from the live session (the app must wait for the metadata pass so every capture time is known), looking up `archiveRoots` by volume UUID, the archive lock (SR3), freezing culling during Apply (SR6), dropping undo entries for deleted frames (SR21), `VolumeMonitor` cancellation and the sleep assertion (R23), and the Eject buttons (SR20). For a card with no volume UUID the executor relies on the per-file size-and-date checks; the app should compare the session key again before starting.
- **Reading the timing log:** `/usr/bin/log show --last 30m --style compact --predicate 'subsystem == "com.github.corezg.FujiCull" AND category == "timing"'`. Use the full path: in zsh, `log` is a shell builtin. Lines are `open`, `move`, `zoom` (with read/decode split) and `hold`.
- **Open items:**
  - **One intermittent test-run crash** (signal 5) during T13. It didn't reproduce in 33 reruns. Watch for it.
  - **T3, one check left:** whether an in-camera format changes the UUID of the 256 GB exFAT card. Nothing depends on it now (capture time is part of frame identity). Known: the X-T50's FAT32 format of a small card writes no volume UUID at all.
  - **Another session of the owner's** added an app icon (`Resources/AppIcon.*`, `scripts/make-icon.swift`, edits to `Makefile` and `Info.plist`) and a `graphify-out/` folder. They are uncommitted and were left alone.
  - **The scanner speed test** (`scansTwoThousandPairsInUnder200Milliseconds`) fails at 200–203 ms when the Mac is busy (seen during the owner's 200 GB Finder copy). It passes on a quiet machine; it was not changed.
  - Locally installed skills (`.claude/skills/`, `.agents/`, `skills-lock.json`) are gitignored by the owner's choice; the coverage baseline was raised to 95.9% with approval (2026-10-10).
- **Working agreements:**
  - Rebuild and relaunch the app (`make app && open build/FujiCull.app`) after every change, so Finder and the Dock get the latest build.
  - Gate commits on `make check`'s real exit status, never through a pipe.
  - The owner prefers native data only; recipe-name inference was declined.
  - Spec changes go into REQUIREMENTS with an "amended" note: R12 (zoom resets on move), R26/R27, Esc, scroll zoom, double-click.
  - A fix isn't verified until the behaviour around it is checked too: the first strip scroll-bar fix removed the warning and stopped the strip scrolling (2026-10-10).
  - Fuji cameras only for now (owner, 2026-10-10). The raw file's role is named `raw` in the Apply code so other formats can be added later.
  - After writing safety code, break its rules one at a time and confirm a test fails (17 such checks so far, listed in the checkpoint D note).

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
