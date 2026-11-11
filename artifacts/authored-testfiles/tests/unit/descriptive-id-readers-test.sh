#!/usr/bin/env bash
# tests/unit/descriptive-id-readers-test.sh — every reader of a SPEC id reads a
# descriptive one (FSTG-1), and still reads the old SPEC-n form (#2462,
# ADR-069 §1).
#
# Why: SPEC ids now describe their item. Twelve places read an id with a
# pattern written for `SPEC-<n>` alone; each would drop a descriptive id
# silently — a requirement nobody tests, a binding nobody runs, a stale tag
# nobody removes. The 371 test files that carry earlier issues' [SPEC-n] tags
# must still read as before.
#
# R1  [code] the acceptance block's SPEC lines and REMOVED lines read with
#            descriptive ids; a REMOVED line is not part of a SPEC's words
# R2  [code] a SPEC's test files are found by its descriptive tag (#2508:
#            design names no files, so there is no binding to read)
# R3  [code] the WIRING list stops at a descriptive binding line
# R4  [code] [done] evidence `file:"text with spaces"` is one item
# R5  [code] the old-code check finds the last other verdict by a descriptive tag
# R6  [code] the acceptance check reads the id on a NEGCTL line
# R7  [code] build's limits name no test file (#2508: no file list at all), and
#            its false-completion probe does not read SPEC-<n> alone
# R8  [code] the status comment shows a descriptive label as code
# R9  [code] test-author drops this issue's tags no longer in the contract,
#            whatever their form, and keeps other issues' tags
# R10 [code] the coverage check and issue-acceptance name the evidence by its
#            file and text, not a line number (#2464: and no window of lines)
# R11 [code] old SPEC-n ids still read everywhere above
#            (#2482: the ids above carry their stage's prefix, DSFSTG-1: every
#            reader reads the longer form)
# R12 [code] issue-acceptance is not told the requirements are numbered R-1, R-2
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "every reader of a SPEC id reads a descriptive one (#2462)"
setup_test_env "descriptive-id-readers"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"
set +e
assert_not_contains() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
unset ZBUILD_ACCEPTANCE_RUN_CMD 2>/dev/null || true
_ID="$(zb_test_issue)"

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'EOF'
# D
```acceptance
WIRING:
core/run.sh
DSFSTG-1[code]: --from-stage runs the stage first
  and puts earlier outputs back covers: RQRSUM-1
REMOVED: DSFSTG-2 — folded into DSFSTG-1
SPEC-3[no-code]: an old-form requirement
DSGARD-1[done]: a new run never skips evidence: core/run.sh:"if $resume_mode && x" tests/unit/a-test.sh
```
EOF

# ── R1 / R11 ─────────────────────────────────────────────────────────────────
assert_eq "[R1] descriptive and old ids are listed" "DSFSTG-1 SPEC-3 DSGARD-1" \
    "$(acceptance_list_spec_ids "$D" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "[R1] a REMOVED line is read with its reason" "DSFSTG-2	folded into DSFSTG-1" \
    "$(acceptance_list_removed_ids "$D")"
assert_eq "[R1] ...and is not part of the SPEC before it" \
    "--from-stage runs the stage first and puts earlier outputs back" "$(acceptance_spec_text "$D" DSFSTG-1)"
assert_eq "[R1] covers reads after a wrapped line" "RQRSUM-1" "$(acceptance_spec_covers "$D" DSFSTG-1)"

# ── R2 ───────────────────────────────────────────────────────────────────────
TR="$TEST_TEMP_DIR/tagrepo"; mkdir -p "$TR/tests/unit"; git -C "$TR" init -q
printf 'assert "[DSFSTG-1] runs first"\n' > "$TR/tests/unit/from-stage-test.sh"
printf 'assert "[DSFSTG-1] puts back"\n' > "$TR/tests/unit/from-stage-more-test.sh"
printf 'assert "[SPEC-3] old"\n' > "$TR/tests/unit/old-test.sh"
assert_eq "[R2] a descriptive id's test files, found by its tag" \
    "tests/unit/from-stage-more-test.sh tests/unit/from-stage-test.sh" \
    "$(acceptance_list_testfiles_for_spec "$D" DSFSTG-1 "$TR" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "[R11] an old id's file" "tests/unit/old-test.sh" "$(acceptance_list_testfiles_for_spec "$D" SPEC-3 "$TR")"
assert_eq "[R2] the union of test files" \
    "tests/unit/from-stage-more-test.sh tests/unit/from-stage-test.sh tests/unit/old-test.sh" \
    "$(acceptance_list_testfiles "$D" "$TR" | tr '\n' ' ' | sed 's/ $//')"

# ── R3 ───────────────────────────────────────────────────────────────────────
assert_eq "[R3] WIRING stops at a descriptive SPEC line" "core/run.sh" "$(acceptance_list_wiring "$D")"

# ── R4 ───────────────────────────────────────────────────────────────────────
assert_eq "[R4] quoted evidence text with spaces is one item" \
    "core/run.sh:\"if \$resume_mode && x\""$'\n'"tests/unit/a-test.sh" "$(acceptance_spec_evidence "$D" DSGARD-1)"

# ── R5 ───────────────────────────────────────────────────────────────────────
LOG="$TEST_TEMP_DIR/negctl.log"
export ZBUILD_ISSUE="$_ID"
printf '✓ [#%s/DSFSTG-1] runs first\n✗ [#%s/DSGARD-1] never skips\n' "$_ID" "$_ID" > "$LOG"
assert_eq "[R5] the last other verdict, by a descriptive tag" "DSGARD-1" "$(_negctl_last_other_verdict "$LOG" DSLOOP-9)"
printf '✓ [#%s/SPEC-2] old\n' "$_ID" > "$LOG"
assert_eq "[R11] ...and by an old one" "SPEC-2" "$(_negctl_last_other_verdict "$LOG" DSLOOP-9)"
unset ZBUILD_ISSUE

