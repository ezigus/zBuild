#!/usr/bin/env bash
# tests/unit/judge-quotes-test.sh — a judge answers every item, and quotes the
# text each complaint is about (#2464, ADR-072 §2 §3).
#
# Why: on #1805 run 41679237388 design's coverage judge answered "covered" and
# then wrote `omitted` and `(none)` where its lists were empty; the engine read
# each as a finding, and two of design's three tries went on them. The same
# judge ruled a [done] claim wrong from ten lines of code.
#
# Q1 the quote check: words of the item itself, or a file's text in the
#    repository or the old-code copy, spacing aside; anything else is refused
# Q2 design's coverage check: one line per requirement and per SPEC; a missing
#    line or a quote that is not there is asked again, then `unusable`; junk
#    lines are never findings; a [done] claim is read on the old code, by file
# Q3 test-author's assertion check: a part the test falls short on quotes that
#    part's words (#2467: a line per part); one that does not is asked again,
#    then not judged
# Q4 issue-acceptance: one line per requirement; complaints quoted; no line
#    numbers or windows of code in its prompt
# Q5 a review lens quotes each finding's text from its file
# Q6 formatting is not the judge's to get right (#2472): `*`, `_` and backticks
#    are left out on both sides, as spacing is
# Q7 a quote mark written \" and a backslash written \\ inside a quote are the
#    characters themselves (#2487): on #1805 run 42397891946 issue-acceptance
#    quoted a line holding `"$dry_run"` as \"$dry_run\", and the check refused
#    both its quotes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a judge answers every item and quotes each complaint (#2464)"
setup_test_env "judge-quotes"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi
}

# A repository whose base commit holds the old code and whose branch holds the new.
XR="$TEST_TEMP_DIR/xrepo"; mkdir -p "$XR/scripts" "$XR/tests"
(
    cd "$XR" || exit 1
    git init -q -b main; git config user.email t@t; git config user.name t
    printf 'line one\nrefuse_missing_config() { [[ -f "$1" ]] || return 2; }\nskip_stage() {\n    continue\n}\n' > scripts/cfg.sh
    git add -A; git commit -qm base
    git checkout -qb feature
    printf 'line one\nrefuse_missing_config() { [[ -r "$1" ]] || return 3; }\n' > scripts/cfg.sh
    git commit -qam change
)
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state/runs/r1"; mkdir -p "$ZBUILD_STATE_DIR/artifacts"

# shellcheck source=../../scripts/lib/judge.sh
source "$REPO_ROOT/scripts/lib/judge.sh"

