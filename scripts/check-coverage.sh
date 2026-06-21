#!/usr/bin/env bash
# Bash statement coverage via PS4 tracing. No external tools required.
# Computes covered/executable-line ratio for core/ and scripts/lib/.
# Usage: [COVERAGE_FLOOR=N] bash scripts/check-coverage.sh
# Exit: 0 = pass, 1 = below floor, 2 = instrumentation failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLOOR="${COVERAGE_FLOOR:-70}"

TRACE_FILE="$(mktemp -t zbuild-coverage.XXXXXX)"
BASH_ENV_FILE="$(mktemp -t zbuild-bash-env.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$TRACE_FILE' '$BASH_ENV_FILE'" EXIT

# BASH_ENV is sourced by every non-interactive bash subprocess (including
# `bash "$f"` invocations in run-tests.sh). It injects `set -x` so that
# child processes also emit xtrace output via fd 9 → TRACE_FILE.
printf 'set -x\n' > "$BASH_ENV_FILE"

export ZBUILD_TEST_TMP
ZBUILD_TEST_TMP="$(mktemp -d)"

echo "Running unit tests with PS4 tracing (floor: ${FLOOR}%)..."

# PS4 format: TRACE:<source>:<lineno>:  — Python parser matches this prefix.
# BASH_XTRACEFD=9 writes xtrace to fd 9 (not stderr), keeping test output clean.
# BASH_ENV injects set -x into every child bash so sourced core/*.sh lines appear.
# #984: FORCE SERIAL here. The unit tier is parallel-by-default now, but PS4
# line-tracing funnels every child's xtrace to one fd-9 trace file — concurrent
# workers would interleave/corrupt it and skew coverage. Coverage must run serial.
PS4='TRACE:${BASH_SOURCE[0]-}:${LINENO}:' \
BASH_XTRACEFD=9 \
BASH_ENV="$BASH_ENV_FILE" \
ZBUILD_TEST_PARALLEL_JOBS=0 \
    bash "$REPO_ROOT/scripts/run-tests.sh" --tier unit 9>"$TRACE_FILE"

TRACE_LINES="$(wc -l < "$TRACE_FILE" | tr -d ' ')"
echo "Trace lines captured: ${TRACE_LINES}"

if [[ "$TRACE_LINES" -eq 0 ]]; then
    echo "ERROR: trace file is empty — PS4/BASH_XTRACEFD not supported on this bash" >&2
    exit 2
fi

# Parse trace and compute coverage with Python 3 (available on all CI runners)
python3 - "$TRACE_FILE" "$REPO_ROOT" "$FLOOR" <<'PYEOF'
import sys
import os
import re
from collections import defaultdict

trace_file = sys.argv[1]
repo_root  = sys.argv[2]
floor      = int(sys.argv[3])

INCLUDE  = ['/core/', '/scripts/lib/']
EXCLUDE  = ['/tests/', '-test.sh', '-unit-test.sh']

covered = defaultdict(set)
with open(trace_file, encoding='utf-8', errors='replace') as fh:
    for line in fh:
        m = re.match(r'^TRACE:(.*?):(\d+):', line)
        if m:
            src    = m.group(1)
            lineno = int(m.group(2))
            if (any(p in src for p in INCLUDE)
                    and not any(x in src for x in EXCLUDE)):
                covered[src].add(lineno)

if not covered:
    print("ERROR: no lines traced in core/ or scripts/lib/ — "
          "check that child bash processes inherit BASH_XTRACEFD",
          file=sys.stderr)
    sys.exit(2)

total_covered = 0
total_exec    = 0

rows = []
for src in sorted(covered):
    if not os.path.isfile(src):
        continue
    with open(src, encoding='utf-8', errors='replace') as fh:
        lines = fh.readlines()
    executable = sum(
        1 for ln in lines
        if ln.strip() and not ln.strip().startswith('#')
    )
    executed = len(covered[src])
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

if overall < floor:
    print(f"ERROR: {overall:.1f}% is below the {floor}% floor", file=sys.stderr)
    sys.exit(1)

print(f"OK: {overall:.1f}% >= {floor}%")
PYEOF
