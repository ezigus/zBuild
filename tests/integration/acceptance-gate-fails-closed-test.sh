#!/usr/bin/env bash
# tests/integration/acceptance-gate-fails-closed-test.sh — the gates fail closed
# (ADR-036 amendment 2026-10-09).
#
# #1752 run 37920468204: the contract-lib snapshot left out a sibling lib, the
# negative control died on `_ACCEPTANCE_TOUT: unbound variable`, and the
# acceptance gate wrote `verdict: pass` — "0 checked on the old and new code,
# 0 already done, 0 no code" — for a block that listed SPEC lines.
#
#   F1: a lib the gate's libraries load is missing → fail, naming it
#   F2: a lib the gate loads itself is missing → fail, naming it
#   F3: the #1752 shape — the libs load, a helper moved out is gone, the
#       negative control reports on no requirement → fail, not pass
#   F4: a whole-run skip still names each SPEC → still a pass (guard)
#   F5: shape-floor: its library's own dependency is missing → fail
#   F6: secret-scan: merge-base.sh is missing → fail, not skip
#   F7: the reason names every file that did not load
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the gates fail closed (#1752)"
setup_test_env "acceptance-gate-fails-closed"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# A copy of every top-level lib — what the self-grading snapshot holds — with
# <missing> removed.
_lib_without() {
    local name="$1" missing="$2"
    local dir="$TEST_TEMP_DIR/lib-$name"
    mkdir -p "$dir"
    cp "$REPO_ROOT"/scripts/lib/*.sh "$dir/"
    [[ -n "$missing" ]] && rm -f "$dir/$missing"
    printf '%s' "$dir"
}

# A repo whose feature branch adds impl.sh and a test that needs it: SPEC-1 is a
# real negative control (fails on main, passes on feature).
_build_repo() {
    local repo; repo="$(setup_git_temp_repo "$1")"
    (
        cd "$repo"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
        printf '%s\n' '#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
# shellcheck disable=SC1090
source "$impl"; my_feature' > tests/feature-test.sh
        chmod +x impl.sh tests/feature-test.sh
        "$GIT" add -A; "$GIT" commit -q -m "feat"
    ) >/dev/null 2>&1
    cat > "$repo/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF
    printf '%s' "$repo"
}

# _run_gate <repo> [lib_dir] — RESULT, RC
_run_gate() {
    local repo="$1" lib="${2:-}"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts" "$state_dir/events"
    export ZBUILD_EVENTS_DIR="$state_dir/events"
    export ZBUILD_EVENTS_JSONL="$state_dir/events/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$state_dir/artifacts/design.md"
    printf '{"inputs":{"design":"%s"}}\n' "$state_dir/artifacts/design.md" > "$state_dir/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$state_dir/stage-inputs.json"
    set +e
    (
        unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
              _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
              _ACCEPTANCE_COVERAGE_LOADED
        if [[ -n "$lib" ]]; then export ZBUILD_CONTRACT_LIB_DIR="$lib"; else unset ZBUILD_CONTRACT_LIB_DIR; fi
        cd "$repo" || exit 99
        # shellcheck disable=SC1090
        source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh"
        acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json"
    ) >/dev/null 2>&1
    RC=$?
    set -e
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
}

# ── Control: the fixture passes with the real libs ───────────────────────────
print_test_section "control: the fixture passes with every lib present"
R0="$(_build_repo fc-control)"
_run_gate "$R0" "$(_lib_without control "")"
assert_eq "control: verdict pass with every lib present" "pass" "$(jq -r .verdict <<<"$RESULT")"

# ── F1: a dependency of the gate's libraries does not load ───────────────────
print_test_section "F1: a library's own dependency is missing"
R1="$(_build_repo fc-f1)"
_run_gate "$R1" "$(_lib_without f1 env-scrub.sh)"
assert_eq "[F1] verdict fail when env-scrub.sh does not load" "fail" "$(jq -r .verdict <<<"$RESULT")"
assert_contains "[F1] the reason names the file that did not load" \
    "$(jq -r .reason <<<"$RESULT")" "env-scrub.sh"
assert_eq "[F1] disposition broken — the gate could not do its work" "broken" \
    "$(jq -r .disposition <<<"$RESULT")"
assert_eq "[F1] rc 1" "1" "$RC"

# ── F2: a library the gate loads itself does not load ───────────────────────
print_test_section "F2: a library the gate loads is missing"
R2="$(_build_repo fc-f2)"
_run_gate "$R2" "$(_lib_without f2 acceptance-coverage.sh)"
assert_eq "[F2] verdict fail when acceptance-coverage.sh does not load" "fail" "$(jq -r .verdict <<<"$RESULT")"
assert_contains "[F2] the reason names it" "$(jq -r .reason <<<"$RESULT")" "acceptance-coverage.sh"

# ── F3: the #1752 shape — nothing evaluated is not a pass ────────────────────
print_test_section "F3: the block lists SPEC lines and none of them was checked"
R3="$(_build_repo fc-f3)"
L3="$(_lib_without f3 "")"
# What the #1752 build did: the helper left acceptance-block.sh for a sibling,
# loaded with the `$(cd …)` form, and the sibling is not there.
printf '\n# shellcheck source=/dev/null\nsource "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zb-gone-1752.sh"\nunset -f _acceptance_timeout_prefix\n' \
    >> "$L3/acceptance-block.sh"
_run_gate "$R3" "$L3"
assert_eq "[F3] verdict fail when no SPEC got a status" "fail" "$(jq -r .verdict <<<"$RESULT")"
assert_contains "[F3] failures name nothing_checked" \
    "$(jq -c '.failures' <<<"$RESULT")" "nothing_checked"
assert_contains "[F3] the reason says no requirement was checked" \
    "$(jq -r .reason <<<"$RESULT")" "none of them was checked"
assert_eq "[F3] rc 1" "1" "$RC"
assert_eq "[F3] disposition broken" "broken" "$(jq -r .disposition <<<"$RESULT")"

# ── F7: the reason names every file that did not load ────────────────────────
print_test_section "F7: the reason keeps every gate_load_failed entry"
_r7="$(
    # shellcheck disable=SC1090
    source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" >/dev/null 2>&1
    _ag_build_reason "gate_load_failed:a-lib.sh" "gate_load_failed:b-lib.sh"
)"
assert_contains "[F7] the first file is named" "$_r7" "a-lib.sh"
assert_contains "[F7] the second file is named" "$_r7" "b-lib.sh"

# ── F4 (guard): a whole-run skip names each SPEC — still a pass ──────────────
print_test_section "F4: a test-only change still passes"
R4="$(setup_git_temp_repo fc-f4)"
(
    cd "$R4"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\n# [SPEC-1] test-only\nexit 0\n' > tests/feature-test.sh
    chmod +x tests/feature-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "test only"
) >/dev/null 2>&1
printf '%s\n' '```acceptance' 'SPEC-1: test-only' 'TESTFILES:' 'tests/feature-test.sh' '```' > "$R4/design.md"
_run_gate "$R4"
assert_eq "[F4] a test-only change (no_prod_delta for SPEC-1) still passes" "pass" \
    "$(jq -r .verdict <<<"$RESULT")"

# ── F5: shape-floor — its library's dependency is missing ────────────────────
print_test_section "F5: shape-floor fails when its library's dependency does not load"
W5="$TEST_TEMP_DIR/w5"; mkdir -p "$W5/artifacts"
L5="$(_lib_without f5 impact-prefilter.sh)"
set +e
(
    export ZBUILD_CONTRACT_LIB_DIR="$L5" ZBUILD_REPO_ROOT="$R0"
    unset _ZBUILD_SHAPE_FLOOR_PLUGIN_LOADED _SF_LOADED _ZBUILD_MERGE_BASE_LOADED
    # shellcheck disable=SC1090
    source "$REPO_ROOT/plugins/tool/shape-floor/plugin.sh"
    shape_floor_run "shape-floor" "$W5/state.json"
) >/dev/null 2>&1
set -e
_J5="$(cat "$W5/artifacts/shape-floor-result.json" 2>/dev/null || echo '{}')"
assert_eq "[F5] shape-floor verdict fail" "fail" "$(jq -r .verdict <<<"$_J5")"
assert_eq "[F5] shape-floor reason library_load_failure" "library_load_failure" "$(jq -r .reason <<<"$_J5")"

# ── F6: secret-scan — merge-base.sh is missing ───────────────────────────────
print_test_section "F6: secret-scan fails when merge-base.sh does not load"
W6="$TEST_TEMP_DIR/w6"; mkdir -p "$W6/artifacts"
L6="$(_lib_without f6 merge-base.sh)"
set +e
(
    export ZBUILD_CONTRACT_LIB_DIR="$L6" ZBUILD_REPO_ROOT="$R0"
    unset _ZBUILD_SECRET_SCAN_LOADED _ZBUILD_MERGE_BASE_LOADED
    # shellcheck disable=SC1090
    source "$REPO_ROOT/plugins/tool/secret-scan/plugin.sh"
    secret_scan_run "secret-scan" "$W6/state.json"
) >/dev/null 2>&1
set -e
_J6="$(cat "$W6/artifacts/secret-scan-result.json" 2>/dev/null || echo '{}')"
assert_eq "[F6] secret-scan verdict fail, not skip" "fail" "$(jq -r .verdict <<<"$_J6")"
assert_eq "[F6] secret-scan reason library_load_failure" "library_load_failure" "$(jq -r .reason <<<"$_J6")"

cleanup_test_env
print_test_results