print_test_section "Q1: the quote check"
BASE=""; judge_base_dir_v BASE "$XR"
_q() { local why; judge_quote_check_v why "$1" "${2:-}" "$XR" "$BASE" && printf ok || printf 'bad: %s' "$why"; }
assert_eq "[Q1] the item's own words" "ok" "$(_q '"refuse a missing"' 'refuse a missing config file')"
assert_contains "[Q1] words the item does not say are refused" "$(_q '"accept a flag"' 'refuse a missing config file')" "bad:"
assert_eq "[Q1] a file's text in the repository" "ok" "$(_q 'scripts/cfg.sh:"[[ -r "$1" ]] || return 3"')"
assert_eq "[Q1] ...or in the code from before the change" "ok" "$(_q 'scripts/cfg.sh:"[[ -f "$1" ]] || return 2"')"
assert_eq "[Q1] spacing is not the judge's to get right" "ok" "$(_q 'scripts/cfg.sh:"refuse_missing_config()   {  [[ -r"')"
assert_eq "[Q1] text across lines, quoted on one" "ok" "$(_q 'scripts/cfg.sh:"skip_stage() { continue }"')"
assert_eq "[Q1] an absolute path inside the repository" "ok" "$(_q "$XR/scripts/cfg.sh:\"line one\"")"
assert_contains "[Q1] text the file does not hold is refused" "$(_q 'scripts/cfg.sh:"return 9"')" "bad:"
assert_contains "[Q1] ...and says which file" "$(_q 'scripts/cfg.sh:"return 9"')" "scripts/cfg.sh"
assert_contains "[Q1] a file that does not exist is refused" "$(_q 'scripts/nope.sh:"line one"')" "bad:"
assert_contains "[Q1] a path that leaves the repository is refused" "$(_q '../xrepo/scripts/cfg.sh:"line one"')" "bad:"
assert_contains "[Q1] no quote at all is refused" "$(_q '')" "bad:"
assert_contains "[Q1] a word in place of a quote is refused" "$(_q 'omitted' 'omitted')" "bad:"

print_test_section "Q2: design's coverage check"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    export ZBUILD_REPO_ROOT="$XR"
    _N="$TEST_TEMP_DIR/q2-n"; _P="$TEST_TEMP_DIR/q2-p"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        if [[ $n -eq 1 ]]; then printf '%s' "$_R1"; else printf '%s' "${_R2:-$_R1}"; fi
    }
    D="$TEST_TEMP_DIR/q2.md"
    cat > "$D" <<'MD'
# Design
```acceptance
DSWORK-1[code]: a --dry-run flag is accepted covers: RQRQST-1
DSCNFG-1[done]: a missing config is refused covers: RQRQST-2 evidence: scripts/cfg.sh:"refuse_missing_config()"
TESTFILES:
DSWORK-1: tests/acc-test.sh
WIRING: none
```
```scope
scripts/thing.sh
scripts/telemetry.sh
```
MD
    REQS='- RQRQST-1: add a --dry-run flag
- RQRQST-2: refuse a missing config file'
    _cov() { printf 0 > "$_N"; _design_coverage "$D" "$REQS" T2 >/dev/null 2>&1; }
    # #2491: a line for every scope entry, as for every SPEC.
    _sc=$'SCOPE: scripts/thing.sh: ok\nSCOPE: scripts/telemetry.sh: ok\n'
    _ok=$'RQRQST-1: covered\nRQRQST-2: covered\nDSWORK-1: ok\nDSCNFG-1: ok\n'"$_sc"

    _R1="$_ok"; _R2=""; _cov
    echo "Q2a|${#_DESIGN_UNCOVERED[@]}${#_DESIGN_OUTSIDE[@]}${#_DESIGN_DONE_WRONG[@]}|$_DESIGN_COV_OUTCOME|$(cat "$_N")"
    _p1="$(tr -s '[:space:]' ' ' < "$_P.1")"
    echo "Q2g|$([[ "$_p1" == *"|| return 2"* || "$_p1" == *"|| return 3"* ]] && echo snippet || echo nosnippet)"
    echo "Q2g2|$([[ "$_p1" == *"scripts/cfg.sh"* ]] && echo named)"
    echo "Q2g3|$([[ "$_p1" == *"$ZBUILD_STATE_DIR"* ]] && echo base)"
    echo "Q2g4|$([[ "$_p1" == *"QUOTE:"* ]] && echo quote)"

    _R1="${_ok}UNCOVERED: omitted
OUTSIDE: (none)
DONE_WRONG: none"; _R2=""; _cov
    echo "Q2b|${#_DESIGN_UNCOVERED[@]}${#_DESIGN_OUTSIDE[@]}${#_DESIGN_DONE_WRONG[@]}|$_DESIGN_COV_OUTCOME"

    _R1=$'RQRQST-1: covered\nRQRQST-2: uncovered | WHY: no SPEC refuses an unreadable file | QUOTE: "refuse a missing config file"\nDSWORK-1: ok\nDSCNFG-1: ok\n'"$_sc"; _R2=""; _cov
    echo "Q2c|${#_DESIGN_UNCOVERED[@]}|${_DESIGN_UNCOVERED[0]:-}|$(cat "$_N")"

    _R1=$'RQRQST-1: covered\nRQRQST-2: covered\nDSCNFG-1: ok\n'"$_sc"; _R2="$_ok"; _cov
    echo "Q2d|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"

    _R1=$'RQRQST-1: covered\nRQRQST-2: uncovered | WHY: x | QUOTE: "accept a flag"\nDSWORK-1: ok\nDSCNFG-1: ok\n'"$_sc"; _R2=""; _cov
    echo "Q2e|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"

    _R1=$'RQRQST-1: covered\nRQRQST-2: covered\nDSWORK-1: ok\nDSCNFG-1: done_wrong | WHY: it returns 2 only when the file is absent | QUOTE: scripts/cfg.sh:"[[ -f "$1" ]] || return 2"\n'"$_sc"; _R2=""; _cov
    echo "Q2f|${#_DESIGN_DONE_WRONG[@]}|${_DESIGN_DONE_WRONG[0]:-}|$_DESIGN_COV_OUTCOME"

    _R1=$'RQRQST-1: covered\nRQRQST-2: covered\nDSWORK-1: done_wrong | WHY: x | QUOTE: scripts/cfg.sh:"line one"\nDSCNFG-1: ok\n'"$_sc"; _R2="$_R1"; _cov
    echo "Q2h|$_DESIGN_COV_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"

    _R1=$'RQRQST-1: covered\nRQRQST-2: covered\nDSWORK-1: ok\nDSCNFG-1: ok\nSCOPE: scripts/thing.sh: ok\nSCOPE: scripts/telemetry.sh: outside | WHY: the issue asks for no telemetry\n'; _R2=""; _cov
    echo "Q2i|${#_DESIGN_OUTSIDE[@]}|$(_design_coverage_findings)"
) > "$TEST_TEMP_DIR/q2.out" 2>"$TEST_TEMP_DIR/q2.err"
_l() { grep "^$1|" "$TEST_TEMP_DIR/q2.out" | head -1 | cut -d'|' -f2-; }
assert_eq "[Q2] every item answered, none failing: nothing found, judged in one call" "000||1" "$(_l Q2a)"
assert_eq "[Q2] the prompt carries no window of code" "nosnippet" "$(_l Q2g)"
assert_eq "[Q2] ...it names the evidence's file" "named" "$(_l Q2g2)"
assert_eq "[Q2] ...and where the code from before the change is" "base" "$(_l Q2g3)"
assert_eq "[Q2] ...and asks for a quote with each complaint" "quote" "$(_l Q2g4)"
assert_eq "[Q2] 'omitted', '(none)' and 'none' are never findings" "000|" "$(_l Q2b)"
assert_contains "[Q2] an uncovered requirement with a real quote is a finding" "$(_l Q2c)" "1|RQRQST-2"
assert_contains "[Q2] ...that says why" "$(_l Q2c)" "no SPEC refuses an unreadable file"
assert_contains "[Q2] a missing line is asked again, naming it" "$(_l Q2d)" "2||"
assert_contains "[Q2] ...naming it" "$(_l Q2d)" "no line for DSWORK-1"
assert_contains "[Q2] a quote the requirement does not say is asked again, then unusable" "$(_l Q2e)" "2|unusable|"
assert_contains "[Q2] ...saying which quote" "$(_l Q2e)" "RQRQST-2's quote is not in"
assert_contains "[Q2] a [done] claim is judged on the code from before the change" "$(_l Q2f)" "1|DSCNFG-1"
assert_contains "[Q2] ...and carries its quote" "$(_l Q2f)" 'return 2'
assert_contains "[Q2] done_wrong on a SPEC not marked [done] cannot be used" "$(_l Q2h)" "unusable|"
assert_contains "[Q2] ...and is asked again, saying so" "$(_l Q2h)" "DSWORK-1 is not marked [done]"
assert_contains "[Q2] a scope entry the issue does not ask for is a finding" "$(_l Q2i)" "1|SCOPE scripts/telemetry.sh: the issue asks for no telemetry [FIX IN DESIGN:"

