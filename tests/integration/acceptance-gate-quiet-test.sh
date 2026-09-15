#!/usr/bin/env bash
# Integration: acceptance-gate must stay QUIET on the operator terminal (#1211).
#
# The runner dups fd 3 to the operator terminal and exports ZBUILD_STAGE_IO_FD=3
# so stage-io banners survive `2>/dev/null`. The acceptance-gate's ADR-036 negctl
# and reachability checks shell out `bash <testfile>`; those nested TESTFILES drive
# real plugins whose stage-io banners would otherwise escape to the terminal via
# the inherited fd 3, bypassing the sandbox's stdout/stderr capture — and repeat
# once per baseline/HEAD run. This test pins the fix:
#
# [SPEC-1] Nested TESTFILE banners (written to ${ZBUILD_STAGE_IO_FD} or fd 3
#          directly) do NOT reach the operator terminal / fd 3 during a check.
# [SPEC-2] The acceptance-gate emits exactly ONE concise PASS/FAIL line per SPEC
#          (negctl) and per WIRING target (reachability) to the operator.
# [SPEC-3] Nested test diagnostics are STILL captured to the per-check logfile
#          (moved off the terminal, not lost).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate operator-terminal quiet (#1211)"
setup_test_env "acceptance-gate-quiet"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# A nested TESTFILE body that mimics a real plugin's stage-io banner: it writes a
# distinctive marker to the stage-io channel (ZBUILD_STAGE_IO_FD, default 2) AND
# straight to fd 3 (the runner's duped-terminal channel), exactly the two escape
# routes #1211 closes. It is also a valid negative control: it requires impl.sh
# (absent at baseline → fails there, present at HEAD → passes).
NESTED_BANNER_BODY='#!/usr/bin/env bash
# [SPEC-1] feature is implemented
printf "NESTED-STAGE-IO-MARKER\n" >&"${ZBUILD_STAGE_IO_FD:-2}" 2>/dev/null || true
printf "NESTED-FD3-DIRECT\n" >&3 2>/dev/null || true
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
# shellcheck disable=SC1090
source "$impl"; my_feature'

# ── Part A: fd-3 isolation at the negctl lib level (SPEC-1 + SPEC-3) ───────────
unset _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ACCEPTANCE_COVERAGE_LOADED \
      _ZBUILD_MERGE_BASE_LOADED
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

REPO_A="$(setup_git_temp_repo "quiet-negctl")"
(
    cd "$REPO_A"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    printf '%s\n' "$NESTED_BANNER_BODY" > tests/feature-test.sh
    chmod +x tests/feature-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl + banner-emitting test"
) >/dev/null 2>&1
cat > "$REPO_A/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF

TERM_CAP_A="$TEST_TEMP_DIR/terminal-negctl.txt"; : > "$TERM_CAP_A"
LOGDIR_A="$TEST_TEMP_DIR/negctl-logs"; rm -rf "$LOGDIR_A"
# Simulate the runner's contract: fd 3 duped to the "terminal", exported as the
# stage-io channel. The nested banner must NOT leak onto fd 3.
exec 3>"$TERM_CAP_A"
export ZBUILD_STAGE_IO_FD=3
export ZBUILD_NEGCTL_ARTIFACT_DIR="$LOGDIR_A"
set +e
acceptance_negctl_check "$REPO_A/design.md" "$REPO_A" >/dev/null 2>&1
set -e
exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_NEGCTL_ARTIFACT_DIR

assert_eq "[SPEC-1] negctl: stage-io banner does NOT reach fd 3 / terminal" \
    "0" "$(grep -c 'NESTED-STAGE-IO-MARKER' "$TERM_CAP_A")"
assert_eq "[SPEC-1] negctl: direct fd-3 write does NOT reach the terminal" \
    "0" "$(grep -c 'NESTED-FD3-DIRECT' "$TERM_CAP_A")"
_a_marker_n="$(grep -c 'NESTED-STAGE-IO-MARKER' "$LOGDIR_A"/negctl-SPEC-1.log 2>/dev/null)" || _a_marker_n=0
assert_gt "[SPEC-3] negctl: nested banner captured to the per-SPEC logfile" \
    "$_a_marker_n" "0"

