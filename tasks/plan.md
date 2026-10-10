# Implementation Plan: FujiCull v1

_2026-10-09. Source of truth: [docs/REQUIREMENTS.md](../docs/REQUIREMENTS.md) (what) and
[docs/DESIGN.md](../docs/DESIGN.md) + [ADRs](../docs/decisions/) (how). Tasks live in
[todo.md](todo.md)._

## Overview

Build FujiCull in six phases, each ending at a checkpoint where something real can be tried. The order follows DESIGN §4.1 (`scan` → `session` → `persist` → `imaging` → `viewer` → `apply`), with two adjustments:

- **Something to browse comes early.** Phase 1 is a thin vertical slice: open a folder and browse its JPGs with arrow keys. This tests the riskiest unknowns first: card throughput, decode speed and key handling.
- **The Apply core is built and tested on its own** (Phase 4) before any Apply UI exists, because it's the only destructive code path and its tests don't need a GUI.

## Architecture decisions (summary)

- Native Swift 6 + SwiftPM + Makefile, CLT-only, Swift Testing, no third-party dependencies (ADR-001).
- JPEG-first previews in three tiers through one card reader, memory-only caches (ADR-002).
- Apply = a pure planner plus a journaled copy → verify → tag → confirm → remove → delete executor (ADR-003). Archive copies of frames rejected later go to the SSD's Trash (D6, R26).
- Frames are ordered by DCIM folder, then filename (ADR-004).
- One JSON session file per card in Application Support (ADR-005).
- SwiftUI shell with an AppKit viewer, filmstrip and grid (ADR-006).

## Task index

| Phase | Tasks | Ends with |
|---|---|---|
| 0 Scaffold | T1 | An empty app launches; `make test` is green |
| 1 Browse slice | T2–T6 | **Checkpoint A:** open a folder or card and browse with ← → |
| 2 Culling | T7–T10 | **Checkpoint B:** cull a whole folder, quit, relaunch, resume |
| 3 Viewing polish | T11–T15 | **Checkpoint C:** grid, zoom, EXIF, orphans; performance targets measured |
| 4 Apply core | T15a, T16–T20 | **Checkpoint D:** the Apply engine is proven by fault-injection tests |
| 5 Apply UI + rehearsal | T21–T24 | **Checkpoint E:** a full Apply rehearsal against a folder copy of a real card |

## Dependency graph

```
T1 ─┬─ T2 ─┬─ T4 ── T5 ── T6 ─┬─ T8 ── T10 ── T11
    │      │                  │        │
    │      └─ T7 ─────────────┘        ├─ T12, T13*, T14*, T15
    │             └─ T9 ───────────────┘
    │
    └─ T3 (spike: needs SD card)              * = needs sample files (Q4)

T2, T7, T9 ─ T16 ─ T17 ─ T18 ─ T19 ─ T20 ─┬─ T21 ─ T22 ─ T24
                       T23 (spike: SSD) ──┘
```

## Parallelization

- Once T2, T7 and T9 are done, the **Apply core (T16–T20) doesn't depend on any UI**. It can run in parallel with Phases 2 and 3, in a separate session or worktree.
- T3 (card spike) and T23 (SSD spike) need your hardware and can run whenever it's at hand.
- T13 and T14 wait for sample files (Q4). Everything else can proceed without them, using synthetic test JPEGs generated with ImageIO.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Card I/O slower than expected; next frame takes over 100 ms | Med | T3 measures it early. Prefetch depth is tunable. MPF preview is a fallback (S1). |
| Unmodified arrow and Return keys misrouted between SwiftUI menus and AppKit | Med | Spike S5 inside T8, before the UI grows. |
| Apply bug loses photos | **High** | Phases 4 and 5 are test-first. Fault injection asserts that nothing is deleted from the card on any failure. A rehearsal against a folder copy comes before the first real card (T24). |
| Film simulation not decodable | Low | Show "—" (T13). |
| exFAT SSD: no `RENAME_EXCL`, `._` files for tags | Med | Fallback built into T16. T23 confirms the format. |
| Sample files late | Low | Only T13 and T14 are blocked. Synthetic fixtures cover everything else. |

## Open questions

- Q4: sample X-T50 files are coming later. They block T13 and T14.
- Q6: SSD format unknown. T23 resolves it.
