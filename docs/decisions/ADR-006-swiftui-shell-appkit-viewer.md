# ADR-006: SwiftUI app shell with AppKit viewer, filmstrip and grid

## Status
Accepted (2026-10-09)

## Date
2026-10-09

## Context
The interaction is keyboard-first: arrow keys with auto-repeat, single unmodified keys, and smooth 100% zoom that follows the mouse. The views have to handle 2,000 thumbnails. SwiftUI's key handling (`onKeyPress`, focus) and lazy stacks have been unreliable for repeat-heavy, large-collection use on macOS 14. The rest of the app (menus, settings, sheets for the Apply flow) is ordinary UI where SwiftUI is the most concise option.

## Decision
- SwiftUI provides the `App`, `.commands` menus, `Settings`, the Apply sheets, and the overlay (in an `NSHostingView`).
- AppKit provides:
  - `ViewerView`, a layer-backed `NSView` that overrides `keyDown`
  - `FilmstripView` and `GridView`, both `NSCollectionView`
- These are hosted through `NSViewControllerRepresentable`.
- Keys and menu items all go through one `CullModel.perform(AppCommand)`. Spike S5 decides which layer actually receives unmodified arrow keys, so that each command fires exactly once.

## Alternatives Considered

### Pure SwiftUI
- Pros: less bridging code.
- Cons: less control over key repeat and first responder, and the performance of `LazyHGrid` with 2,000 items is uncertain.
- Rejected for the hot path.

### Pure AppKit
- Pros: full control.
- Cons: more boilerplate for menus, settings and sheets.
- Rejected: SwiftUI is fine for those parts.

## Consequences
- There is a thin bridging layer to maintain.
- Every interaction rule lives in Core or `CullModel`, so the UI framework doesn't affect testability.
- **Spike S5 result (2026-10-09, T8):** every key is both a SwiftUI menu shortcut (including unmodified arrows, `/`, `.`, `'`, ⌫, Return) and handled in `ViewerNSView.keyDown`. Both routes call `CullModel.perform`, and the owner confirmed on the real card that **each key fires exactly once**, and that holding → still repeats. A key consumed as a menu shortcut never reaches `keyDown`, so there's no double dispatch. Culling menu items must be disabled while a text field is focused (the Apply sheet, T21), so `/`, `.` and the arrows can be typed there.
