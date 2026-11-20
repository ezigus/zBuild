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
#           file, a test file and a document are not put back; a changed
#           shebang line is code (it picks the interpreter)
# E4 [code] with no WIRING section at all the files are still checked
# E5 [code] the gate fails on it, as a finding the build loop can act on, in
#           plain words that name the file
#
# #1764 run 44782866204: a design step that changed config/shape-change-paths.txt
# was removed, nothing undid its line, and the check said "add a test" — so
# test-author pinned a change nothing asks for (#2575, ADR-036).
# E6 [code] a changed file no test checks and nothing asks for — no design
#           step's areas, no WIRING file and no requirement names it — is
#           reported as unasked_change, not untested_change
# E7 [code] a file a SPEC names is untested_change (to the code and the tests);
#           a file only a step's areas name (here a folder holding it) is
#           unspecified_change
# E8 [code] the gate's finding for it says "nothing asks for this change — take
#           it out, or name what asks for it", and goes to the code and the
#           design, never to the tests
# E9 [code] review on #2575: a SPEC on a.sh, a step on b.sh, b.sh untested — the
#           finding is "step 2 changes b.sh but no SPEC says what it should do —
#           add a SPEC, or say why it needs no test", to the design only: never
#           to test-author, whose tests trace to a SPEC, so nothing loops
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

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
    printf '#!/bin/sh\nshebang() { :; }\n' > shebang.sh
    "$GIT" add -A && "$GIT" commit -q -m base
    "$GIT" checkout -q -b feature
    # lib.sh: the tested change. caller.sh: a change no test looks at.
    printf '#!/usr/bin/env bash\nlimit() { echo 2; }\n' > lib.sh
    printf '#!/usr/bin/env bash\nsource lib.sh\nmain() { echo run; limit; }\n' > caller.sh
    # other.sh: comments and blank lines only. old.sh: deleted.
    printf '#!/usr/bin/env bash\n# new comment\n\n// another\nother() { echo o; }\n' > other.sh
    "$GIT" rm -q old.sh
    printf '#!/usr/bin/env bash\nshebang() { :; }\n' > shebang.sh
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

# E1-E5's design has no steps block: the check keeps the rule it had, and
# does not guess what is asked for (#2575 review).
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
if grep -qF "REACHABILITY SKIP no_code shebang.sh" <<< "$_out"; then
    assert_fail "[E3] a changed shebang line is code, not a comment" "skipped as no_code"
else
    assert_pass "[E3] a changed shebang line is code, not a comment"
fi
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
    ( cd "$REPO" && source "$REPO_ROOT/plugins/tool/test/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" ) >/dev/null 2>&1 || true
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
}
_design none
_run_gate
assert_contains "[E5] the gate lists the untested file" "$(jq -r '.failures[]? // empty' <<< "$RESULT")" "untested_change:caller.sh"
assert_eq "[E5] the build loop can act on it" "recoverable" "$(jq -r '.severity // empty' <<< "$RESULT")"
_reason="$(jq -r '.reason // empty' <<< "$RESULT")"
assert_contains "[E5] the reason names the file" "$_reason" "caller.sh"
assert_contains "[E5] ...in plain words" "$_reason" "was put back to its old version on its own and every test still passed"
assert_eq "[E5] the event is emitted for the file" "1" \
    "$(grep '"acceptance.gate.untested_change"' "$REPO/.zbuild-state/events/events.jsonl" | grep -c '"file":"caller.sh"' || true)"

print_test_section "E6-E8: a change nothing asks for (#1764, #2575)"
R2="$(setup_git_temp_repo "unasked-change")"
(
    cd "$R2"
    mkdir -p config tools
    printf 'scripts/lib/a.sh\n' > config/shape-change-paths.txt
    printf '#!/usr/bin/env bash\nlimit() { echo 1; }\n' > lib.sh
    printf '#!/usr/bin/env bash\nt() { :; }\n' > tools/t.sh
    printf '#!/usr/bin/env bash\nn() { :; }\n' > named.sh
    "$GIT" add -A && "$GIT" commit -q -m base
    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\nlimit() { echo 2; }\n' > lib.sh
    # The leftover line of a removed step.
    printf 'scripts/lib/a.sh\nplugins/agent/design/plugin.sh\n' > config/shape-change-paths.txt
    printf '#!/usr/bin/env bash\nt() { echo t; }\n' > tools/t.sh
    printf '#!/usr/bin/env bash\nn() { echo n; }\n' > named.sh
    mkdir -p tests
    cat > tests/limit-test.sh <<'TESTEOF'
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/lib.sh"
if [[ "$(limit)" == "2" ]]; then echo "  ✓ [SPEC-1] the limit is 2"; exit 0; fi
echo "  ✗ [SPEC-1] the limit is 2"; exit 1
TESTEOF
    "$GIT" add -A && "$GIT" commit -q -m "feat: limit 2"
) >/dev/null 2>&1
cat > "$R2/design.md" <<'MD'
# Raise the limit
```steps
- raise the limit | areas: lib.sh
- tidy the tools | areas: tools/
```
```acceptance
SPEC-1[code]: the limit is 2
SPEC-2[no-code]: named.sh says n when called
WIRING: none
```
MD
_out6="$( unset _ACCEPTANCE_REACHABILITY_LOADED _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED _ZBUILD_DESIGN_STEPS_LOADED
    cd "$R2" && source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh" \
        && acceptance_reachability_check "$R2/design.md" "$R2" 2>/dev/null || true )"
