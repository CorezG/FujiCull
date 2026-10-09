# ADR-001: Native Swift 6 + SwiftPM, no Xcode project, no third-party dependencies

## Status
Accepted (2026-10-09)

## Date
2026-10-09

## Context
FujiCull is a personal, non-sandboxed macOS 14+ app for Apple Silicon (A1, A2). It must be lightweight and must handle files on the card and SSD reliably. The development Mac has **Command Line Tools only** (Swift 6.3.3, no Xcode). Agents also edit this project in cloud containers that have no Swift toolchain, so the build definition must be plain text that is easy to diff.

## Decision
- Use Swift 6 (strict concurrency) and a single `Package.swift` with three targets:
  - `FujiCullCore` (library: Foundation + CryptoKit)
  - `FujiCullImaging` (library: ImageIO and CoreGraphics)
  - `FujiCullApp` (executable: SwiftUI + AppKit)
- No `.xcodeproj`. A `Makefile` builds the executable, assembles `build/FujiCull.app` from `Resources/Info.plist`, and ad-hoc signs it with `codesign --force --sign -`.
- Use Swift Testing for tests. Under CLT-only, `make test` passes the framework path explicitly. This was verified to work on this Mac:
  `swift test -Xswiftc -F -Xswiftc $CLT/Library/Developer/Frameworks -Xlinker -F -Xlinker $CLT/Library/Developer/Frameworks -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib`
  (`$CLT=/Library/Developer/CommandLineTools`). Plain `swift test` fails with `no such module 'Testing'`, and XCTest isn't available without Xcode.
- No third-party packages.

## Alternatives Considered

### Xcode project
- Pros: Instruments, the UI test runner, asset catalogs and signing UI.
- Cons: Needs Xcode, which isn't installed. The `.pbxproj` merges badly and can't be edited by an agent in the cloud.
- Rejected for v1. It can be added later; the package will still build from Xcode.

### Electron or Tauri
- Pros: cross-platform.
- Cons: heavy, worse image decoding and memory use, and awkward low-level file APIs (`F_NOCACHE`, `renamex_np`, Finder tags).
- Rejected: it goes against the "lightweight" requirement and the macOS-only scope.

## Consequences
- Core logic is testable with `make test` on this Mac.
- There is no XCUITest and no Instruments. Performance is checked with `os_signpost` and logging, and the UI with a manual checklist.
- The ad-hoc signature changes on every rebuild, so macOS may ask again for access to removable volumes.
- If Xcode is installed later, nothing about the package has to change.
