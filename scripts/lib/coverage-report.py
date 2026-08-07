#!/usr/bin/env python3
"""Coverage report: parse a PS4 trace and compute statement coverage.

Usage: python3 coverage-report.py <trace_file> <repo_root> <floor>
Exit:  0 = pass, 1 = below floor, 2 = instrumentation failure

Extracted from the heredoc in scripts/check-coverage.sh (#1761) so the
arithmetic can be exercised directly by a test instead of only through a full
unit-tier run.

The denominator is built from the file set on disk, not from the trace (#1761).
A file that no test ever sources produces zero trace lines; keying the per-file
loop off the trace excluded it from BOTH numerator and denominator, so a wholly
untested new file could not move the gate at all.
"""
import sys
import os
import re
import json
from collections import defaultdict

trace_file = sys.argv[1]
repo_root  = sys.argv[2]
floor      = int(sys.argv[3])

INCLUDE  = ['/core/', '/scripts/lib/']
EXCLUDE  = ['/tests/', '-test.sh', '-unit-test.sh']

# Roots enumerated from disk. Deliberately NOT `repo_root` itself: walking the
# whole tree matches `/scripts/lib/` under legacy/, which is a frozen upstream
# import that is never executed and is not engine code (CLAUDE.md). Counting it
# would add ~58 files of dead weight to the denominator (#1761).
SCAN_ROOTS = ['core', 'scripts/lib']


def _in_scope(path):
    return (any(p in path for p in INCLUDE)
            and not any(x in path for x in EXCLUDE))


covered = defaultdict(set)
with open(trace_file, encoding='utf-8', errors='replace') as fh:
    for line in fh:
        m = re.match(r'^TRACE:(.*?):(\d+):', line)
        if m:
            src    = m.group(1)
            lineno = int(m.group(2))
            if _in_scope(src):
                covered[src].add(lineno)

if not covered:
    print("ERROR: no lines traced in core/ or scripts/lib/ — "
          "check that child bash processes inherit BASH_XTRACEFD",
          file=sys.stderr)
    sys.exit(2)

# Union of "what the trace saw" and "what is on disk under the scan roots", so
# an untraced in-scope file lands in the table at 0/N rather than vanishing.
all_sources = set(covered.keys())
for root in SCAN_ROOTS:
    for dirpath, _dirnames, filenames in os.walk(os.path.join(repo_root, root)):
        for fname in filenames:
            if not fname.endswith('.sh'):
                continue
            abs_path = os.path.join(dirpath, fname)
            if _in_scope(abs_path):
                all_sources.add(abs_path)

total_covered = 0
total_exec    = 0

rows = []
for src in sorted(all_sources):
    if not os.path.isfile(src):
        continue
    with open(src, encoding='utf-8', errors='replace') as fh:
        lines = fh.readlines()
    executable = sum(
        1 for ln in lines
        if ln.strip() and not ln.strip().startswith('#')
    )
    executed = len(covered.get(src, set()))
    pct      = (executed / executable * 100) if executable else 0.0
    rel      = os.path.relpath(src, repo_root)
    rows.append((rel, executed, executable, pct))
    total_covered += executed
    total_exec    += executable

if total_exec == 0:
    print("ERROR: zero executable lines found in included files", file=sys.stderr)
    sys.exit(2)

print("\n| File | Covered | Total | % |")
print("|------|---------|-------|---|")
for rel, executed, executable, pct in rows:
    print(f"| {rel} | {executed} | {executable} | {pct:.1f}% |")

overall = total_covered / total_exec * 100
print(f"\nTotal: {total_covered}/{total_exec} lines ({overall:.1f}%)")

map_out = os.environ.get('ZBUILD_COVERAGE_MAP_OUT', '')
if map_out:
    cmap = {
        "files": [
            {"file": r, "covered": e, "total": x, "pct": round(p, 1)}
            for r, e, x, p in rows
        ],
        "total_pct": round(overall, 1)
    }
    try:
        with open(map_out, 'w', encoding='utf-8') as _f:
            json.dump(cmap, _f)
    except OSError as _e:
        # Fail-soft (coverage-map is advisory evidence) but surface why.
        print(f"WARN: could not write coverage map to {map_out}: {_e}", file=sys.stderr)

if overall < floor:
    print(f"ERROR: {overall:.1f}% is below the {floor}% floor", file=sys.stderr)
    sys.exit(1)

print(f"OK: {overall:.1f}% >= {floor}%")
