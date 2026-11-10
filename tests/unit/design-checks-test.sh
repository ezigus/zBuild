#!/usr/bin/env bash
# Tests: design's scripted checks of its own design.md (plugins/agent/design/
# lib/checks.sh; #2369 moved them out of the design-gate stage, ADR-046, #1218).
# No model, nothing executed; pure reads of design.md and the files it names.
# Runs the structural checks (C2, C3, C5, C7, C9–C11), reports ALL violations in
# ONE pass. #2508 (ADR-069 §11): design names no files — no scope block (C1) and
# no test file per SPEC (C4, C8) are asked for or checked.
# G8 (ADR-069 §10, #2508): a WIRING file in one of the repo's test folders is no
# WIRING file; the repo's own list decides which folders those are.
# C3 is the requirement status (#2304, ADR-069): G1–G6 below; G7 (#2305) reads a
# [code] requirement's words.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design checks its own design.md — the scripted checks (#2369, #1218)"
setup_test_env "design-checks"
_test_cleanup_hook() { cleanup_test_env; }


# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/agent/design/lib/checks.sh
source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"

# repo_root for the checks = a temp tree where the WIRING and evidence files live.
ROOT="$TEST_TEMP_DIR/repo"
mkdir -p "$ROOT/tests" "$ROOT/scripts"
export ZBUILD_REPO_ROOT="$ROOT"

# _run_gate_with_md <design.md content>  → runs _design_checks on it; sets
# $VERDICT, $RESULT_JSON (.data.violations), $FEEDBACK_PATH (the plain sentences
# design is sent back with) and $GATE_RC.
_state_seq=0
_run_gate_with_md() {
    _state_seq=$((_state_seq + 1))
    local art="$TEST_TEMP_DIR/state-$_state_seq/artifacts" v
    mkdir -p "$art"
    printf '%s' "$1" > "$art/design.md"
    set +e
    _design_checks "$art/design.md" "$ROOT" "${REQ_JSON:-}"
    GATE_RC=$?
    set -e
    RESULT_JSON="$art/checks.json"
    FEEDBACK_PATH="$art/checks-feedback.md"
    if [[ ${#_DESIGN_VIOLATIONS[@]} -eq 0 ]]; then
        VERDICT=pass; printf '{"data":{"violations":[]}}' > "$RESULT_JSON"; : > "$FEEDBACK_PATH"
    else
        VERDICT=fail
        printf '%s\n' "${_DESIGN_VIOLATIONS[@]}" | jq -R . | jq -s '{data:{violations:.}}' > "$RESULT_JSON"
        for v in "${_DESIGN_VIOLATIONS[@]}"; do _dck_plain "$v"; printf '\n'; done > "$FEEDBACK_PATH"
    fi
}

# A well-formed, clean design (every SPEC classified; WIRING present + path
# exists; no file list, #2508). Baseline for the pass case.
printf 'assert "[DSWORK-1] ok" 1 1\n'  > "$ROOT/tests/a-test.sh"
: > "$ROOT/scripts/wire.sh"

_clean_md='# Design

## Decision
Do the thing.

```acceptance
DSWORK-1[change]: the thing works
  When: it runs
  Then: it is done
WIRING: scripts/wire.sh
```
'

# ─── SPEC-1 (C6 removed): a SPEC with no tagged test yet passes the gate ──────
# C6 tag-presence check is deleted (ADR-046 demotion, issue #1477): design runs
# before any test exists, so a [change] SPEC no test file holds the tag of yet
# passes. Its test is checked downstream, where it becomes answerable.
printf 'assert "unrelated" 1 1\n' > "$ROOT/tests/untagged-test.sh"
_run_gate_with_md '# Design

```acceptance
DSWORK-1[change]: the thing works
  When: it runs
  Then: it is done
WIRING: scripts/wire.sh
```
'
assert_eq "[DSWORK-1] no tagged test yet → verdict=pass (C6 removed)" "pass" "$VERDICT"
assert_eq "[DSWORK-1] no tagged test yet → zero violations" \
    "0" "$(jq -r '.data.violations|length' "$RESULT_JSON")"

# ─── SPEC-2 (C3 status): a requirement with no status → verdict=fail ─────────
_run_gate_with_md '# Design

```acceptance
DSWORK-1: no status here
WIRING: scripts/wire.sh
```
'
assert_eq "[DSWORK-2] unclassified SPEC → verdict=fail" "fail" "$VERDICT"
assert_contains "[DSWORK-2] violation names NO_STATUS DSWORK-1" \
    "$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")" "NO_STATUS DSWORK-1"

# ─── SPEC-3 (C5 wiring): a MISSING-WIRING design → verdict=fail ───────────────
# WIRING section entirely absent from the acceptance block.
_run_gate_with_md '# Design

```acceptance
DSWORK-1[change]: the thing works
  When: it runs
  Then: it is done
```
'
assert_eq "[DSWORK-3] missing-WIRING design → verdict=fail" "fail" "$VERDICT"
assert_contains "[DSWORK-3] violation names WIRING_MISSING" \
    "$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")" "WIRING_MISSING"

# ─── SPEC-6 (happy path): a CLEAN design → verdict=pass, proceeds to build ────
_run_gate_with_md "$_clean_md"
assert_eq "[DSWORK-6] clean design → verdict=pass" "pass" "$VERDICT"
assert_eq "[DSWORK-6] clean design → zero violations" \
    "0" "$(jq -r '.data.violations|length' "$RESULT_JSON")"

# ─── SPEC-7 (report-all): MANY violations reported in ONE pass ───────────────
# an unclassified SPEC (C3) + no WIRING (C5) + a malformed UNCLEAR line (C12)
# all at once → all three named in a single run (no whack-a-mole).
_run_gate_with_md '# Design

```acceptance
DSWORK-1[change]: a behaviour
  When: it runs
  Then: it is done
DSWORK-2: unclassified
```

UNCLEAR: R-1 is the flag needed?
'
_all="$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")"
assert_eq "[DSWORK-7] multi-violation design → verdict=fail" "fail" "$VERDICT"
assert_contains "[DSWORK-7] reports NO_STATUS in one pass"        "$_all" "NO_STATUS"
assert_contains "[DSWORK-7] reports WIRING_MISSING in one pass"   "$_all" "WIRING_MISSING"
assert_contains "[DSWORK-7] reports UNCLEAR_MALFORMED in one pass" "$_all" "UNCLEAR_MALFORMED"

