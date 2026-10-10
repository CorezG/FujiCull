# Constraints

Last reviewed: 2026-10-09 by CorezG (set in the constraint-driven-development interview).

The quality bar for FujiCull. Every rule names the command that checks it. All checks **block**: a task is not
done, and nothing is committed, until they pass. Tightening a rule needs no discussion. Loosening one needs
the owner's explicit approval in its own commit, never in the same commit as the code that was failing.

## Floor (always enforced)

Checked on the diff by `scripts/floor-guard.py`.

- No new suppressions: `swift-format-ignore`, `swiftlint:disable`, `#if false`, `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency import`, or compiler flags that hide warnings
- No unfinished work: `fatalError("not implemented")` style stubs, an empty `catch { }`, `TODO`/`FIXME` in code, or `try? FileManager` (a file error swallowed)
- No easier tests: no `.disabled`, `withKnownIssue`, `XCTSkip`, no deleted test file, and no assertion (`#expect`, `#require`, `XCTAssert`) removed from a test that stays
- No secrets in source
- This file is not weakened to make a change pass

## Enforced with numbers

| Dimension | Rule | Checked by | Runs at |
|-----------|------|-----------|---------|
| Format | Zero findings | `swift format lint --strict --recursive Sources Tests` | task end |
| Compiler | Zero warnings, Swift 6 strict concurrency | `swift build -Xswiftc -warnings-as-errors` | task end |
| Floor | Zero violations in the diff | `scripts/floor-guard.py` | task end, before every commit |
| Architecture | Core imports no UI or image frameworks; Imaging imports no UI; only `FujiCullCore/Apply/` deletes, moves, trashes or renames files; only `Apply/` and `Persist/` write files | `scripts/check-boundaries.sh` | task end |
| Tests | Every test passes | `make test` | task end |
| Safety coverage | Files in `FujiCullCore/Apply/` and `FujiCullCore/Persist/` at least 95% of lines covered | `scripts/check-coverage.py` | task end |
| Changed-code coverage | Each changed Swift file in `FujiCullCore` or `FujiCullImaging` at least 80% of lines covered | `scripts/check-coverage.py` | task end |
| Task-end time | Whole task-end check at most 90 seconds; slower tests move to the checkpoint run, never deleted | timed by `make check` | task end |
| Speed: open card | First image under 2 s on Fuji SD (2,091 frames) | debug timing overlay (T15), by hand | Checkpoint C onward |
| Speed: next frame | Under 100 ms when prefetched | debug timing overlay (T15), by hand | Checkpoint C onward |
| Speed: 100% zoom | Under 300 ms when prefetched | debug timing overlay (T15), by hand | Checkpoint C onward |

Why these numbers:
- **95% on Apply and Persist:** this is the code that can lose photos or marks. Fault-injection tests are planned for every branch (ADR-003), so near-full coverage is reachable.
- **80% on other changed code:** high enough to force a test with every change, low enough to leave room for glue code.
- **UI code is not counted:** it can't be driven automatically without Xcode (ADR-001). The manual checklist (T24) covers it.
- **90 seconds:** past that, people start skipping the check.
- **Speed budgets:** taken from the REQUIREMENTS §5 NFRs and measured on the real card and reader.

External opinions in this bar (not judged by our own tests): the Swift compiler's strict concurrency checking, `swift format`, and speed measured on real hardware.

Not machine-checkable, so reviewed by a human at Checkpoint D: **every failure path in Apply has a fault-injection test** (DESIGN §9).

## Measured, not yet enforced

| Metric | Today | Direction |
|--------|-------|-----------|
| Core + Imaging line coverage | 94.2% (568/603 lines) at Checkpoint A, 2026-10-09 | must not fall (0.5% tolerance) |
| Task-end check duration | 9 s at Checkpoint A, 2026-10-09 | must not grow past 90 s |

## Where each check runs

| Stage | Command | Runs | Budget |
|-------|---------|------|--------|
| Task end | `make check` | format, compiler, floor, boundaries, tests, coverage | at most 90 s |
| Before commit | `scripts/floor-guard.py` | floor on everything unpushed | seconds |
| Checkpoint | `make check-full` | everything above plus slow tests, then the manual speed and UI checklists | no limit |

There's no CI yet: GitHub's macOS runners could run `make check-full` later (ci-cd-and-automation skill).

## Exceptions

| ID | Rule | Path | Reason | Owner | Expires |
|----|------|------|--------|-------|---------|
