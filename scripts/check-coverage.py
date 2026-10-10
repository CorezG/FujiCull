#!/usr/bin/env python3
"""check-coverage: coverage rules from CONSTRAINTS.md.

Reads the llvm-cov JSON that `swift test --enable-code-coverage` already wrote
(no second test run). Rules:
  * Safety-critical files (Sources/FujiCullCore/Apply/, Sources/FujiCullCore/Persist/): >= 95% lines.
  * Every changed Swift file in FujiCullCore or FujiCullImaging: >= 80% lines.
  * FujiCullApp (UI) is not counted; it is covered by the manual checklist.
Prints the overall Core + Imaging line coverage for the ratchet in CONSTRAINTS.md.

Usage: scripts/check-coverage.py [--json <codecov.json>] [--base <ref>]
exit 0 clean, 1 below threshold, 2 could not run.
"""
import json
import os
import subprocess
import sys

SAFETY_DIRS = ("Sources/FujiCullCore/Apply/", "Sources/FujiCullCore/Persist/")
COUNTED_DIRS = ("Sources/FujiCullCore/", "Sources/FujiCullImaging/")
SAFETY_MIN = 95.0
CHANGED_MIN = 80.0


def bail(msg):
    print("check-coverage: " + msg, file=sys.stderr)
    sys.exit(2)


def run(args):
    p = subprocess.run(args, capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def arg(name):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else bail(name + " needs a value")
    return None


top = run(["git", "rev-parse", "--show-toplevel"]) or bail("not inside a git work tree")
os.chdir(top)

path = arg("--json") or run(["swift", "test", "--show-codecov-path"]) or bail("no coverage path")
if not os.path.exists(path):
    bail("no coverage data at %s; run `make test` (it passes --enable-code-coverage) first" % path)
data = json.load(open(path))

files = {}
for f in data["data"][0]["files"]:
    rel = os.path.relpath(f["filename"], top)
    if rel.startswith(COUNTED_DIRS):
        lines = f["summary"]["lines"]
        files[rel] = (lines["covered"], lines["count"])

base = arg("--base") or run(["git", "rev-parse", "--abbrev-ref", "@{upstream}"]) or "HEAD"
mb = run(["git", "merge-base", base, "HEAD"]) or bail("no merge base against " + base)
changed = set((run(["git", "diff", "--name-only", mb, "--"]) or "").split("\n"))
changed |= set((run(["git", "ls-files", "--others", "--exclude-standard"]) or "").split("\n"))

pct = lambda c, n: 100.0 if n == 0 else 100.0 * c / n
fails = []
for rel, (c, n) in sorted(files.items()):
    p = pct(c, n)
    if rel.startswith(SAFETY_DIRS) and p < SAFETY_MIN:
        fails.append("[safety-coverage] %s: %.1f%% < %.0f%%" % (rel, p, SAFETY_MIN))
    elif rel in changed and p < CHANGED_MIN:
        fails.append("[changed-coverage] %s: %.1f%% < %.0f%%" % (rel, p, CHANGED_MIN))

tc = sum(c for c, _ in files.values())
tn = sum(n for _, n in files.values())
print("check-coverage: Core + Imaging line coverage %.1f%% (%d/%d lines, %d files)"
      % (pct(tc, tn), tc, tn, len(files)))
if fails:
    print("check-coverage: below threshold:", file=sys.stderr)
    for f in fails:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
print("check-coverage: clean")
sys.exit(0)
