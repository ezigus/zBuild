#!/usr/bin/env bash
# Tests: resume contract across a REAL process boundary.
# Two bash processes: writer (initializes + writes), reader (resume + read).
# Proves state survives process exit, not just function re-call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/state — resume across process boundary"

setup_test_env "core-state-resume-exec"
STATE_FILE="$TEST_TEMP_DIR/state.json"

# ─── Process 1: writer ──────────────────────────────────────────────────────
bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/state/resume.sh'
    init_state '$STATE_FILE' 'exec-test-run' 99 >/dev/null
    increment_iteration '$STATE_FILE' >/dev/null
    increment_iteration '$STATE_FILE' >/dev/null
    increment_iteration '$STATE_FILE' >/dev/null
    set_state_field '$STATE_FILE' '.plugin_state.\"test-plugin\".score' '88'
"
writer_rc=$?
assert_eq "writer process exits 0" "0" "$writer_rc"

# ─── Verify state file exists in this process ──────────────────────────────
assert_file_exists "state file persisted after writer exit" "$STATE_FILE"

# ─── Process 2: reader (simulates restart / resume) ────────────────────────
read_output="$(bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/state/resume.sh'
    resume_state '$STATE_FILE' >/dev/null
    iter=\$(get_state_field '$STATE_FILE' '.current_iteration' '0')
    score=\$(get_state_field '$STATE_FILE' '.plugin_state.\"test-plugin\".score' '0')
    echo \"iter=\$iter score=\$score\"
")"

assert_contains "reader process sees current_iteration=3 (FIXES shipwright gap)" "$read_output" "iter=3"
assert_contains "reader process sees plugin_state.test-plugin.score=88" "$read_output" "score=88"

# ─── Process 3: writer continues after resume ──────────────────────────────
bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/state/resume.sh'
    resume_state '$STATE_FILE' >/dev/null
    increment_iteration '$STATE_FILE' >/dev/null
"
final_iter=$(bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/state/resume.sh'
    get_state_field '$STATE_FILE' '.current_iteration' '0'
")
assert_eq "iteration continues from where resume picked up (3 → 4)" "4" "$final_iter"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