# ── R6 ───────────────────────────────────────────────────────────────────────
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh" 2>/dev/null
_id=""; _ag_negctl_line_id_v _id "NEGCTL PASS DSFSTG-1 control_valid"
assert_eq "[R6] the id on a NEGCTL PASS line" "DSFSTG-1" "$_id"
_id=""; _ag_negctl_line_id_v _id "NEGCTL ERROR timeout:DSGARD-1"
assert_eq "[R6] ...and on a NEGCTL ERROR line" "DSGARD-1" "$_id"
_id=""; _ag_negctl_line_id_v _id "NEGCTL FAIL SPEC-4 tautology"
assert_eq "[R11] ...and an old one" "SPEC-4" "$_id"

# ── R7 ───────────────────────────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/build/lib/prompt.sh
source "$REPO_ROOT/plugins/agent/build/lib/prompt.sh" 2>/dev/null
_lim="$(_build_compose_limits "" 2>/dev/null)"
if [[ "$_lim" == *"tests/unit/from-stage-test.sh"* || "$_lim" == *"### Scope"* ]]; then
    assert_fail "[R7] build's limits name no test file and no scope list" "$_lim"
else
    assert_pass "[R7] build's limits name no test file and no scope list"
fi
_sum_src="$(cat "$REPO_ROOT/plugins/agent/build/lib/summary.sh")"
_probe_re="$(sed -n '/_build_guard_false_completion()/,/^}/p' <<< "$_sum_src" | grep -c 'SPEC-\[0-9\]' || true)"
assert_eq "[R7] the false-completion probe no longer reads SPEC-<n> alone" "0" "$_probe_re"

# ── R8 ───────────────────────────────────────────────────────────────────────
# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh" 2>/dev/null
_o=""; _rsc_code_labels_v _o "failed [#1805/DSFSTG-1] and "
assert_eq "[R8] descriptive and old labels are shown as code" 'failed `[#1805/DSFSTG-1]` and ``' "$_o"

# ── R9 ───────────────────────────────────────────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO/tests/unit"
git -C "$REPO" init -q -b main; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m base; git -C "$REPO" checkout -qb work   # #2520: the step reads the branch's lines
printf 'assert "[#%s/DSFSTG-1] keep" 1\nassert "[#%s/SPEC-3] old form, still in contract" 1\nassert "[#%s/SPEC-7] stale" 1\nassert "[#%s/DSLOOP-2] stale" 1\nassert "[#99/DSLOOP-2] other issue" 1\nassert "[UTF-8] not a tag" 1\n' "$_ID" "$_ID" "$_ID" "$_ID" \
    > "$REPO/tests/unit/from-stage-test.sh"
# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" 2>/dev/null
ZBUILD_ISSUE="$_ID" _ta_drop_stale_tags "$D" "$REPO"
_tf="$(cat "$REPO/tests/unit/from-stage-test.sh")"
assert_contains "[R9] a tag still in the contract stays" "$_tf" "[#$_ID/DSFSTG-1] keep"
assert_contains "[R11] ...an old-form one too" "$_tf" "[#$_ID/SPEC-3]"
assert_not_contains "[R9] this issue's old-form tag no longer in the contract goes" "$_tf" "[#$_ID/SPEC-7]"
assert_not_contains "[R9] ...and a descriptive one" "$_tf" "[#$_ID/DSLOOP-2]"
assert_contains "[R9] another issue's tag stays" "$_tf" "[#99/DSLOOP-2]"
assert_contains "[R9] a bracket that is no tag stays" "$_tf" "[UTF-8]"

# ── R10 ──────────────────────────────────────────────────────────────────────
G="$(setup_git_temp_repo id-readers)"
mkdir -p "$G/core"; printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nif $resume_mode && x\nfin\n' > "$G/core/run.sh"
git -C "$G" add -A >/dev/null 2>&1; git -C "$G" -c user.email=t@t -c user.name=t commit -qm r >/dev/null 2>&1
# shellcheck source=../../plugins/agent/design/lib/coverage.sh
source "$REPO_ROOT/plugins/agent/design/lib/coverage.sh" 2>/dev/null
# #2464 (ADR-072 §2): the judges are pointed at the file and its text, and
# open it themselves — no window of lines.
# #2470: per SPEC, read off the SPECs as the check reads them.
_cov="$(
    ids=(); declare -A first=() text=() st=() render=() labs=() pword=() ptext=() ev=()
    _dcov_specs "$(extract_acceptance_block "$D")"
    _dcov_done_evidence_v ev "$D" "$G"
    printf '%s' "${ev[@]}"
)"
assert_contains "[R10] the coverage check names the evidence by its text" "$_cov" 'if $resume_mode'
assert_contains "[R10] ...and the file to open" "$_cov" "open $G/core/run.sh"
_jdg="$(acceptance_requirements_for_judge "$D")"
assert_contains "[R10] issue-acceptance names the evidence by its text" "$_jdg" 'if $resume_mode'
assert_not_contains "[R10] ...with no window of lines" "$_jdg" '13| if $resume_mode && x'

# ── R12 ──────────────────────────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
_iap="$(_ia_prompt "I" "S" "D" "pass" 2>/dev/null | tr -s '[:space:]' ' ')"
assert_contains "[R12] issue-acceptance's prompt names the issue's requirements" "$_iap" "ISSUE REQUIREMENTS"
_num=0; [[ "$_iap" == *"numbered R-1"* || "$_iap" == *"(R-2:"* ]] && _num=1
assert_eq "[R12] ...and does not say they are numbered R-1, R-2" "0" "$_num"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