# ─── SPEC-8: _design_checks ALWAYS returns rc=0 ────────
# Even on a failing verdict the plugin returns 0 — the verdict lives in the
# artifact (shape-floor / gate-aggregator idiom); the cycle reads its outcome (#2366).
assert_eq "[DSWORK-8] _design_checks returns rc=0 on a FAIL verdict" "0" "$GATE_RC"
_run_gate_with_md "$_clean_md"
assert_eq "[DSWORK-8] _design_checks returns rc=0 on a PASS verdict" "0" "$GATE_RC"

# ─── SPEC-9 / SPEC-4 (feedback): feedback markdown written on every verdict ───
# ADR-055 §9: written on every terminal verdict (pass and fail); absence is never
# legitimate. Required:true in the manifest enforces this at the engine level.
_run_gate_with_md "$_clean_md"
assert_eq "[DSWORK-4][DSWORK-9] feedback file written on a passing verdict" "present" \
    "$([[ -f "$FEEDBACK_PATH" ]] && echo present || echo absent)"
_run_gate_with_md '# Design

```acceptance
DSWORK-1: broken
```
'
assert_eq "[DSWORK-9] feedback file written on a failing verdict" "present" \
    "$([[ -f "$FEEDBACK_PATH" ]] && echo present || echo absent)"

