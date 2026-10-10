#!/usr/bin/env python3
"""floor-guard: diff-scoped enforcement of the CONSTRAINTS.md floor.

Ported from the constraint-driven-development reference (references/floor-guard.md),
with the patterns adapted to Swift. Contract is unchanged:

  exit 0  clean
  exit 1  at least one floor violation (block the change)
  exit 2  the guard could not run (never read this as clean)

Usage: scripts/floor-guard.py [--base <ref>]
Default base: the branch's upstream if it has one, otherwise HEAD
(so uncommitted and unpushed work is always covered).
Reports the rule and location only, never a matched secret value.
"""
import os
import re
import subprocess
import sys


def git(args, diff_exit=False):
    """Run git; return stdout, or None on failure. `git diff --no-index` exits 1 on difference."""
    p = subprocess.run(["git"] + args, capture_output=True, text=True)
    if p.returncode == 0 or (diff_exit and p.returncode == 1):
        return p.stdout
    return None


def bail(msg):
    print("floor-guard: " + msg, file=sys.stderr)
    sys.exit(2)


top = git(["rev-parse", "--show-toplevel"])
if not top:
    bail("not inside a git work tree")
os.chdir(top.strip())

base = None
if "--base" in sys.argv:
    i = sys.argv.index("--base")
    if i + 1 >= len(sys.argv):
        bail("--base needs a ref")
    base = sys.argv[i + 1]
else:
    up = git(["rev-parse", "--abbrev-ref", "@{upstream}"])
    base = up.strip() if up else "HEAD"

merge_base = git(["merge-base", base, "HEAD"])
if not merge_base:
    bail("no merge base against " + base)
merge_base = merge_base.strip()

tracked = git(["diff", "--unified=0", merge_base, "--"])
if tracked is None:
    bail("could not diff against " + merge_base)
untracked_list = git(["ls-files", "--others", "--exclude-standard"])
if untracked_list is None:
    bail("could not list untracked files")
parts = [tracked]
for f in filter(None, untracked_list.split("\n")):
    d = git(["diff", "--no-index", "--unified=0", "/dev/null", f], diff_exit=True)
    if d is None:
        bail("could not diff untracked file " + f)
    parts.append(d)
diff = "\n".join(parts)

# Walk the diff. ---/+++ are headers only between a `diff` line and the first @@ hunk.
added, removed, deleted = [], [], []
path_of = lambda s: re.sub(r"^[ab]/", "", s)
file_ = old_file = ""
in_header = False
for line in diff.split("\n"):
    if line.startswith("diff "):
        in_header = True
    elif line.startswith("@@"):
        in_header = False
    elif in_header:
        if line.startswith("--- "):
            old_file = path_of(line[4:])
        elif line.startswith("+++ "):
            new_file = path_of(line[4:])
            file_ = old_file if new_file == "/dev/null" else new_file
            if new_file == "/dev/null":
                deleted.append(file_)
    elif line.startswith("+"):
        added.append((file_, line[1:]))
    elif line.startswith("-"):
        removed.append((file_, line[1:]))

findings = []


def flag(rule, f, text):
    findings.append((rule, f, text.strip()[:120]))


GUARD_SELF = ("scripts/floor-guard.py", "CONSTRAINTS.md")  # pattern text lives here legitimately
is_swift = lambda f: f.endswith(".swift")
is_test = lambda f: f.startswith("Tests/") and f.endswith(".swift")
is_constraints = lambda f: f.endswith("CONSTRAINTS.md")

# 1. Silenced checker (Swift ecosystem).
SUPPRESSIONS = re.compile(
    r"swift-format-ignore|swiftlint:disable|#if\s+false|@_silgen_name|"
    r"@preconcurrency\s+import|nonisolated\(unsafe\)|@unchecked\s+Sendable|"
    r"-suppress-warnings|-Xfrontend\s+-disable"
)
# 4. Unfinished work.
STUBS = re.compile(
    r"fatalError\(\s*\"[^\"]*(?:[Nn]ot implemented|[Uu]nimplemented|TODO)|"
    r"preconditionFailure\(\s*\"[^\"]*(?:[Nn]ot implemented|[Uu]nimplemented)|"
    r"catch\s*\{\s*\}|try\?\s*FileManager|\bTODO\b|\bFIXME\b"
)
# 2. A test made easier.
SKIPS = re.compile(r"\.disabled\b|\bwithKnownIssue\b|\bXCTSkip|\.enabled\(if:\s*false")
ASSERTIONS = re.compile(r"#expect|#require|XCTAssert|XCTFail|Issue\.record")

