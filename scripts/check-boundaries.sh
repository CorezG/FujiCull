#!/bin/sh
# check-boundaries: architecture rules from CONSTRAINTS.md (see DESIGN §4 and §9).
# exit 0 clean, 1 violation, 2 could not run.
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-boundaries: not in a git work tree" >&2; exit 2; }

fail=0
report() { echo "  [$1] $2" >&2; fail=1; }

scan() { # scan <dir> <regex> <rule> [exclude-dir-regex]
  [ -d "$1" ] || return 0
  find "$1" -name '*.swift' -type f | while read -r f; do
    if [ -n "$4" ] && echo "$f" | grep -Eq "$4"; then continue; fi
    grep -nE "$2" "$f" | grep -vE '^\s*[0-9]+:\s*//' | sed "s|^|$f:|"
  done | while read -r hit; do echo "$3|$hit"; done
}

hits=$(
  # 1. Core is pure: Foundation, CryptoKit, Darwin only.
  scan Sources/FujiCullCore '^\s*import\s+(AppKit|SwiftUI|ImageIO|CoreGraphics|QuartzCore|UniformTypeIdentifiers|Cocoa)\b' core-imports-ui
  # 2. Imaging has no UI.
  scan Sources/FujiCullImaging '^\s*import\s+(AppKit|SwiftUI|Cocoa)\b' imaging-imports-ui
  # 3. Only the Apply engine may delete, trash, move or rename files.
  # C's remove() deletes a path; collection methods like cache.remove(key) or pending.remove(at:) don't, so only
  # a bare or module-qualified remove( whose argument mentions a path counts.
  scan Sources '(removeItem|trashItem|moveItem|replaceItemAt|\bunlink\(|(^|[^.A-Za-z0-9_]|Darwin\.|Foundation\.)remove\([^)]*[Pp]ath|\brename\(|renamex_np|removefile|\brmdir\()' destructive-outside-apply 'Sources/FujiCullCore/Apply/'
  # 4. Only Apply and session persistence may write files.
  scan Sources '(\.write\(to:|createFile\(|forWritingTo|forUpdating|\bopen\(.*O_(WRONLY|RDWR|CREAT))' write-outside-apply-or-persist 'Sources/FujiCullCore/(Apply|Persist)/'
)

if [ -n "$hits" ]; then
  echo "check-boundaries: violation(s):" >&2
  echo "$hits" | while IFS='|' read -r rule loc; do echo "  [$rule] $loc" >&2; done
  exit 1
fi
echo "check-boundaries: clean"
exit 0