# ─── G1–G6: requirement status (#2304, ADR-069 §1–§3) ───────────────────────
# Each requirement carries one status: [code], [no-code] or [done]. A [done]
# one names evidence that exists in the repository. No status names a test
# file (#2508). Nothing here runs a test (C6 is gone).
printf 'line one\nline two\nline three\n' > "$ROOT/scripts/three.sh"
# _g_md <spec line>... — a clean design around the given requirement lines.
_g_md() {
    printf '# Design\n\n```acceptance\n'
    printf '%s\n' "$@"
    printf 'WIRING: scripts/wire.sh\n```\n'
}
_viol() { jq -r '.data.violations|join(" ")' "$RESULT_JSON"; }

_run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' 'DSWORK-2: no status here')"
assert_eq "[G1] a requirement with no status → verdict=fail" "fail" "$VERDICT"
assert_contains "[G1] the violation names it" "$(_viol)" "NO_STATUS DSWORK-2"
assert_contains "[G1] the feedback says what the three statuses are" "$(cat "$FEEDBACK_PATH")" \
    "DSWORK-2 has no status — tag it [code]"

_run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' 'DSWORK-2[guard]: an old guard' '  When: it runs' '  Then: it is done')"
assert_eq "[G2] an old [guard] tag → verdict=fail" "fail" "$VERDICT"
assert_contains "[G2] the violation names it" "$(_viol)" "UNKNOWN_STATUS DSWORK-2"
assert_contains "[G2] the feedback tells design what to use instead" "$(cat "$FEEDBACK_PATH")" \
    "DSWORK-2 carries the old guard tag, which is no longer a status"
# #2304 (ADR-069 §8): the feedback is read by design; the literal tag would be
# offered back to it, so the sentence names the tag without writing it.
assert_eq "[G2] the feedback does not write the retired tag itself" "0" \
    "$(grep -cF '[guard]' "$FEEDBACK_PATH" || true)"
assert_eq "[G2] ...nor does the finding design answers" "0" \
    "$(jq -r '.data.findings[].text' "$RESULT_JSON" | grep -cF '[guard]' || true)"
_run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' 'DSWORK-2[maybe]: unknown')"
assert_contains "[G2] an unknown tag is rejected the same way" "$(_viol)" "UNKNOWN_STATUS DSWORK-2"
_run_gate_with_md "$(_g_md 'DSWORK-1[change]: x' '  When: it runs' '  Then: it is done' 'DSWORK-2[no-code]: docs')"
assert_eq "[G2] the old [change] still reads as code, and [no-code] is a status" "pass" "$VERDICT"

_run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' 'DSWORK-2[done]: already there' '  When: it runs' '  Then: it is done')"
assert_eq "[G3] a [done] requirement with no evidence → verdict=fail" "fail" "$VERDICT"
assert_contains "[G3] the violation names it" "$(_viol)" "DONE_NO_EVIDENCE DSWORK-2"
assert_contains "[G3] the feedback says how to name evidence" "$(cat "$FEEDBACK_PATH")" \
    "DSWORK-2 is marked [done] but names no evidence"

_run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' 'DSWORK-2[done]: already there evidence: scripts/three.sh:"line three" tests/a-test.sh' '  When: it runs' '  Then: it is done')"
assert_eq "[G4] evidence that exists (a file with its text, and a test file) → pass" "pass" "$VERDICT"
for _ev in /etc/hosts ../outside.sh scripts/missing.sh scripts/three.sh:x; do
    _run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' "DSWORK-2[done]: already there evidence: $_ev" "  When: it runs" "  Then: it is done")"
    assert_contains "[G4] evidence '$_ev' is rejected" "$(_viol)" "DONE_BAD_EVIDENCE DSWORK-2 $_ev"
done
assert_contains "[G4] the feedback says what is wrong with the evidence" "$(cat "$FEEDBACK_PATH")" \
    "the evidence scripts/three.sh:x for DSWORK-2"
# #2462 (ADR-069 §2): a line number is never evidence — lines move.
for _ev in scripts/three.sh:3 scripts/three.sh:0; do
    _run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' "DSWORK-2[done]: already there evidence: $_ev" "  When: it runs" "  Then: it is done")"
    assert_contains "[G4] evidence '$_ev' names a line number and is rejected" "$(_viol)" "DONE_LINE_EVIDENCE DSWORK-2 $_ev"