# ── Part B: fd-3 isolation at the reachability lib level (SPEC-1 + SPEC-3) ─────
unset _ACCEPTANCE_REACHABILITY_LOADED
# shellcheck source=../../scripts/lib/acceptance-reachability.sh
source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh"

REPO_B="$(setup_git_temp_repo "quiet-reach")"
(
    cd "$REPO_B"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    printf '%s\n' "$NESTED_BANNER_BODY" > tests/feature-test.sh
    chmod +x tests/feature-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: wiring + banner-emitting test"
) >/dev/null 2>&1
cat > "$REPO_B/design.md" <<'EOF'
```acceptance
SPEC-1[change]: feature is implemented
WIRING:
impl.sh
TESTFILES:
tests/feature-test.sh
```
EOF

TERM_CAP_B="$TEST_TEMP_DIR/terminal-reach.txt"; : > "$TERM_CAP_B"
LOGDIR_B="$TEST_TEMP_DIR/reach-logs"; rm -rf "$LOGDIR_B"
exec 3>"$TERM_CAP_B"
export ZBUILD_STAGE_IO_FD=3
export ZBUILD_NEGCTL_ARTIFACT_DIR="$LOGDIR_B"
set +e
acceptance_reachability_check "$REPO_B/design.md" "$REPO_B" >/dev/null 2>&1
set -e
exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_NEGCTL_ARTIFACT_DIR

assert_eq "[SPEC-1] reachability: stage-io banner does NOT reach fd 3 / terminal" \
    "0" "$(grep -c 'NESTED-STAGE-IO-MARKER' "$TERM_CAP_B")"
assert_eq "[SPEC-1] reachability: direct fd-3 write does NOT reach the terminal" \
    "0" "$(grep -c 'NESTED-FD3-DIRECT' "$TERM_CAP_B")"
_b_marker_n="$(grep -c 'NESTED-STAGE-IO-MARKER' "$LOGDIR_B"/reachability-impl.sh.log 2>/dev/null)" || _b_marker_n=0
assert_gt "[SPEC-3] reachability: nested banner captured to the logfile" \
    "$_b_marker_n" "0"

# ── Part C: concise operator summary from the plugin (SPEC-2) ─────────────────
# Stub template_stage_io_dests so the plugin's io-gated summary emits (in the real
# pipeline the runner sources template.sh, which reads simple.yaml's
# `io: destinations: [file, stdout]`). Exported so the `( )` run subshell sees it.
template_stage_io_dests() {
    [[ "${1:-}" == "acceptance-gate" ]] && printf 'file\nstdout\n'
    return 0
}
export -f template_stage_io_dests

_run_gate_capture() {  # _run_gate_capture <repo> <fd3_capture_file>
    local repo="$1" cap="$2"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$state_dir/artifacts/design.md" 2>/dev/null || true
    local _si_json="$state_dir/stage-inputs.json"
    printf '{"inputs":{"design":"%s"}}\n' "$state_dir/artifacts/design.md" > "$_si_json"
    export ZBUILD_STAGE_INPUTS="$_si_json"
    unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
          _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
          _ACCEPTANCE_COVERAGE_LOADED
    : > "$cap"
    # shellcheck disable=SC1090
    (
        cd "$repo"
        exec 3>"$cap"
        export ZBUILD_STAGE_IO_FD=3
        export ZBUILD_STATE_DIR="$state_dir"
        source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh"
        # #1241: plugin.sh now sources stage-io.sh → template.sh, which defines a
        # real (template-less → empty) template_stage_io_dests that clobbers the
        # exported stub. Re-assert the stub AFTER the source so the io-gate still
        # opens (in production the runner has a real template loaded here).
        template_stage_io_dests() {
            [[ "${1:-}" == "acceptance-gate" ]] && printf 'file\nstdout\n'
            return 0
        }
        acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json"
    ) || true  # verdict=fail (rc=1) is expected in C1; capture is what we assert
}

