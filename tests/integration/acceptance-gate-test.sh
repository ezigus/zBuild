#!/usr/bin/env bash
# Integration: the acceptance-gate plugin (ADR-036 #922) end-to-end through its
# run hook — load-bearing → pass, tautological → fail, no block → skipped no-op.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate plugin — end-to-end (#922)"
setup_test_env "acceptance-gate-plugin"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# build a repo whose `main` lacks impl and whose feature HEAD adds impl + tests
_build_repo() {  # _build_repo <name> <head_test_body>
    local name="$1" body="$2"
    local repo; repo="$(setup_git_temp_repo "$name")"
    (
        cd "$repo"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
        printf '%s\n' "$body" > tests/feature-test.sh
        chmod +x tests/feature-test.sh impl.sh
        "$GIT" add -A; "$GIT" commit -q -m "feat"
    )
    printf '%s' "$repo"
}

# Variant that also captures the operator summary emitted to fd 2.
# Defines template_stage_io_dests to enable summary output. Sets SUMMARY in
# addition to RC, RESULT, EVENTS.
_run_gate_with_summary() {
    local repo="$1"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$state_dir/artifacts/design.md" 2>/dev/null || true
    unset _ZBUILD_ACCEPTANCE_GATE_LOADED
    local _sf; _sf="$(mktemp)"
    # Define stub AFTER source so it overrides the template.sh lookup-based version
    # that stage-io.sh transitively loads when the plugin is sourced.
    ( cd "$repo" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
          && template_stage_io_dests() { printf 'stdout\n'; } \
          && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" ) 2>"$_sf"
    RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
    SUMMARY="$(cat "$_sf")"
    rm -f "$_sf"
}

_run_gate() {  # _run_gate <repo> → sets RC, RESULT, EVENTS
    local repo="$1"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$state_dir/artifacts/design.md" 2>/dev/null || true
    # fresh plugin load per call (guard var would block re-source)
    unset _ZBUILD_ACCEPTANCE_GATE_LOADED
    # shellcheck disable=SC1090
    ( cd "$repo" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" )
    RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
}

# ── S1: load-bearing tagged test → verdict=pass ───────────────────────────────
REPO1="$(_build_repo gate-lb '#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
source "$impl"; my_feature')"
cat > "$REPO1/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO1"; set -e
assert_eq "S1: load-bearing → rc=0" "0" "$RC"
assert_eq "S1: verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"
assert_event_emitted "S1: complete event" "$EVENTS" "acceptance.gate.complete"

# ── S2: tautological tagged test → verdict=fail ───────────────────────────────
REPO2="$(_build_repo gate-taut '#!/usr/bin/env bash
# [SPEC-1] always true
exit 0')"
cat > "$REPO2/design.md" <<'EOF'
```acceptance
SPEC-1: always true
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO2"; set -e
assert_eq "S2: tautological → rc=1" "1" "$RC"
assert_eq "S2: verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"
assert_event_emitted "S2: tautology event" "$EVENTS" "acceptance.gate.tautology"

# ── S3: untagged SPEC → verdict=fail (Level-1) ────────────────────────────────
REPO3="$(_build_repo gate-untagged '#!/usr/bin/env bash
# no spec tag here
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1')"
cat > "$REPO3/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO3"; set -e
assert_eq "S3: untagged → rc=1" "1" "$RC"
assert_event_emitted "S3: untagged_spec event" "$EVENTS" "acceptance.gate.untagged_spec"

# ── S4: no acceptance block → no-op pass (precondition_unmet) ─────────────────
# Precondition `design_acceptance_block` unmet: the SPEC methodology is not in
# use, so the gate no-ops (this is what makes it safe on foreign repos).
REPO4="$(_build_repo gate-noblock '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
printf '# Design\nNo acceptance block here.\n' > "$REPO4/design.md"
set +e; _run_gate "$REPO4"; set -e
assert_eq "S4: no block → rc=0" "0" "$RC"
assert_eq "S4: verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"
assert_eq "S4: reason=precondition_unmet" "precondition_unmet" "$(jq -r .reason <<<"$RESULT")"
assert_eq "S4: precondition=design_acceptance_block" "design_acceptance_block" "$(jq -r .precondition <<<"$RESULT")"
assert_event_emitted "S4: skipped event" "$EVENTS" "acceptance.gate.skipped"

# ── S5: malformed acceptance block (fence but no TESTFILES) → fail closed ─────
REPO5="$(_build_repo gate-malformed '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
cat > "$REPO5/design.md" <<'EOF'
```acceptance
SPEC-1: missing testfiles section and closing fence
EOF
set +e; _run_gate "$REPO5"; set -e
assert_eq "S5: malformed block → rc=1 (fail closed, not skipped)" "1" "$RC"
assert_eq "S5: verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"

# ── S6: guard SPEC with tautological test → verdict=pass (NEGCTL SKIP) ────────
# A [guard]-classified SPEC with a test that always passes at baseline must
# be accepted (negctl skips it) rather than rejected as tautological.
REPO6="$(_build_repo gate-guard '#!/usr/bin/env bash
# [SPEC-1] guard: invariant that must not regress
exit 0')"
cat > "$REPO6/design.md" <<'EOF'
```acceptance
SPEC-1[guard]: invariant that must not regress
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO6"; set -e
assert_eq "S6: guard SPEC with tautological test → rc=0" "0" "$RC"
assert_eq "S6: verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"

# ── S7: change SPEC with tautological test still caught ───────────────────────
# A [change]-classified SPEC with a tautological test must still fail (negctl
# runs baseline check for change SPECs; guard-skip must not apply here).
REPO7="$(_build_repo gate-change-taut '#!/usr/bin/env bash
# [SPEC-1] change: always true
exit 0')"
cat > "$REPO7/design.md" <<'EOF'
```acceptance
SPEC-1[change]: new behavior introduced
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO7"; set -e
assert_eq "S7: [change] SPEC with tautological test → rc=1" "1" "$RC"
assert_eq "S7: verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"

# ── S8: a test that outlives the timeout → INFRA class, not a violation (#1188) ─
# The plugin resolves ZBUILD_NEGCTL_TIMEOUT (env wins) and exports the artifact
# dir; a timeout records negctl_error:timeout:SPEC-1, emits the negctl_timeout
# event, and captures a per-SPEC diagnostic log.
if command -v timeout >/dev/null 2>&1; then
    REPO8="$(_build_repo gate-timeout '#!/usr/bin/env bash
# [SPEC-1] slow feature
sleep 30')"
    cat > "$REPO8/design.md" <<'EOF'
```acceptance
SPEC-1: slow feature
TESTFILES:
tests/feature-test.sh
```
EOF
    export ZBUILD_NEGCTL_TIMEOUT=1
    set +e; _run_gate "$REPO8"; set -e
    unset ZBUILD_NEGCTL_TIMEOUT
    assert_eq "S8: timeout → rc=1 (gate records infra failure)" "1" "$RC"
    assert_eq "S8: verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"
    assert_eq "S8: failure class is negctl_error:timeout:SPEC-1 (not a violation)" \
        "negctl_error:timeout:SPEC-1" "$(jq -r '.failures[0]' <<<"$RESULT")"
    assert_event_emitted "S8: negctl_timeout event" "$EVENTS" "acceptance.gate.negctl_timeout"
    [[ -f "$REPO8/.zbuild-state/artifacts/negctl-SPEC-1.log" ]] \
        && assert_pass "S8: negctl-SPEC-1.log diagnostic artifact captured" \
        || assert_fail "S8: expected negctl-SPEC-1.log artifact" "missing"
else
    assert_pass "S8: skipped (no 'timeout' binary available)"
fi

# ── S9: placeholder block (empty TESTFILES, no SPECs) → no-op precondition ────
# A well-formed block that declares NO SPEC ids and an empty TESTFILES section
# is a placeholder, not adopted methodology → no-op pass
# (reason=precondition_unmet, precondition=tagged_testfiles). Distinct from S5
# malformed (no TESTFILES section at all → fail closed). Teeth check: a block
# WITH SPEC ids but empty TESTFILES still falls through to a Level-1 fail
# (verified by the existing coverage tests), NOT a no-op.
REPO9="$(_build_repo gate-placeholder '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
printf '```acceptance\nTESTFILES:\n```\n' > "$REPO9/design.md"
set +e; _run_gate "$REPO9"; set -e
assert_eq "S9: placeholder block → rc=0" "0" "$RC"
assert_eq "S9: verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"
assert_eq "S9: reason=precondition_unmet" "precondition_unmet" "$(jq -r .reason <<<"$RESULT")"
assert_eq "S9: precondition=tagged_testfiles" "tagged_testfiles" "$(jq -r .precondition <<<"$RESULT")"

# ── S10: BOTH untagged AND tautological SPECs surface in ONE pass (#1220) ─────
# The whack-a-mole fix: a design with an untagged SPEC AND a tautological
# [change] SPEC must report BOTH classes in a single gate run (not one class per
# cycle iteration). SPEC-1 is tagged but tautological; SPEC-2 has no tagged
# assertion. Both must appear in failures[], both events must fire, and the
# untagged SPEC-2 must NOT be double-reported as no_testfile.
REPO10="$(_build_repo gate-both '#!/usr/bin/env bash
# [SPEC-1] change: always true (tautological)
exit 0')"
cat > "$REPO10/design.md" <<'EOF'
```acceptance
SPEC-1[change]: new behavior introduced
SPEC-2: second requirement (no tagged assertion)
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO10"; set -e
FAILURES="$(jq -rc .failures <<<"$RESULT")"
assert_eq "S10: both violations → rc=1" "1" "$RC"
assert_eq "S10: verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"
assert_eq "S10: disposition=recoverable (#1585 — tautology+untagged both build-fixable → cycle re-iterates)" "recoverable" "$(jq -r .disposition <<<"$RESULT")"
assert_contains "S10: untagged_spec:SPEC-2 present in one pass" "$FAILURES" "untagged_spec:SPEC-2"
assert_contains "S10: tautology:SPEC-1 present in the SAME pass" "$FAILURES" "tautology:SPEC-1"
assert_event_emitted "S10: untagged_spec event" "$EVENTS" "acceptance.gate.untagged_spec"
assert_event_emitted "S10: tautology event" "$EVENTS" "acceptance.gate.tautology"
if grep -qF "no_testfile:SPEC-2" <<<"$FAILURES"; then
    assert_fail "S10: SPEC-2 double-reported (untagged AND no_testfile)" "$FAILURES"
else
    assert_pass "S10: untagged SPEC-2 reported once (not also no_testfile)"
fi

# ── S11: terminal reason NAMES the SPEC ids + violation class (#1220) ─────────
# Replaces the opaque member_terminal_failure: the result artifact carries a
# human-readable `reason` naming the offending SPEC ids and their class.
REASON="$(jq -r '.reason // ""' <<<"$RESULT")"
assert_contains "S11: reason names SPEC-1" "$REASON" "SPEC-1"
assert_contains "S11: reason names SPEC-2" "$REASON" "SPEC-2"
assert_contains_regex "S11: reason names the tautology class" "$REASON" "[Tt]autolog"

# ── S12 (#1583 + #1585): a tautology is BUILD-FIXABLE → NO route_target, RECOVERABLE ─
# Since #1477 removed design's stub-writer, BUILD authors assertion bodies, so a
# tautological [change] SPEC is fixed by build re-authoring it (the mechanical
# negative-control re-verifies). The gate sets NO route_target (#1583) AND classifies
# it as disposition=recoverable (#1585) so the build_test_cycle RE-ITERATES and feeds
# the tautology to build — instead of halting terminally at iter 1. verdict / rc
# unchanged (still a fail until build fixes it).
# RESULT here still holds REPO10's run (tautology SPEC-1 + untagged SPEC-2).
assert_eq "S12: tautology → route_target absent (build-fixable, #1583)" "" "$(jq -r '.route_target // ""' <<<"$RESULT")"
assert_eq "S12: tautology verdict unchanged (still fail)" "fail" "$(jq -r .verdict <<<"$RESULT")"
assert_eq "S12: tautology disposition=recoverable (#1585 — cycle re-iterates, not terminal)" "recoverable" "$(jq -r .disposition <<<"$RESULT")"

# ── S13 (#1219): a build-fixable failure does NOT set route_target ─────────────
# As of #1583 NO failure class is design-rooted (tautology became build-fixable
# too — see S12). An untagged_spec (recoverable, build-fixable) stays in the build
# cycle — no route_target, so the gate-aggregator keeps verdict=fail and the
# route_back never fires. REPO3 = untagged-only.
set +e; _run_gate "$REPO3"; set -e
assert_eq "S13: untagged-only (build-fixable) → route_target absent" "" "$(jq -r '.route_target // ""' <<<"$RESULT")"

# ── S14 (#1219): a not_passing_at_head failure does NOT set route_target ───────
# not_passing_at_head is build-fixable/terminal (fix the impl) — out of #1219
# scope; it must NOT route to design. REPO with a [change] SPEC whose tagged test
# fails at BOTH baseline and HEAD (a real not_passing_at_head, not a tautology).
REPO14="$(_build_repo gate-nohead '#!/usr/bin/env bash
# [SPEC-1] change: never passes anywhere
exit 1')"
cat > "$REPO14/design.md" <<'EOF'
```acceptance
SPEC-1[change]: new behavior introduced
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO14"; set -e
assert_eq "S14: not_passing_at_head → route_target absent (build-fixable)" "" "$(jq -r '.route_target // ""' <<<"$RESULT")"

  # exits with $FAIL

# ── S10b (#1649): a design's PROMISE is still enforced — just later ───────────
# #1649 removed the design-gate's on-disk existence check, because design runs
# before anything is built and rejecting a proposed new test file forced every
# design onto a pre-existing crowded file. That removal is only safe because the
# promise is enforced HERE, after build has had its chance to create the file.
# This pins that guarantee: a [change] SPEC whose declared testfile was never
# created must fail as no_testfile. Without it, "declared but never written"
# would sail through both gates unnoticed.
REPO10B="$(_build_repo gate-unfulfilled '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
cat > "$REPO10B/design.md" <<'EOF'
```acceptance
SPEC-1[change]: promised in design, never created by build
TESTFILES:
SPEC-1: tests/never-written-test.sh
```
EOF
set +e; _run_gate "$REPO10B"; set -e
FAILURES_10B="$(jq -rc .failures <<<"$RESULT")"
assert_eq "S10b: an unfulfilled testfile promise → verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"
# Reported by the ADR-036 tagging check, which fires ahead of negctl's
# no_testfile arm: with the file absent there is no [SPEC-1] assertion to find.
# Either class is a correct refusal; this pins the one that actually happens.
assert_contains "S10b: names the offending SPEC" "$FAILURES_10B" "SPEC-1"
# recoverable, not terminal — the build cycle gets to go and write the file,
# which is the right disposition for "promised it, did not create it".
assert_eq "S10b: unfulfilled promise is recoverable (cycle re-iterates)" \
    "recoverable" "$(jq -r .disposition <<<"$RESULT")"

# ── S15 (#1686): WIRING target not in this commit's diff → wiring_not_on_path ───
# A WIRING file declared in design.md that this commit never touched cannot flip
# when reverted. The gate must emit verdict=fail, disposition=recoverable and
# route_target=design, so the aggregator fires route_design and route_back rewinds
# to design_verify_cycle — the first live activation of the dormant carrier.
#
# NOT the #1664 shape: PR #1680 DID change .github/workflows/test.yml (+9/-2), so
# that target was in the diff and still lands on inert_wiring. See #1711.
REPO15="$(setup_git_temp_repo gate-nopath)"
(
    cd "$REPO15"
    "$GIT" checkout -q -b feature
    mkdir -p scripts tests
    printf '#!/usr/bin/env bash\nmy_script() { return 0; }\n' > scripts/helper.sh
    printf '#!/usr/bin/env bash\n# [SPEC-1] change: helper is present\n[[ -f "$(dirname "$0")/../scripts/helper.sh" ]] || exit 1\nsource "$(dirname "$0")/../scripts/helper.sh"; my_script\n' \
        > tests/helper-test.sh
    chmod +x scripts/helper.sh tests/helper-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: add helper (workflow file never touched)"
) >/dev/null 2>&1
cat > "$REPO15/design.md" <<'EOF'
```acceptance
SPEC-1[change]: helper is present
WIRING:
.github/workflows/test.yml
TESTFILES:
tests/helper-test.sh
```
EOF
set +e; _run_gate "$REPO15"; set -e
RC15="$RC"; RESULT15="$RESULT"; EVENTS15="$EVENTS"

assert_eq "[SPEC-3] S15: wiring_not_on_path → rc=1" "1" "$RC15"
assert_eq "[SPEC-3] S15: verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT15")"
assert_eq "[SPEC-3] S15: disposition=recoverable (design-rewind, not terminal halt)" \
    "recoverable" "$(jq -r .disposition <<<"$RESULT15")"
assert_eq "[SPEC-3] S15: route_target=design (first live activation of dormant carrier)" \
    "design" "$(jq -r '.route_target // ""' <<<"$RESULT15")"
assert_contains "[SPEC-3] S15: failures[] contains wiring_not_on_path" \
    "$(jq -rc .failures <<<"$RESULT15")" "wiring_not_on_path"
assert_event_emitted "[SPEC-3] S15: wiring_not_on_path event emitted" \
    "$EVENTS15" "acceptance.gate.wiring_not_on_path"

# ── S16 (#1684): NEGCTL summary lines are enriched with desc and label ─────────
# [SPEC-3] acceptance_gate_run enriches each NEGCTL PASS line with the SPEC
# description from design.md and the [SPEC-n]-tagged assertion label from
# the declared testfile.
# Also verifies <none found> appears when no [SPEC-n] tag exists in the testfile.
REPO16="$(_build_repo gate-enrich-pass '#!/usr/bin/env bash
# [SPEC-1] feature works as expected
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
source "$impl"; my_feature')"
cat > "$REPO16/design.md" <<'EOF'
```acceptance
SPEC-1: feature works as expected
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate_with_summary "$REPO16"; set -e
assert_eq "[SPEC-3] S16: load-bearing enriched → rc=0" "0" "$RC"
assert_eq "[SPEC-3] S16: verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"
assert_contains "[SPEC-3] S16: summary contains SPEC desc enrichment" \
    "$SUMMARY" "design : feature works as expected"
assert_contains "[SPEC-3] S16: summary contains assertion label enrichment" \
    "$SUMMARY" "asserts: # [SPEC-1] feature works as expected"
# The verdict token must remain the leading content of its own line — parsers
# (and acceptance-gate-quiet-test.sh's one-NEGCTL-line-per-SPEC count) key on it.
assert_eq "[SPEC-3] S16: verdict token still leads its line" \
    "1" "$(printf '%s\n' "$SUMMARY" | grep -c '^ *NEGCTL PASS SPEC-1$')"
# #1684: the pairing must outlive the run. The fd-2 emit is ephemeral and
# io-gated; without the artifact no lens and no post-hoc audit can ever see it.
assert_eq "[SPEC-3] S16: summary persisted to an artifact" \
    "1" "$([[ -f "$REPO16/.zbuild-state/artifacts/acceptance-summary.txt" ]] && echo 1 || echo 0)"
assert_contains "[SPEC-3] S16: persisted artifact carries the design/asserts pair" \
    "$(cat "$REPO16/.zbuild-state/artifacts/acceptance-summary.txt" 2>/dev/null)" \
    "asserts: # [SPEC-1] feature works as expected"

# ── S16c (#1684): a SPEC with no description text renders an explicit marker ───
# Empty desc previously rendered as a blank gap, indistinguishable from a
# rendering bug. <none found> covered the label but never the description.
REPO16C="$(_build_repo gate-enrich-nodesc '#!/usr/bin/env bash
# [SPEC-1] x
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
source "$impl"; my_feature')"
cat > "$REPO16C/design.md" <<'EOF'
```acceptance
SPEC-1:
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate_with_summary "$REPO16C"; set -e
assert_contains "[SPEC-3] S16c: empty SPEC text renders <no description>" \
    "$SUMMARY" "design : <no description>"

# Verify <none found> when the testfile has no [SPEC-n] tag.
# Use a guard SPEC so Level-1 coverage check is exempt (guard SPECs skip negctl).
REPO16B="$(_build_repo gate-enrich-nolabel '#!/usr/bin/env bash
# no spec tag in this file
exit 0')"
cat > "$REPO16B/design.md" <<'EOF'
```acceptance
SPEC-1[guard]: some invariant
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate_with_summary "$REPO16B"; set -e
assert_eq "[SPEC-3] S16b: guard SPEC with no tag → rc=0 (skip)" "0" "$RC"
assert_contains "[SPEC-3] S16b: summary shows <none found> when no assertion tag" \
    "$SUMMARY" "<none found>"

# ── S16d (#1684): the FAIL line is enriched too, and still classified as FAIL ──
# The enrichment branch is shared by PASS/FAIL/SKIP, but only PASS and SKIP were
# driven end-to-end. A FAIL line is the one where enrichment could do real damage:
# `case "$line"` downstream classifies the failure, and it must keep matching on
# the ORIGINAL line, not the enriched one, or a tautology stops being recorded.
REPO16D="$(_build_repo gate-enrich-fail '#!/usr/bin/env bash
# [SPEC-1] always true
exit 0')"
cat > "$REPO16D/design.md" <<'EOF'
```acceptance
SPEC-1[change]: this assertion is tautological and must be caught
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate_with_summary "$REPO16D"; set -e
assert_eq "[SPEC-3] S16d: tautological SPEC → rc=1" "1" "$RC"
assert_eq "[SPEC-3] S16d: verdict=fail (enrichment did not break classification)" \
    "fail" "$(jq -r .verdict <<<"$RESULT")"
assert_event_emitted "[SPEC-3] S16d: tautology still recorded" \
    "$EVENTS" "acceptance.gate.tautology"
assert_eq "[SPEC-3] S16d: FAIL verdict token still leads its own line" \
    "1" "$(printf '%s\n' "$SUMMARY" | grep -c '^ *NEGCTL FAIL SPEC-1 tautology$')"
assert_contains "[SPEC-3] S16d: FAIL line carries the design text" \
    "$SUMMARY" "design : this assertion is tautological and must be caught"
assert_contains "[SPEC-3] S16d: FAIL line carries the asserted label" \
    "$SUMMARY" "asserts: # [SPEC-1] always true"

cleanup_test_env
print_test_results