done

_run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' 'DSWORK-2[no-code]: docs' 'DSWORK-3[done]: there evidence: scripts/three.sh:"line one"' '  When: it runs' '  Then: it is done')"
assert_eq "[G5] [no-code] and [done] need no test file of their own" "pass" "$VERDICT"

_run_gate_with_md "$(_g_md 'DSWORK-1[code]: x' '  When: it runs' '  Then: it is done' 'DSWORK-2[guard]: old' '  When: it runs' '  Then: it is done')"
assert_eq "[G6] the result carries no guard pre-check block" "absent" \
    "$(jq -r 'if has("guard_precheck") then "present" else "absent" end' "$RESULT_JSON")"
assert_eq "[G6] the feedback has no guard coverage section" "0" \
    "$(grep -c 'Guard baseline' "$FEEDBACK_PATH" || true)"
assert_eq "[G6] the gate no longer defines a guard pre-check" "absent" \
    "$(declare -F acceptance_negctl_guard_precheck >/dev/null && echo present || echo absent)"

# ─── G7: a [code] requirement describes behaviour, not file contents ────────
# (#2305, ADR-069 §9) "plugin.sh contains `_foo`" fails on the old code and
# passes on the new, so the fail-first rule accepts it while it proves nothing
# about what the code does. The gate reads the requirement's words: a contents
# or existence verb about a file, with no behaviour verb, is rejected.
_run_gate_with_md "$(_g_md 'DSWORK-1[code]: plugin.sh contains `_foo`' '  When: it runs' '  Then: it is done')"
assert_eq "[G7] 'plugin.sh contains _foo' as [code] → verdict=fail" "fail" "$VERDICT"
assert_contains "[G7] the violation names it" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR DSWORK-1"
assert_contains "[G7] the feedback says it in plain words" "$(cat "$FEEDBACK_PATH")" \
    "DSWORK-1 describes what a file contains, not what the code does — no test can prove that; describe the behaviour someone could observe (an input and what happens)"
assert_eq "[G7] the feedback does not write the code" "0" "$(grep -cF CONTENTS_NOT_BEHAVIOUR "$FEEDBACK_PATH" || true)"
for _t in 'the manifest declares key `x`' 'scripts/x.sh defines function bar' \
          'the file tests/x-test.sh exists' 'the helper is present in scripts/lib/x.sh' \
          'the manifest has a `config.router` key' 'the test greps plugin.sh for `_foo`' \
          '`plugin.sh` contains `fails`'; do
    _run_gate_with_md "$(_g_md "DSWORK-1[code]: $_t" "  When: it runs" "  Then: it is done")"
    assert_contains "[G7] '$_t' as [code] is rejected" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR DSWORK-1"
done
_run_gate_with_md "$(_g_md 'DSWORK-1[change]: plugin.sh contains `_foo`' '  When: it runs' '  Then: it is done')"
assert_contains "[G7] ...and so is the old [change] tag" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR DSWORK-1"
for _t in 'an empty input returns rc 1' 'build writes a summary when the diff is empty' \
          'scripts/x.sh prints an error and exits 1 when the file does not exist' \
          'the design prompt contains the evidence syntax' \
          'a manifest that declares no key is rejected by the loader' \
          'design-gate fails a design whose scope block is empty'; do
    _run_gate_with_md "$(_g_md "DSWORK-1[code]: $_t" "  When: it runs" "  Then: it is done")"
    assert_eq "[G7] guard: '$_t' passes" "pass" "$VERDICT"