print_test_section "Q3: test-author's assertion check"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    _N="$TEST_TEMP_DIR/q3-n"; _P="$TEST_TEMP_DIR/q3-p"
    route_to_model() {
        cat >/dev/null
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        if [[ $n -eq 1 ]]; then printf '%s' "$_R1"; else printf '%s' "${_R2:-$_R1}"; fi
    }
    R="$TEST_TEMP_DIR/q3-repo"; mkdir -p "$R/tests"; D="$TEST_TEMP_DIR/q3.md"
    printf '# Design\n```acceptance\nDSLOOP-1[code]: fresh runs and nested re-entries start at round 1\nWIRING: none\nTESTFILES:\nDSLOOP-1: tests/acc-test.sh\n```\n' > "$D"
    printf 'unset RESUME\nassert_eq "[DSLOOP-1] a fresh run starts at 1" "1" "$got"\n' > "$R/tests/acc-test.sh"
    _j() { printf 0 > "$_N"; _ta_correspondence "$D" "$R" T2 >/dev/null 2>&1; }

    # #2467 (ADR-073 §6): a line per failing part (this one-line SPEC is its
    # one Then), named by its word (#2470).
    _R1=$'DSLOOP-1 Then: missing | WHY: only a fresh run is tested | QUOTE: "nested re-entries"'; _R2=""; _j
    echo "Q3a|${#_TA_CORR_FINDINGS[@]}|${_TA_CORR_FINDINGS[0]:-}|$_TA_CORR_OUTCOME|$(cat "$_N")"
    echo "Q3p|$([[ "$(cat "$_P.1")" == *'QUOTE: "<that part'"'"'s own words'* ]] && echo asked)"

    _R1=$'DSLOOP-1 Then: missing | WHY: only a fresh run is tested'
    _R2=$'DSLOOP-1 Then: missing | WHY: only a fresh run is tested | QUOTE: "nested re-entries"'; _j
    echo "Q3b|$(cat "$_N")|${#_TA_CORR_FINDINGS[@]}|$_TA_CORR_OUTCOME"

    _R1=$'DSLOOP-1 Then: missing | WHY: only a fresh run is tested'
    _R2="$_R1"; _j
    echo "Q3c|$(cat "$_N")|${#_TA_CORR_FINDINGS[@]}|$_TA_CORR_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.3" 2>/dev/null)"

    _R1=$'DSLOOP-1 Then: wrong | WHY: x | QUOTE: "a resumed run reads the saved round"'
    _R2="$_R1"; _j
    echo "Q3d|${#_TA_CORR_FINDINGS[@]}|$_TA_CORR_OUTCOME"

    _R1=$'DSLOOP-1: ok'; _R2=""; _j
    echo "Q3e|${#_TA_CORR_FINDINGS[@]}|$_TA_CORR_OUTCOME|$(cat "$_N")"
) > "$TEST_TEMP_DIR/q3.out" 2>/dev/null
_l() { grep "^$1|" "$TEST_TEMP_DIR/q3.out" | head -1 | cut -d'|' -f2-; }
assert_contains "[Q3] partial with the requirement's words quoted is a finding" "$(_l Q3a)" "1|DSLOOP-1"
assert_contains "[Q3] ...in one call" "$(_l Q3a)" "||1"
assert_eq "[Q3] the check asks for the quote" "asked" "$(_l Q3p)"
assert_eq "[Q3] partial with no quote is asked again on its own, and the answer counts" "2|1|" "$(_l Q3b)"
assert_contains "[Q3] still no quote: asked again once more, then not judged" "$(_l Q3c)" "3|0|unusable|"
assert_contains "[Q3] ...told what was wrong" "$(_l Q3c)" "DSLOOP-1 Then has no QUOTE"
assert_eq "[Q3] a quote the requirement does not say is not judged" "0|unusable" "$(_l Q3d)"
assert_eq "[Q3] corresponds needs no quote" "0||1" "$(_l Q3e)"