for f, text in added:
    if f in GUARD_SELF:
        continue
    if is_swift(f) or f in ("Package.swift", "Makefile"):
        if SUPPRESSIONS.search(text):
            flag("silenced-checker", f, text)
        if STUBS.search(text):
            flag("unfinished-work", f, text)
    if is_test(f) and SKIPS.search(text):
        flag("test-made-easier", f, text)
    if is_constraints(f) and re.match(r"^\| *(W|E)\d+ *\|", text):
        flag("new-exception", f, text)

for f in deleted:
    if is_test(f):
        flag("test-deleted", f, "file deleted")
for f, text in removed:
    if is_test(f) and f not in deleted and ASSERTIONS.search(text):
        flag("assertion-removed", f, text)

# CONSTRAINTS.md: a rule weakened or removed (same direction logic as the reference).
def rule_key(t):
    s = t.strip()
    if s.startswith("|"):
        cells = [c.strip() for c in s.split("|") if c.strip()]
        if not cells or set(cells[0]) <= set("-: "):
            return None
        return cells[0]
    if re.match(r"^[-*] ", s):
        return s[2:].split(":")[0].strip()
    return None


is_exception = lambda t: re.match(r"^\| *(W|E)\d+ *\|", t.strip()) is not None
MIN_BEFORE = re.compile(r"(>=|>|≥|at least|minimum|\bmin\b|no less than|not fall|not drop)\s*$")
MAX_BEFORE = re.compile(r"(<=|<|≤|at most|maximum|\bmax\b|no more than|under|below|not grow|not exceed)\s*$")
MIN_AFTER = re.compile(r"^\s*\S*\s*(or more|or higher|must not fall|must not drop)")
MAX_AFTER = re.compile(r"^\s*\S*\s*(or less|or lower|must not grow|must not exceed)")


def thresholds(t):
    out = []
    for m in re.finditer(r"\d+(?:\.\d+)?", t):
        before = t[max(0, m.start() - 24):m.start()].lower()
        after = t[m.end():m.end() + 40].lower()
        if MIN_BEFORE.search(before) or MIN_AFTER.search(after):
            d = "min"
        elif MAX_BEFORE.search(before) or MAX_AFTER.search(after):
            d = "max"
        else:
            d = None
        out.append((float(m.group()), d))
    return out


removed_rules = [(f, t) for f, t in removed if is_constraints(f) and rule_key(t) is not None]
added_rules = [(f, t) for f, t in added if is_constraints(f) and rule_key(t) is not None]
for f, rt in removed_rules:
    match = next((at for af, at in added_rules if rule_key(at) == rule_key(rt)), None)
    if match is None:
        if not is_exception(rt):
            flag("rule-removed", f, rt)
        continue
    before, after = thresholds(rt), thresholds(match)
    verdict = None
    for d in ("min", "max", None):
        was = [n for n, dd in before if dd == d]
        now = [n for n, dd in after if dd == d]
        for i, b in enumerate(was):
            if verdict:
                break
            if i >= len(now):
                verdict = "threshold-removed"
            elif now[i] == b:
                continue
            elif (now[i] < b) if d == "min" else (now[i] > b) if d == "max" else True:
                verdict = "threshold-loosened" if d else "threshold-changed"
    if verdict:
        flag(verdict, f, rt + "  ->  " + match)

if not findings:
    print("floor-guard: clean (base " + base + ")")
    sys.exit(0)
print("floor-guard: %d floor violation(s):" % len(findings), file=sys.stderr)
for rule, f, text in findings:
    print("  [%s] %s: %s" % (rule, f, text), file=sys.stderr)
print("\nEach is a move that lowers the bar. Fix the code, or route it through a tracked exception.",
      file=sys.stderr)
sys.exit(1)
