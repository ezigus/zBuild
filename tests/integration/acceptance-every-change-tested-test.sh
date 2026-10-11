#!/usr/bin/env bash
# tests/integration/acceptance-every-change-tested-test.sh — every changed code
# file, put back on its own, makes some test fail (ADR-036 Amendment 2026-10-11).
#
# Why: #1932's run changed core/state/run-cap.sh and runner.sh. Its tests called
# run-cap.sh directly, so putting back the whole change failed them and the
# check passed; nothing tested the runner.sh change. The check that puts back
# one file only looked at the file the design named, and "WIRING: none" turned
# it off. The list of changed files now comes from git, and every one is put
# back on its own; a stage cannot declare a file out of it.
#
# E1 [code] a changed code file no test notices is reported, by name, even
#           under WIRING: none
# E2 [code] a changed code file a test notices passes
# E3 [code] a file whose only changes are comments or blank lines, a deleted
#           file, a test file and a document are not put back
# E4 [code] with no WIRING section at all the files are still checked
# E5 [code] the gate fails on it, as a finding the build loop can act on, in
#           plain words that name the file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance: every changed code file is put back on its own (ADR-036)"
setup_test_env "acceptance-every-change"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

REPO="$(setup_git_temp_repo "every-change")"
(
    cd "$REPO"
    printf '#!/usr/bin/env bash\nlimit() { echo 1; }\n' > lib.sh
    printf '#!/usr/bin/env bash\nsource lib.sh\nmain() { echo run; }\n' > caller.sh
    printf '#!/usr/bin/env bash\n# old comment\nother() { echo o; }\n' > other.sh
    printf '#!/usr/bin/env bash\nold() { :; }\n' > old.sh
    "$GIT" add -A && "$GIT" commit -q -m base
    "$GIT" checkout -q -b feature
    # lib.sh: the tested change. caller.sh: a change no test looks at.
    printf '#!/usr/bin/env bash\nlimit() { echo 2; }\n' > lib.sh
    printf '#!/usr/bin/env bash\nsource lib.sh\nmain() { echo run; limit; }\n' > caller.sh
    # other.sh: comments and blank lines only. old.sh: deleted.
    printf '#!/usr/bin/env bash\n# new comment\n\n// another\nother() { echo o; }\n' > other.sh
    "$GIT" rm -q old.sh
    mkdir -p tests docs
    printf 'notes\n' > docs/notes.md
    cat > tests/limit-test.sh <<'TESTEOF'
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/lib.sh"
if [[ "$(limit)" == "2" ]]; then echo "  ✓ [SPEC-1] the limit is 2"; exit 0; fi
echo "  ✗ [SPEC-1] the limit is 2"; exit 1
TESTEOF
    chmod +x tests/limit-test.sh
    "$GIT" add -A && "$GIT" commit -q -m "feat: limit 2"
) >/dev/null 2>&1

_design() {
    local wiring="$1"
    {
        printf '```acceptance\nSPEC-1[code]: the limit is 2\n'
        [[ -n "$wiring" ]] && printf 'WIRING:\n%s\n' "$wiring"
        printf 'TESTFILES:\nSPEC-1: tests/limit-test.sh\n```\n'
    } > "$REPO/design.md"
}

_reach() {
    unset _ACCEPTANCE_REACHABILITY_LOADED _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED
    ( cd "$REPO" && source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh" \
        && acceptance_reachability_check "$REPO/design.md" "$REPO" ) 2>/dev/null || true
}

print_test_section "E1–E3: under WIRING: none"
_design none
_out="$(_reach)"
assert_contains "[E1] the untested change is reported by name" "$_out" "REACHABILITY FAIL untested_change caller.sh"
assert_contains "[E2] the tested change passes" "$_out" "REACHABILITY PASS change lib.sh"
assert_contains "[E3] a comments-only change is not put back" "$_out" "REACHABILITY SKIP no_code other.sh"
for _f in old.sh tests/limit-test.sh docs/notes.md; do
    if grep -qF " $_f" <<< "$_out"; then
        assert_fail "[E3] $_f is not put back" "$(grep -F " $_f" <<< "$_out")"
    else
        assert_pass "[E3] $_f is not put back"
    fi
done

print_test_section "E4: no WIRING section"
_design ""
_out4="$(_reach)"
assert_contains "[E4] the untested change is still reported" "$_out4" "REACHABILITY FAIL untested_change caller.sh"

print_test_section "E5: the gate fails, recoverably, in plain words"
_run_gate() {
    local state_dir="$REPO/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$REPO/design.md" "$state_dir/artifacts/design.md"
    printf '{"inputs":{"design":"%s"}}\n' "$state_dir/artifacts/design.md" > "$state_dir/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$state_dir/stage-inputs.json"
    unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
          _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
          _ACCEPTANCE_COVERAGE_LOADED
    # shellcheck disable=SC1090
    ( cd "$REPO" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" ) >/dev/null 2>&1 || true
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
}
_design none
_run_gate
assert_contains "[E5] the gate lists the untested file" "$(jq -r '.failures[]? // empty' <<< "$RESULT")" "untested_change:caller.sh"
assert_eq "[E5] the build loop can act on it" "recoverable" "$(jq -r '.severity // empty' <<< "$RESULT")"
assert_contains "[E5] the reason names the file in plain words" "$(jq -r '.reason // empty' <<< "$RESULT")" \
    "caller.sh was put back to its old version on its own and every test still passed"
assert_eq "[E5] the event is emitted" "1" \
    "$(grep -c '"acceptance.gate.untested_change"' "$REPO/.zbuild-state/events/events.jsonl" || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