print_test_section "Q4: issue-acceptance"
_mk_inputs() {  # <dir> — the issue, its requirements, a design, a diff, a test run, each by its writer
    local in="$1"; mkdir -p "$in"
    zb_test_issue_output "$in" "Add a flag. Refuse a missing config file." >/dev/null
    (
        # shellcheck source=../../plugins/agent/intake/plugin.sh
        source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
        route_to_model() {
            if [[ "$2" == *"check a list of requirements"* ]]; then printf 'MISSING: none\n'
            else printf 'REQUIREMENT: RQFLAG-1 add a --dry-run flag\nREQUIREMENT: RQCNFG-1 refuse a missing config file\n'; fi
        }
        _intake_write_requirements "$in" '{"title":"Add a flag","body":"Add a flag. Refuse a missing config file."}'
    ) >/dev/null 2>&1
    printf '%s\n' '# Design' '```acceptance' 'DSFLAG-1[code]: a --dry-run flag is accepted' 'DSCNFG-2[done]: a missing config is refused evidence: scripts/cfg.sh:"refuse_missing_config()"' 'TESTFILES:' 'DSFLAG-1: tests/t.sh' 'WIRING: none' '```' > "$in/design.md"
    printf '%s\n' 'diff --git a/p.sh b/p.sh' '+dry_run=1' > "$in/diff.patch"
    zb_test_test_run_output "$in" pass 1 0 >/dev/null
}
(
    # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
    # shellcheck source=../../scripts/lib/stage-result.sh
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    export ZBUILD_REPO_ROOT="$XR"
    _N="$TEST_TEMP_DIR/q4-n"; _P="$TEST_TEMP_DIR/q4-p"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        if [[ $n -eq 1 ]]; then printf '%s\n' "$_R1"; else printf '%s\n' "${_R2:-$_R1}"; fi
    }
    resolve_tier() { printf 'T2'; }
    S="$TEST_TEMP_DIR/q4"; A="$S/artifacts"; mkdir -p "$A"; printf '{}' > "$S/pipeline-state.json"
    _mk_inputs "$S/inputs"
    jq -n --arg i "$S/inputs/intake-result.json" --arg r "$S/inputs/requirements.json" --arg d "$S/inputs/design.md" \
        --arg p "$S/inputs/diff.patch" --arg t "$S/inputs/test-results.json" \
        '{inputs: {a: $i, r: $r, b: $d, c: $p, d: $t}}' > "$S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A"
    # Each case is a new answer to the same inputs: the kept one is cleared (ADR-072 §4).
    _ia() { printf 0 > "$_N"; rm -f "$A/issue-acceptance-result.json" "$A/issue-acceptance-judged.json"; issue_acceptance_run issue-acceptance "$S/pipeline-state.json" >/dev/null 2>&1; jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null; }

    _R1=$'MET: RQFLAG-1\nMET: RQCNFG-1'; _R2=""
    echo "Q4a|$(_ia)|$(cat "$_N")"
    _p1="$(tr -s '[:space:]' ' ' < "$_P.1")"
    echo "Q4w|$([[ "$_p1" =~ \ [0-9]+\|\  ]] && echo window || echo nowindow)"
    echo "Q4w2|$([[ "$_p1" == *'scripts/cfg.sh:"refuse_missing_config()"'* ]] && echo named)"

    _R1=$'MET: RQFLAG-1\nUNMET: [fix-code] RQCNFG-1 | WHY: an unreadable file is not refused | QUOTE: "refuse a missing config file"'; _R2=""
    echo "Q4b|$(_ia)|$(jq -r '.data.findings[0].text // ""' "$A/issue-acceptance-result.json")"

    _R1=$'MET: RQFLAG-1'; _R2=$'MET: RQFLAG-1\nMET: RQCNFG-1'
    echo "Q4c|$(_ia)|$(cat "$_N")|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"

    _R1=$'MET: RQFLAG-1\nUNMET: [fix-code] RQCNFG-1 | WHY: x | QUOTE: scripts/cfg.sh:"return 9"'; _R2=""
    echo "Q4d|$(_ia)|$(cat "$_N")|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"

    _R1=$'MET: RQFLAG-1\nMET: RQCNFG-1\nUNMET: none\nUNSURE: omitted'; _R2=""
    echo "Q4e|$(_ia)"
) > "$TEST_TEMP_DIR/q4.out" 2>/dev/null
_l() { grep "^$1|" "$TEST_TEMP_DIR/q4.out" | head -1 | cut -d'|' -f2-; }
assert_eq "[Q4] every requirement met: pass, in one call" "pass|1" "$(_l Q4a)"
assert_eq "[Q4] the prompt carries no numbered window of code" "nowindow" "$(_l Q4w)"
assert_eq "[Q4] ...it names the evidence by its file and text" "named" "$(_l Q4w2)"
assert_contains "[Q4] an unmet requirement with a real quote fails, as a finding" "$(_l Q4b)" "fail|"
assert_contains "[Q4] ...that names it and says why" "$(_l Q4b)" "RQCNFG-1"
assert_contains "[Q4] a requirement with no line is asked again" "$(_l Q4c)" "pass|2|"
assert_contains "[Q4] ...naming it" "$(_l Q4c)" "no line for RQCNFG-1"
assert_contains "[Q4] a quote the file does not hold, twice: unusable" "$(_l Q4d)" "unusable|2|"
assert_contains "[Q4] ...asked again saying which quote" "$(_l Q4d)" "RQCNFG-1's quote is not in scripts/cfg.sh"
assert_eq "[Q4] 'none' and 'omitted' are never findings" "pass" "$(_l Q4e)"

