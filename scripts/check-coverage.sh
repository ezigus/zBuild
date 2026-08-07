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
# shellcheck disable=SC2064
trap "rm -f '$TRACE_FILE'" EXIT

export ZBUILD_TEST_TMP
ZBUILD_TEST_TMP="$(mktemp -d)"

echo "Running unit tests with coverage tracing (floor: ${FLOOR}%)..."

# #993: the runner owns the trace mechanism. We just ask it for a merged
# coverage trace at $TRACE_FILE; run-tests.sh wires PS4/BASH_XTRACEFD/BASH_ENV,
# gives each test its own trace file (so parallel workers never share fd 9), and merges them — so
# coverage runs under the parallel unit tier without one shared fd-9 trace
# getting corrupted (replaces the old forced-serial workaround). The PS4 format
# (`TRACE:<source>:<lineno>:`) coverage-report.py matches is set by the runner.
bash "$REPO_ROOT/scripts/run-tests.sh" --tier unit --coverage-trace "$TRACE_FILE"

TRACE_LINES="$(wc -l < "$TRACE_FILE" | tr -d ' ')"
echo "Trace lines captured: ${TRACE_LINES}"

if [[ "$TRACE_LINES" -eq 0 ]]; then
    echo "ERROR: trace file is empty — coverage tracing produced no output" >&2
    exit 2
fi

# Parse trace and compute coverage. The arithmetic lives in scripts/lib/
# coverage-report.py (#1761) rather than an inline heredoc so a test can invoke
# it directly with a fixture trace instead of only through a full unit-tier run.
python3 "$SCRIPT_DIR/lib/coverage-report.py" "$TRACE_FILE" "$REPO_ROOT" "$FLOOR"