assert_contains "[E6] the leftover change is reported as asked for by nothing" "$_out6" \
    "REACHABILITY FAIL unasked_change config/shape-change-paths.txt"
assert_eq "[E6] ...not as an untested change" "0" \
    "$(grep -c 'untested_change config/shape-change-paths.txt' <<< "$_out6" || true)"
assert_contains "[E7] a file only a step's areas name (a folder holding it) has no SPEC" "$_out6" \
    "REACHABILITY FAIL unspecified_change tools/t.sh step=2"
assert_contains "[E7] a file a requirement names is asked for" "$_out6" \
    "REACHABILITY FAIL untested_change named.sh"
assert_contains "[E7] the tested change still passes" "$_out6" "REACHABILITY PASS change lib.sh"

REPO="$R2"
_run_gate
assert_contains "[E8] the gate lists the unasked file" "$(jq -r '.failures[]? // empty' <<< "$RESULT")" \
    "unasked_change:config/shape-change-paths.txt"
assert_eq "[E8] the build loop can act on it" "recoverable" "$(jq -r '.severity // empty' <<< "$RESULT")"
_reason8="$(jq -r '.reason // empty' <<< "$RESULT")"
assert_contains "[E8] the reason names the file" "$_reason8" "config/shape-change-paths.txt"
assert_contains "[E8] ...and says to take it out, or name what asks for it" "$_reason8" \
    "nothing asks for this change — take it out, or name what asks for it"
_A8="$R2/.zbuild-state/artifacts"
_f8() { jq -r '.data.findings[]?.text // empty' "$_A8/acceptance-gate-$1-result.json" 2>/dev/null || true; }
assert_contains "[E8] the finding goes to the code (build)" "$(_f8 code)" "nothing asks for this change"
assert_contains "[E8] ...and to the design" "$(_f8 design)" "nothing asks for this change"
assert_eq "[E8] ...never to the tests" "0" "$(_f8 test | grep -c 'shape-change-paths' || true)"
assert_eq "[E8] the event is emitted for the file" "1" \
    "$(grep '"acceptance.gate.unasked_change"' "$R2/.zbuild-state/events/events.jsonl" | grep -c '"file":"config/shape-change-paths.txt"' || true)"

print_test_section "E9: a step's file with no SPEC goes to the design (#2575 review)"
R3="$(setup_git_temp_repo "step-no-spec")"
(
    cd "$R3"
    printf '#!/usr/bin/env bash\nlimit() { echo 1; }\n' > a.sh
    printf '#!/usr/bin/env bash\nb() { echo 1; }\n' > b.sh
    "$GIT" add -A && "$GIT" commit -q -m base
    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\nlimit() { echo 2; }\n' > a.sh
    printf '#!/usr/bin/env bash\nb() { echo 2; }\n' > b.sh
    mkdir -p tests
    cat > tests/limit-test.sh <<'TESTEOF'
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/a.sh"
if [[ "$(limit)" == "2" ]]; then echo "  ✓ [SPEC-1] the limit is 2"; exit 0; fi
echo "  ✗ [SPEC-1] the limit is 2"; exit 1
TESTEOF
    "$GIT" add -A && "$GIT" commit -q -m change
) >/dev/null 2>&1
cat > "$R3/design.md" <<'MD'
# Two files
```steps
- raise the limit | areas: a.sh
- tidy b | areas: b.sh
```
```acceptance
SPEC-1[code]: a.sh's limit is 2
WIRING: none
```
MD
REPO="$R3"
_run_gate
_A9="$R3/.zbuild-state/artifacts"
_f9() { jq -r '.data.findings[]?.text // empty' "$_A9/acceptance-gate-$1-result.json" 2>/dev/null || true; }
assert_contains "[E9] the gate lists the file with the step's number" "$(jq -r '.failures[]? // empty' <<< "$RESULT")" \
    "unspecified_change:b.sh step=2"
assert_contains "[E9] the design is told the step changes it with no SPEC" "$(_f9 design)" \
    "step 2 changes b.sh but no SPEC says what it should do — add a SPEC, or say why it needs no test"
assert_eq "[E9] ...test-author is not asked for a test" "0" "$(_f9 test | grep -c 'b.sh' || true)"
assert_eq "[E9] ...nor build to take it out" "0" "$(_f9 code | grep -c 'b.sh' || true)"
assert_eq "[E9] the build loop can act on it" "recoverable" "$(jq -r '.severity // empty' <<< "$RESULT")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