print_test_section "Q5: a review lens quotes each finding"
(
    # shellcheck source=../../core/plugin-registry/registry.sh
    source "$REPO_ROOT/core/plugin-registry/registry.sh"
    # shellcheck source=../../plugins/agent/review-lens/plugin.sh
    source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
    export ZBUILD_REPO_ROOT="$XR"
    ART="$TEST_TEMP_DIR/q5"; mkdir -p "$ART"
    printf '%s\n' 'diff --git a/scripts/cfg.sh b/scripts/cfg.sh' '-refuse_missing_config() { [[ -f "$1" ]] || return 2; }' '+refuse_missing_config() { [[ -r "$1" ]] || return 3; }' > "$ART/diff.patch"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/q5-scope.md"
    _N="$TEST_TEMP_DIR/q5-n"; _P="$TEST_TEMP_DIR/q5-p"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        if [[ $n -eq 1 ]]; then printf '%s' "$_R1"; else printf '%s' "${_R2:-$_R1}"; fi
    }
    _lens() {
        printf 0 > "$_N"; rm -f "$ART/lens-red-team.json" "$ART/lens-red-team-judged.json"
        _TPL_STAGE_FAIL_ON_review_lenses="medium high critical" ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=red-team \
            _review_lens_run_inner red-team "$TEST_TEMP_DIR/q5-scope.md" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1 || true
        jq -r '.outcome // "none"' "$ART/lens-red-team.json" 2>/dev/null
    }
    _f() { printf '{"score":5,"findings":[{"file":"scripts/cfg.sh","severity":"high","message":"exit code changed","introduced":true,"quote":%s}]}' "$1"; }
    _R1="$(_f '"[[ -r \"$1\" ]] || return 3"')"; _R2=""
    echo "Q5a|$(_lens)|$(cat "$_N")|$(jq -r '.findings[0].quote // ""' "$ART/lens-red-team.json")"
    echo "Q5p|$([[ "$(cat "$_P.1")" == *'"quote": "<the exact text'* ]] && echo asked)"
    _R1="$(_f '"[[ -f \"$1\" ]] || return 2"')"; _R2=""
    echo "Q5b|$(_lens)"
    _R1='{"score":5,"findings":[{"file":"scripts/cfg.sh","severity":"high","message":"m","introduced":true}]}'; _R2="$(_f '"[[ -r \"$1\" ]] || return 3"')"
    echo "Q5c|$(_lens)|$(cat "$_N")|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
    _R1="$(_f '"return 9"')"; _R2=""
    echo "Q5d|$(_lens)|$(cat "$_N")|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
) > "$TEST_TEMP_DIR/q5.out" 2>/dev/null
_l() { grep "^$1|" "$TEST_TEMP_DIR/q5.out" | head -1 | cut -d'|' -f2-; }
assert_contains "[Q5] a finding quoting its file's text counts" "$(_l Q5a)" "fail|1|"
assert_contains "[Q5] ...and keeps its quote" "$(_l Q5a)" 'return 3'
assert_eq "[Q5] the lens is asked for a quote" "asked" "$(_l Q5p)"
assert_eq "[Q5] a quote of a line the change removed counts too" "fail" "$(_l Q5b)"
assert_contains "[Q5] a finding with no quote is asked again, and the answer counts" "$(_l Q5c)" "fail|2|"
assert_contains "[Q5] ...told which finding" "$(_l Q5c)" "finding 1 has no quote"
assert_contains "[Q5] a quote its file does not hold, twice: unusable" "$(_l Q5d)" "unusable|2|"
assert_contains "[Q5] ...asked again saying which finding" "$(_l Q5d)" "finding 1's quote is not in scripts/cfg.sh"

print_test_section "Q6: formatting aside (#2472)"
# #1805 run 41951779189: the issue wrote `stage *k* is dispatched`; the judge
# quoted it as it reads, and the check refused it twice.
_Q6W='RQRESU-4: Resuming it does not dispatch stages 1…*k−1*, and stage *k* is dispatched. Run `zbuild_resume` on __init__.'
assert_eq "[Q6] a quote with the emphasis left out holds" "ok" "$(_q '"stage k is dispatched"' "$_Q6W")"
assert_eq "[Q6] ...across marks next to other characters" "ok" "$(_q '"stages 1…k−1, and"' "$_Q6W")"
assert_eq "[Q6] backticks and underscores left out hold" "ok" "$(_q '"Run zbuildresume on init"' "$_Q6W")"
assert_eq "[Q6] a quote that keeps the marks still holds" "ok" "$(_q '"stage *k* is dispatched"' "$_Q6W")"
assert_eq "[Q6] a quote across a line break holds" "ok" "$(_q '"is dispatched. Run"' "stage *k* is"$'\n'"  dispatched.   Run")"
assert_contains "[Q6] words that are not there are still refused" "$(_q '"stage k is skipped"' "$_Q6W")" "bad:"
assert_contains "[Q6] the refusal says the item's own words" "$(_q '"stage k is skipped"' "$_Q6W")" "is not in the item's own words"
assert_not_contains "[Q6] ...and no variable name" "$(_q '"stage k is skipped"' "$_Q6W")" "_judge__"
printf 'see `skip_stage` and *every* stage\n' >> "$XR/scripts/cfg.sh"
assert_eq "[Q6] a file's text, formatting aside" "ok" "$(_q 'scripts/cfg.sh:"see skipstage and every stage"')"

print_test_section "Q7: an escaped quote mark is the mark itself"
printf '%s\n' 'if ! _gate "$dry_run" "$mode"; then' 'grep -c '"'"'_gate "\$dry_run"'"'"' f' >> "$XR/scripts/cfg.sh"
assert_eq "[Q7] \\\" in a file quote is a quote mark" "ok" "$(_q 'scripts/cfg.sh:"if ! _gate \"$dry_run\" \"$mode\"; then"')"
assert_eq "[Q7] ...and a backslash that is really in the file still holds" "ok" "$(_q 'scripts/cfg.sh:"_gate \"\$dry_run\""')"
assert_eq "[Q7] ...as does \\\\ written for it" "ok" "$(_q 'scripts/cfg.sh:"_gate \"\\$dry_run\""')"
assert_eq "[Q7] \\\" in the item's own words is a quote mark" "ok" "$(_q '"run \"zbuild\" now"' 'please run "zbuild" now')"
assert_contains "[Q7] words that are not there are still refused" "$(_q 'scripts/cfg.sh:"if ! _gate \"$wet_run\""')" "bad:"

cleanup_test_env
print_test_results