done
# #2474 (ADR-069 §9 amended): every SPEC, whatever its tag. #1805 run
# 42090130741's design passed BNDY-1, a [no-code] SPEC about what a test file
# contains; no test could prove it, and it ended the run.
_run_gate_with_md "$(_g_md 'DSWORK-1[code]: an empty input returns rc 1' '  When: it runs' '  Then: it is done' 'DSWORK-2[done]: scripts/three.sh contains line two evidence: scripts/three.sh:"line two"' '  When: it runs' '  Then: it is done')"
assert_contains "[G7] a [done] requirement that describes what a file contains is rejected" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR DSWORK-2"
_run_gate_with_md "$(_g_md 'DSWORK-1[code]: an empty input returns rc 1' '  When: it runs' '  Then: it is done' 'DSWORK-2[no-code]: docs/x.md contains the new section')"
assert_contains "[G7] a [no-code] requirement that describes what a file contains is rejected" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR DSWORK-2"
_run_gate_with_md "$(_g_md 'DSWORK-1[code]: an empty input returns rc 1' '  When: it runs' '  Then: it is done' 'DSBNDY-1[no-code]: resume-rehydrate-test.sh contains both a resume-side assertion (DSRHYD-1/RHYD-2) and a fresh-run sub-case with --no-resume, pinning both sides of the ADR-006/ADR-050 §6 boundary in one test file')"
assert_contains "[G7] ...as is #1805's DSBNDY-1, word for word" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR DSBNDY-1"
_run_gate_with_md "$(_g_md 'DSWORK-1[code]: an empty input returns rc 1' '  When: it runs' '  Then: it is done' 'DSWORK-2[no-code]: the README tells a user how to resume a run')"
assert_eq "[G7] guard: a [no-code] requirement about what a reader is told passes" "pass" "$VERDICT"
# A contents-only requirement is named even beside a sound one (review #2319):
# the gate reports everything at once (SPEC-7).
_run_gate_with_md "$(_g_md 'DSWORK-1[code]: an empty input returns rc 1' '  When: it runs' '  Then: it is done' 'DSWORK-2[code]: plugin.sh contains `_bar`' '  When: it runs' '  Then: it is done')"
assert_contains "[G7] a contents-only requirement beside a sound one is named for describing contents" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR DSWORK-2"

# ─── G8 (ADR-069 §10, #2508): a WIRING file in a test folder is refused ─────
# #2429: reachability cannot prove a test load-bearing. With no test-file list
# (#2508) a test is any file in the repository's test folders.
mkdir -p "$ROOT/tests/unit" "$ROOT/spec"
printf 'x\n' > "$ROOT/tests/unit/b-test.sh"; printf 'x\n' > "$ROOT/spec/thing_spec.rb"
_g8_md() {   # _g8_md <WIRING file>
    printf '# Design\n\n```acceptance\nDSWORK-1[code]: x\n  When: it runs\n  Then: it is done\nWIRING: %s\n```\n' "$1"
}
_run_gate_with_md "$(_g8_md tests/unit/b-test.sh)"
assert_eq "[G8] a WIRING file under tests/ → verdict=fail" "fail" "$VERDICT"
assert_contains "[G8] the violation names the file" "$(_viol)" "WIRING_IS_TEST tests/unit/b-test.sh"
assert_contains "[G8] the feedback says it in plain words" "$(cat "$FEEDBACK_PATH")" \
    "the WIRING file tests/unit/b-test.sh is in a test folder"
_run_gate_with_md "$(_g8_md scripts/wire.sh)"
assert_eq "[G8] a source file as WIRING passes" "pass" "$VERDICT"
_run_gate_with_md "$(_g8_md spec/thing_spec.rb)"
assert_eq "[G8] spec/ is not a test folder by default" "pass" "$VERDICT"
# The folders are the repository's data: its own list replaces the default.
mkdir -p "$ROOT/.zbuild"; printf '# this repo keeps its tests in spec/\nspec/*\n' > "$ROOT/.zbuild/test-paths.txt"
_run_gate_with_md "$(_g8_md spec/thing_spec.rb)"
assert_contains "[G8] a repo's own list decides: spec/ is one of its folders" "$(_viol)" "WIRING_IS_TEST spec/thing_spec.rb"
_run_gate_with_md "$(_g8_md tests/unit/b-test.sh)"
assert_eq "[G8] ...and tests/ is not" "pass" "$VERDICT"
rm -f "$ROOT/.zbuild/test-paths.txt"

print_test_results
