#!/usr/bin/env bash
# Integration: acceptance.gate.complete event carries outcome and reason (#1722)
# DSEVNT-1..6: every exit path of acceptance_gate_run emits the closing event
# with outcome= and reason= matching the result it wrote.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "acceptance-gate events — outcome and reason (#1722)"
setup_test_env "acceptance-gate-events"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# ── Repo builder ──────────────────────────────────────────────────────────────
# _build_repo <name> <head_test_body> [<impl>]
_build_repo() {
    local name="$1" body="$2" impl="${3:-impl.sh}"
    local repo; repo="$(setup_git_temp_repo "$name")"
    (
        cd "$repo" || exit 1
        "$GIT" checkout -q -b feature
        mkdir -p tests "$(dirname "$impl")"
        printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > "$impl"
        printf '%s\n' "$body" > tests/feature-test.sh
        chmod +x tests/feature-test.sh "$impl"
        "$GIT" add -A; "$GIT" commit -q -m "feat"
    )
    printf '%s' "$repo"
}

# ── Gate runner ───────────────────────────────────────────────────────────────
# _run_gate <repo> [lib_dir] → sets RC, RESULT, EVENTS. With lib_dir, the gate
# loads its contract libraries from there (ZBUILD_CONTRACT_LIB_DIR), the way
# acceptance-gate-fails-closed-test.sh reaches a gate whose code is damaged.
_run_gate() {
    local repo="$1" lib="${2:-}"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$state_dir/artifacts/design.md" 2>/dev/null || true
    local _si_json="$state_dir/stage-inputs.json"
    printf '{"inputs":{"design":"%s"}}\n' "$state_dir/artifacts/design.md" > "$_si_json"
    export ZBUILD_STAGE_INPUTS="$_si_json"
    # shellcheck disable=SC1090
    ( cd "$repo" || exit 99
      unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
            _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
            _ACCEPTANCE_COVERAGE_LOADED
      if [[ -n "$lib" ]]; then export ZBUILD_CONTRACT_LIB_DIR="$lib"; else unset ZBUILD_CONTRACT_LIB_DIR; fi
      source "$REPO_ROOT/plugins/tool/test/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" ) >/dev/null 2>&1
    RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
}