# C1: negctl summary — one line per SPEC (SPEC-1 load-bearing, SPEC-2 tautology).
REPO_C="$(setup_git_temp_repo "quiet-summary-negctl")"
(
    cd "$REPO_C"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    # SPEC-1 load-bearing (needs impl.sh) + emits a nested banner.
    printf '%s\n' "$NESTED_BANNER_BODY" > tests/feature-test.sh
    # SPEC-2 tautological (always passes → NEGCTL FAIL tautology).
    printf '#!/usr/bin/env bash\n# [SPEC-2] change: always true\nexit 0\n' > tests/taut-test.sh
    chmod +x tests/*.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat"
) >/dev/null 2>&1
cat > "$REPO_C/design.md" <<'EOF'
```acceptance
SPEC-1[change]: feature is implemented
SPEC-2[change]: always true
TESTFILES:
tests/feature-test.sh
tests/taut-test.sh
```
EOF

CAP_C="$TEST_TEMP_DIR/summary-negctl.txt"
set +e; _run_gate_capture "$REPO_C" "$CAP_C"; set -e

assert_eq "[SPEC-2] summary: exactly one NEGCTL line per SPEC (2 SPECs → 2 lines)" \
    "2" "$(grep -c 'NEGCTL' "$CAP_C")"
assert_contains "[SPEC-2] summary: SPEC-1 load-bearing → NEGCTL PASS on terminal" \
    "$(cat "$CAP_C")" "NEGCTL PASS SPEC-1"
assert_contains "[SPEC-2] summary: SPEC-2 tautology → NEGCTL FAIL on terminal" \
    "$(cat "$CAP_C")" "NEGCTL FAIL SPEC-2 tautology"
assert_eq "[SPEC-1] summary run: no raw nested banner leaked to the terminal" \
    "0" "$(grep -c 'NESTED-STAGE-IO-MARKER' "$CAP_C")"
assert_eq "[SPEC-4] C1: operator summary behavioral contract preserved — one line per SPEC" \
    "2" "$(grep -c 'NEGCTL' "$CAP_C")"
# #1241: the summary must render inside its own stage-io frame (not orphaned
# after the preceding stage's ── end stage-io ──).
assert_contains "[#1241] summary is opened by a stage-io span for acceptance-gate" \
    "$(cat "$CAP_C")" "stage-io: acceptance-gate"
assert_contains "[#1241] summary frame is closed (── end stage-io: acceptance-gate ──)" \
    "$(cat "$CAP_C")" "end stage-io: acceptance-gate"

# C2: reachability summary — one line per WIRING target.
REPO_D="$(setup_git_temp_repo "quiet-summary-reach")"
(
    cd "$REPO_D"
    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > wiring.sh
    chmod +x wiring.sh
    mkdir -p tests
    cat > tests/feature-test.sh <<'TESTEOF'
#!/usr/bin/env bash
# [SPEC-1] my_feature is provided by wiring.sh
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$repo_root/wiring.sh" ]] || exit 1
# shellcheck disable=SC1090
source "$repo_root/wiring.sh"
my_feature
TESTEOF
    chmod +x tests/feature-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: wiring"
) >/dev/null 2>&1
cat > "$REPO_D/design.md" <<'EOF'
```acceptance
SPEC-1[change]: my_feature is provided by wiring.sh
WIRING:
wiring.sh
TESTFILES:
tests/feature-test.sh
```
EOF

CAP_D="$TEST_TEMP_DIR/summary-reach.txt"
set +e; _run_gate_capture "$REPO_D" "$CAP_D"; set -e

assert_eq "[SPEC-2] summary: exactly one REACHABILITY line per WIRING target" \
    "1" "$(grep -c 'REACHABILITY' "$CAP_D")"
assert_contains "[SPEC-2] summary: WIRING target → REACHABILITY PASS on terminal" \
    "$(cat "$CAP_D")" "REACHABILITY PASS wiring.sh"

cleanup_test_env
print_test_results  # exits with $FAIL