# _lib_1752 <repo> — the #1752 shape (acceptance-gate-fails-closed-test.sh F3):
# a copy of the contract libraries whose acceptance-block.sh loads a sibling
# that is not there and loses a helper the negative control needs. Every
# library loads; the negative control reports on no requirement.
_lib_1752() {
    local lib="$1/.zbuild-lib-1752"
    mkdir -p "$lib"
    cp "$REPO_ROOT"/scripts/lib/*.sh "$lib/"
    # shellcheck disable=SC2016  # written into the copy, expanded when it loads
    printf '\n# shellcheck source=/dev/null\nsource "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zb-gone-1752.sh"\nunset -f _acceptance_timeout_prefix\n' \
        >> "$lib/acceptance-block.sh"
    printf '%s' "$lib"
}

# ── Event field extractors ────────────────────────────────────────────────────
# Extract .data.outcome from the acceptance.gate.complete event in a JSONL file.
_complete_event_outcome() {
    jq -r 'select(.type=="acceptance.gate.complete") | .data.outcome // empty' "$1" 2>/dev/null
}

# Extract .data.reason from the acceptance.gate.complete event in a JSONL file.
_complete_event_reason() {
    jq -r 'select(.type=="acceptance.gate.complete") | .data.reason // empty' "$1" 2>/dev/null
}

# ── E1 [DSEVNT-1]: all SPECs pass → outcome=pass, reason matches result ───────
# Given
REPO_E1="$(_build_repo evnt-pass '#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
source "$impl"; my_feature')"
cat > "$REPO_E1/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF
# When
set +e; _run_gate "$REPO_E1"; set -e
# Then
assert_eq "[DSEVNT-1] E1: rc=0 (pass exits 0)" "0" "$RC"
assert_event_emitted "[DSEVNT-1] E1: acceptance.gate.complete emitted on pass" \
    "$EVENTS" "acceptance.gate.complete"
assert_eq "[DSEVNT-1] E1: event outcome=pass" \
    "pass" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-1] E1: event outcome matches result outcome" \
    "$(jq -r .outcome <<<"$RESULT")" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-1] E1: event reason matches result reason" \
    "$(jq -r .reason <<<"$RESULT")" "$(_complete_event_reason "$EVENTS")"
assert_contains "[DSEVNT-1] E1: the check ran its SPEC on the old and new code (not a skip)" \
    "$(_complete_event_reason "$EVENTS")" "the acceptance check passed — 1 checked on the old and new code"

# ── E2 [DSEVNT-2]: a SPEC fails (tautological) → outcome=fail, reason matches ─
# Given
REPO_E2="$(_build_repo evnt-fail '#!/usr/bin/env bash
# [SPEC-1] always true
exit 0')"
cat > "$REPO_E2/design.md" <<'EOF'
```acceptance
SPEC-1[change]: always true
TESTFILES:
tests/feature-test.sh
```
EOF
# When
set +e; _run_gate "$REPO_E2"; set -e
# Then
assert_eq "[DSEVNT-2] E2: rc=1 (fail exits 1)" "1" "$RC"
assert_event_emitted "[DSEVNT-2] E2: acceptance.gate.complete emitted on fail" \
    "$EVENTS" "acceptance.gate.complete"
assert_eq "[DSEVNT-2] E2: event outcome=fail" \
    "fail" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-2] E2: event outcome matches result outcome" \
    "$(jq -r .outcome <<<"$RESULT")" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-2] E2: event reason matches result reason" \
    "$(jq -r .reason <<<"$RESULT")" "$(_complete_event_reason "$EVENTS")"

# ── E3 [DSEVNT-3]: precondition unmet → outcome=pass, reason=precondition_unmet
# Given: a repo with no acceptance block at all
REPO_E3="$(_build_repo evnt-noblock '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
printf '# Design\nNo acceptance block here.\n' > "$REPO_E3/design.md"
# When
set +e; _run_gate "$REPO_E3"; set -e
# Then
assert_eq "[DSEVNT-3] E3: rc=0 (precondition_unmet exits 0)" "0" "$RC"
assert_event_emitted "[DSEVNT-3] E3: acceptance.gate.complete emitted on precondition_unmet" \
    "$EVENTS" "acceptance.gate.complete"
assert_eq "[DSEVNT-3] E3: event outcome=pass" \
    "pass" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-3] E3: event reason=precondition_unmet" \
    "precondition_unmet" "$(_complete_event_reason "$EVENTS")"
assert_eq "[DSEVNT-3] E3: event reason matches result reason" \
    "$(jq -r .reason <<<"$RESULT")" "$(_complete_event_reason "$EVENTS")"

# ── E4 [DSEVNT-4]: malformed block → outcome=fail, reason=malformed_acceptance_block
# Given: a fence line with more after it — the gate finds the fence, the block
# reader takes only a bare ```acceptance line, so the block cannot be read
REPO_E4="$(_build_repo evnt-malformed '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
cat > "$REPO_E4/design.md" <<'EOF'
```acceptance extra
SPEC-1: x
TESTFILES:
tests/feature-test.sh
```
EOF
# When
set +e; _run_gate "$REPO_E4"; set -e
# Then
assert_eq "[DSEVNT-4] E4: rc=1 (malformed exits 1)" "1" "$RC"
assert_event_emitted "[DSEVNT-4] E4: acceptance.gate.complete emitted on malformed block" \
    "$EVENTS" "acceptance.gate.complete"
assert_eq "[DSEVNT-4] E4: event outcome=fail" \
    "fail" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-4] E4: event reason=malformed_acceptance_block" \
    "malformed_acceptance_block" "$(_complete_event_reason "$EVENTS")"
assert_eq "[DSEVNT-4] E4: event reason matches result reason" \
    "$(jq -r .reason <<<"$RESULT")" "$(_complete_event_reason "$EVENTS")"

# ── E5 [DSEVNT-5]: load failure → outcome=broken, reason matches result ───────
# Given: a minimal repo; ZBUILD_CONTRACT_LIB_DIR → non-existent dir so all
# contract-lib sources fail and _ag_fail_load is triggered
REPO_E5="$(setup_git_temp_repo evnt-loadfail)"
printf '# Design\nNo acceptance block.\n' > "$REPO_E5/design.md"
# When
set +e; _run_gate "$REPO_E5" "$REPO_E5/.zbuild-state/no-such-contract-lib"; set -e
# Then
assert_eq "[DSEVNT-5] E5: rc=1 (load failure exits 1)" "1" "$RC"
assert_event_emitted "[DSEVNT-5] E5: acceptance.gate.complete emitted on load failure" \
    "$EVENTS" "acceptance.gate.complete"
assert_eq "[DSEVNT-5] E5: event outcome=broken" \
    "broken" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-5] E5: event outcome matches result outcome" \
    "$(jq -r .outcome <<<"$RESULT")" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-5] E5: event reason matches result reason" \
    "$(jq -r .reason <<<"$RESULT")" "$(_complete_event_reason "$EVENTS")"

# ── E6 [DSEVNT-6]: nothing checked → outcome=broken, reason matches result ────
# Given: a block with a SPEC and a tagged test, and contract libraries in the
# #1752 shape, so the negative control names no SPEC → nothing_checked → broken
REPO_E6="$(_build_repo evnt-nothing '#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
source "$impl"; my_feature')"
cat > "$REPO_E6/design.md" <<'EOF'
```acceptance
SPEC-1[code]: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF
# When
set +e; _run_gate "$REPO_E6" "$(_lib_1752 "$REPO_E6")"; set -e
# Then
assert_eq "[DSEVNT-6] E6: rc=1 (nothing_checked exits 1)" "1" "$RC"
assert_event_emitted "[DSEVNT-6] E6: the gate found nothing checked (not a load failure)" \
    "$EVENTS" "acceptance.gate.nothing_checked"
assert_event_emitted "[DSEVNT-6] E6: acceptance.gate.complete emitted on nothing_checked" \
    "$EVENTS" "acceptance.gate.complete"
assert_eq "[DSEVNT-6] E6: event outcome=broken (not fail)" \
    "broken" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-6] E6: event outcome matches result outcome" \
    "$(jq -r .outcome <<<"$RESULT")" "$(_complete_event_outcome "$EVENTS")"
assert_eq "[DSEVNT-6] E6: event reason matches result reason" \
    "$(jq -r .reason <<<"$RESULT")" "$(_complete_event_reason "$EVENTS")"

cleanup_test_env
print_test_results
