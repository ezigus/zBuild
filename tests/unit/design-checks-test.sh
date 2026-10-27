#!/usr/bin/env bash
# Tests: design's scripted checks of its own design.md (plugins/agent/design/
# lib/checks.sh; #2369 moved them out of the design-gate stage, ADR-046, #1218).
# No model, nothing executed; pure reads of design.md and the files it names.
# Runs the structural checks (C1..C5, C7), reports ALL violations in ONE pass.
# G8 (ADR-069 §10): every test file is in one of the repo's test folders.
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

# repo_root for the checks = a temp tree where declared TESTFILES/WIRING live.
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

# A well-formed, clean design (scope non-empty; every SPEC classified; [change]
# SPEC has an existing tagged TESTFILE; WIRING present + path exists; Level-1
# tags present). Baseline for the pass case.
printf 'assert "[SPEC-1] ok" 1 1\n'  > "$ROOT/tests/a-test.sh"
: > "$ROOT/scripts/wire.sh"

_clean_md='# Design

## Decision
Do the thing.

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: the thing works
TESTFILES:
tests/a-test.sh
WIRING: scripts/wire.sh
```
'

# ─── SPEC-1 (C6 removed): an UNTAGGED TESTFILE no longer fails the gate ───────
# C6 tag-presence check is deleted (ADR-046 demotion, issue #1477). A [change]
# SPEC whose existing TESTFILE carries no [SPEC-1] tag now passes C1..C5.
printf 'assert "unrelated" 1 1\n' > "$ROOT/tests/untagged-test.sh"
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: the thing works
TESTFILES:
tests/untagged-test.sh
WIRING: scripts/wire.sh
```
'
assert_eq "[SPEC-1] untagged TESTFILE → verdict=pass (C6 removed)" "pass" "$VERDICT"
assert_eq "[SPEC-1] untagged TESTFILE → zero violations" \
    "0" "$(jq -r '.data.violations|length' "$RESULT_JSON")"

# ─── SPEC-2 (C3 status): a requirement with no status → verdict=fail ─────────
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1: no status here
TESTFILES:
tests/a-test.sh
WIRING: scripts/wire.sh
```
'
assert_eq "[SPEC-2] unclassified SPEC → verdict=fail" "fail" "$VERDICT"
assert_contains "[SPEC-2] violation names NO_STATUS SPEC-1" \
    "$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")" "NO_STATUS SPEC-1"

# ─── SPEC-3 (C5 wiring): a MISSING-WIRING design → verdict=fail ───────────────
# WIRING section entirely absent from the acceptance block.
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: the thing works
TESTFILES:
tests/a-test.sh
```
'
assert_eq "[SPEC-3] missing-WIRING design → verdict=fail" "fail" "$VERDICT"
assert_contains "[SPEC-3] violation names WIRING_MISSING" \
    "$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")" "WIRING_MISSING"

# ─── SPEC-4 (C1 scope): an INCOMPLETE-SCOPE design → verdict=fail ─────────────
# scope fence present but empty (no entries).
_run_gate_with_md '# Design

```scope
```

```acceptance
SPEC-1[change]: the thing works
TESTFILES:
tests/a-test.sh
WIRING: scripts/wire.sh
```
'
assert_eq "[SPEC-4] incomplete-scope design → verdict=fail" "fail" "$VERDICT"
assert_contains "[SPEC-4] violation names SCOPE_MISSING" \
    "$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")" "SCOPE_MISSING"

# ─── SPEC-5 (#1649): a [change] SPEC may declare a testfile that does not ────
# exist YET — design runs before anything is built, so proposing a new dedicated
# test file must NOT be a violation. The promise is verified downstream, where it
# becomes answerable: acceptance-negctl fails `no_testfile` if the file is still
# absent at gate time. Requiring it here forced every design to abandon its own
# proposal and attach to a pre-existing file (#1624, #1636, #1532).
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: the thing works
TESTFILES:
tests/does-not-exist-test.sh
WIRING: scripts/wire.sh
```
'
assert_eq "[SPEC-5] a not-yet-created testfile is NOT a design-time violation" "pass" "$VERDICT"
assert_eq "[SPEC-5] declaring a future testfile yields zero violations" \
    "0" "$(jq -r '.data.violations|length' "$RESULT_JSON")"

# ─── SPEC-6 (happy path): a CLEAN design → verdict=pass, proceeds to build ────
_run_gate_with_md "$_clean_md"
assert_eq "[SPEC-6] clean design → verdict=pass" "pass" "$VERDICT"
assert_eq "[SPEC-6] clean design → zero violations" \
    "0" "$(jq -r '.data.violations|length' "$RESULT_JSON")"

# ─── SPEC-7 (report-all): MANY violations reported in ONE pass ───────────────
# scope empty (C1) + a [change] SPEC that declares NO testfile at all (C4) +
# an unclassified SPEC (C3) + no WIRING (C5) all at once → all four classes
# named in a single run (no whack-a-mole).
# #1649: the C4 arm is now "declared nothing", not "declared something absent" —
# a not-yet-created path is legitimate and no longer a violation.
_run_gate_with_md '# Design

```scope
```

```acceptance
SPEC-1[change]: has a per-SPEC binding
SPEC-2: unclassified
SPEC-3[change]: declares no testfile of its own
TESTFILES:
SPEC-1: tests/does-not-exist-test.sh
```
'
_all="$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")"
assert_eq "[SPEC-7] multi-violation design → verdict=fail" "fail" "$VERDICT"
assert_contains "[SPEC-7] reports SCOPE_MISSING in one pass"    "$_all" "SCOPE_MISSING"
assert_contains "[SPEC-7] reports NO_STATUS in one pass"        "$_all" "NO_STATUS"
assert_contains "[SPEC-7] reports WIRING_MISSING in one pass"   "$_all" "WIRING_MISSING"
assert_contains "[SPEC-7] reports MISSING_TESTFILE_FOR_SPEC in one pass" "$_all" "MISSING_TESTFILE_FOR_SPEC"

# ─── SPEC-8: _design_checks ALWAYS returns rc=0 ────────
# Even on a failing verdict the plugin returns 0 — the verdict lives in the
# artifact (shape-floor / gate-aggregator idiom); the cycle reads its outcome (#2366).
assert_eq "[SPEC-8] _design_checks returns rc=0 on a FAIL verdict" "0" "$GATE_RC"
_run_gate_with_md "$_clean_md"
assert_eq "[SPEC-8] _design_checks returns rc=0 on a PASS verdict" "0" "$GATE_RC"

# ─── SPEC-9 / SPEC-4 (feedback): feedback markdown written on every verdict ───
# ADR-055 §9: written on every terminal verdict (pass and fail); absence is never
# legitimate. Required:true in the manifest enforces this at the engine level.
_run_gate_with_md "$_clean_md"
assert_eq "[SPEC-4][SPEC-9] feedback file written on a passing verdict" "present" \
    "$([[ -f "$FEEDBACK_PATH" ]] && echo present || echo absent)"
_run_gate_with_md '# Design

```scope
```

```acceptance
SPEC-1: broken
TESTFILES:
tests/a-test.sh
```
'
assert_eq "[SPEC-9] feedback file written on a failing verdict" "present" \
    "$([[ -f "$FEEDBACK_PATH" ]] && echo present || echo absent)"

# ─── G1–G6: requirement status (#2304, ADR-069 §1–§3) ───────────────────────
# Each requirement carries one status: [code], [no-code] or [done]. A [done]
# one names evidence that exists in the repository. Only [code] (and the old
# [change]) needs a test file. Nothing here runs a test (C6 is gone).
printf 'line one\nline two\nline three\n' > "$ROOT/scripts/three.sh"
# _g_md <spec line>... — a clean design around the given requirement lines.
_g_md() {
    printf '# Design\n\n```scope\nscripts/wire.sh\n```\n\n```acceptance\n'
    printf '%s\n' "$@"
    printf 'WIRING: scripts/wire.sh\nTESTFILES:\nSPEC-1: tests/a-test.sh\n```\n'
}
_viol() { jq -r '.data.violations|join(" ")' "$RESULT_JSON"; }

_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2: no status here')"
assert_eq "[G1] a requirement with no status → verdict=fail" "fail" "$VERDICT"
assert_contains "[G1] the violation names it" "$(_viol)" "NO_STATUS SPEC-2"
assert_contains "[G1] the feedback says what the three statuses are" "$(cat "$FEEDBACK_PATH")" \
    "SPEC-2 has no status — tag it [code]"

_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2[guard]: an old guard')"
assert_eq "[G2] an old [guard] tag → verdict=fail" "fail" "$VERDICT"
assert_contains "[G2] the violation names it" "$(_viol)" "UNKNOWN_STATUS SPEC-2"
assert_contains "[G2] the feedback tells design what to use instead" "$(cat "$FEEDBACK_PATH")" \
    "SPEC-2 carries the old guard tag, which is no longer a status"
# #2304 (ADR-069 §8): the feedback is read by design; the literal tag would be
# offered back to it, so the sentence names the tag without writing it.
assert_eq "[G2] the feedback does not write the retired tag itself" "0" \
    "$(grep -cF '[guard]' "$FEEDBACK_PATH" || true)"
assert_eq "[G2] ...nor does the finding design answers" "0" \
    "$(jq -r '.data.findings[].text' "$RESULT_JSON" | grep -cF '[guard]' || true)"
_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2[maybe]: unknown')"
assert_contains "[G2] an unknown tag is rejected the same way" "$(_viol)" "UNKNOWN_STATUS SPEC-2"
_run_gate_with_md "$(_g_md 'SPEC-1[change]: x' 'SPEC-2[no-code]: docs')"
assert_eq "[G2] the old [change] still reads as code, and [no-code] is a status" "pass" "$VERDICT"

_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2[done]: already there')"
assert_eq "[G3] a [done] requirement with no evidence → verdict=fail" "fail" "$VERDICT"
assert_contains "[G3] the violation names it" "$(_viol)" "DONE_NO_EVIDENCE SPEC-2"
assert_contains "[G3] the feedback says how to name evidence" "$(cat "$FEEDBACK_PATH")" \
    "SPEC-2 is marked [done] but names no evidence"

_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2[done]: already there evidence: scripts/three.sh:3 tests/a-test.sh')"
assert_eq "[G4] evidence that exists (path:N within the file, and a file) → pass" "pass" "$VERDICT"
for _ev in /etc/hosts ../outside.sh scripts/missing.sh scripts/three.sh:4 scripts/three.sh:0 scripts/three.sh:x; do
    _run_gate_with_md "$(_g_md 'SPEC-1[code]: x' "SPEC-2[done]: already there evidence: $_ev")"
    assert_contains "[G4] evidence '$_ev' is rejected" "$(_viol)" "DONE_BAD_EVIDENCE SPEC-2 $_ev"
done
assert_contains "[G4] the feedback says what is wrong with the evidence" "$(cat "$FEEDBACK_PATH")" \
    "the evidence scripts/three.sh:x for SPEC-2"

_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2[no-code]: docs' 'SPEC-3[done]: there evidence: scripts/three.sh')"
assert_eq "[G5] [no-code] and [done] need no test file of their own" "pass" "$VERDICT"
_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2[code]: y')"
assert_contains "[G5] a [code] requirement with no test file is still caught" "$(_viol)" \
    "MISSING_TESTFILE_FOR_SPEC SPEC-2"
_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2[change]: y')"
assert_contains "[G5] ...and so is an old [change] one" "$(_viol)" "MISSING_TESTFILE_FOR_SPEC SPEC-2"

_run_gate_with_md "$(_g_md 'SPEC-1[code]: x' 'SPEC-2[guard]: old')"
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
_run_gate_with_md "$(_g_md 'SPEC-1[code]: plugin.sh contains `_foo`')"
assert_eq "[G7] 'plugin.sh contains _foo' as [code] → verdict=fail" "fail" "$VERDICT"
assert_contains "[G7] the violation names it" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR SPEC-1"
assert_contains "[G7] the feedback says it in plain words" "$(cat "$FEEDBACK_PATH")" \
    "SPEC-1 describes what a file contains, not what the code does — describe the behaviour someone could observe (an input and what happens), or, if the code already does it, mark it [done] with evidence"
assert_eq "[G7] the feedback does not write the code" "0" "$(grep -cF CONTENTS_NOT_BEHAVIOUR "$FEEDBACK_PATH" || true)"
for _t in 'the manifest declares key `x`' 'scripts/x.sh defines function bar' \
          'the file tests/x-test.sh exists' 'the helper is present in scripts/lib/x.sh' \
          'the manifest has a `config.router` key' 'the test greps plugin.sh for `_foo`' \
          '`plugin.sh` contains `fails`'; do
    _run_gate_with_md "$(_g_md "SPEC-1[code]: $_t")"
    assert_contains "[G7] '$_t' as [code] is rejected" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR SPEC-1"
done
_run_gate_with_md "$(_g_md 'SPEC-1[change]: plugin.sh contains `_foo`')"
assert_contains "[G7] ...and so is the old [change] tag" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR SPEC-1"
for _t in 'an empty input returns rc 1' 'build writes a summary when the diff is empty' \
          'scripts/x.sh prints an error and exits 1 when the file does not exist' \
          'the design prompt contains the evidence syntax' \
          'a manifest that declares no key is rejected by the loader' \
          'design-gate fails a design whose scope block is empty'; do
    _run_gate_with_md "$(_g_md "SPEC-1[code]: $_t")"
    assert_eq "[G7] guard: '$_t' passes" "pass" "$VERDICT"
done
_run_gate_with_md "$(_g_md 'SPEC-1[code]: an empty input returns rc 1' 'SPEC-2[done]: scripts/three.sh contains line two evidence: scripts/three.sh:2')"
assert_eq "[G7] guard: a [done] requirement may describe what a file contains" "pass" "$VERDICT"
_run_gate_with_md "$(_g_md 'SPEC-1[code]: an empty input returns rc 1' 'SPEC-2[no-code]: docs/x.md contains the new section')"
assert_eq "[G7] guard: a [no-code] requirement may describe what a file contains" "pass" "$VERDICT"
# One bad [code] requirement with no test file draws both violations in the
# same pass (review #2319): the gate reports everything at once (SPEC-7).
_run_gate_with_md "$(_g_md 'SPEC-1[code]: an empty input returns rc 1' 'SPEC-2[code]: plugin.sh contains `_bar`')"
assert_contains "[G7] a contents-only requirement with no test file is named for the missing test file" "$(_viol)" "MISSING_TESTFILE_FOR_SPEC SPEC-2"
assert_contains "[G7] ...and, in the same pass, for describing contents" "$(_viol)" "CONTENTS_NOT_BEHAVIOUR SPEC-2"

# ─── SPEC-11 (#1227 fix 1): C1 fence tolerates trailing whitespace ───────────
# The design stage asserts the scope block with `grep -q '^```scope'`, which
# accepts a fence line carrying trailing whitespace. C1's fence check must
# mirror that tolerance so a trailing-space fence does NOT falsely trip
# SCOPE_MISSING. Build a clean design whose scope fence has a trailing space.
_ws_md="$(printf '# Design\n\n```scope \nscripts/wire.sh\n```\n\n```acceptance\nSPEC-1[change]: the thing works\nTESTFILES:\ntests/a-test.sh\nWIRING: scripts/wire.sh\n```\n')"
_run_gate_with_md "$_ws_md"
_ws_viol="$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")"
assert_eq "[SPEC-11] trailing-ws scope fence → no false SCOPE_MISSING" "absent" \
    "$([[ "$_ws_viol" == *SCOPE_MISSING* ]] && echo present || echo absent)"
assert_eq "[SPEC-11] trailing-ws scope fence → verdict=pass" "pass" "$VERDICT"

# ─── SPEC-12 (C4 per-SPEC binding upgrade): per-SPEC binding present → pass ───
# Each [change] SPEC declares its own TESTFILE binding; both files exist.
printf 'assert "[SPEC-1] b" 1 1\n' > "$ROOT/tests/b-test.sh"
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: first new behavior
SPEC-2[change]: second new behavior
WIRING: scripts/wire.sh
TESTFILES:
SPEC-1: tests/a-test.sh
SPEC-2: tests/b-test.sh
```
'
assert_eq "[SPEC-4] SPEC-12: per-SPEC binding, all files exist → verdict=pass" "pass" "$VERDICT"
assert_eq "[SPEC-4] SPEC-12: per-SPEC binding → zero violations" \
    "0" "$(jq -r '.data.violations|length' "$RESULT_JSON")"

# ─── SPEC-13 (C4 per-SPEC binding upgrade): per-SPEC path missing → fail ─────
# SPEC-1 has a per-SPEC binding but the declared file does not exist on disk.
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: new behavior
WIRING: scripts/wire.sh
TESTFILES:
SPEC-1: tests/does-not-exist-per-spec-test.sh
```
'
assert_eq "[SPEC-4] SPEC-13: per-SPEC binding to a future file → verdict=pass (#1649)" "pass" "$VERDICT"
assert_eq "[SPEC-4] SPEC-13: per-SPEC binding to a future file → zero violations" \
    "0" "$(jq -r '.data.violations|length' "$RESULT_JSON")"

# ─── SPEC-14 (C4 per-SPEC binding upgrade): a [change] SPEC with NO binding ───
# and no global bare-path fallback must be caught. This is the case the OLD
# pooled C4 structurally could NOT see: it counted the global pool (1 file,
# present) and passed, letting SPEC-2 satisfy C4 via SPEC-1's file. Only the
# per-SPEC loop attributes the gap to SPEC-2. SPEC-13 above does not
# discriminate (old C4 emits MISSING_TESTFILE for a missing path too), so this
# is the assertion that makes the design-gate C4 wiring load-bearing.
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: first new behavior
SPEC-2[change]: second new behavior, deliberately given no testfile of its own
WIRING: scripts/wire.sh
TESTFILES:
SPEC-1: tests/a-test.sh
```
'
assert_eq "[SPEC-4] SPEC-14: [change] SPEC with no binding of its own → verdict=fail" \
    "fail" "$VERDICT"
assert_contains "[SPEC-4] SPEC-14: violation attributes the gap to SPEC-2" \
    "$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")" "MISSING_TESTFILE_FOR_SPEC SPEC-2"

# ─── SPEC-15 (#1649): dropping the existence check opens no traversal hole ───
# acceptance-block.sh already refuses absolute and ".."-containing paths while
# parsing, so such a declaration never reaches C4 as a path. A duplicate guard in
# the gate would be unreachable; this pins the real, end-to-end behaviour instead.
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: the thing works
WIRING: scripts/wire.sh
TESTFILES:
SPEC-1: ../outside-the-repo-test.sh
```
'
assert_eq "[SPEC-15] a traversing testfile path → verdict=fail" "fail" "$VERDICT"
# The parser drops it while reading the block, so it reaches C4 as NO path at
# all — hence MISSING_TESTFILE_FOR_SPEC rather than a dedicated path violation.
# Pinning it here proves dropping the existence check opened no traversal hole.
assert_contains "[SPEC-15] a dropped traversing path surfaces as MISSING_TESTFILE_FOR_SPEC" \
    "$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")" "MISSING_TESTFILE_FOR_SPEC"

_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1[change]: the thing works
WIRING: scripts/wire.sh
TESTFILES:
SPEC-1: /etc/passwd-test.sh
```
'
assert_eq "[SPEC-15] an absolute testfile path → verdict=fail" "fail" "$VERDICT"
assert_contains "[SPEC-15] a dropped absolute path also surfaces as MISSING_TESTFILE_FOR_SPEC" \
    "$(jq -r '.data.violations|join(" ")' "$RESULT_JSON")" "MISSING_TESTFILE_FOR_SPEC"

# ─── G8 (ADR-069 §10): a test file is in one of the repo's test folders ─────
# #1801 run 40390919951 named two ADR documents as a requirement's tests; the
# test stage ran them with bash, and their markdown quote lines ("> word")
# created files in the worktree.
_g8_md() {   # _g8_md <SPEC-2 test file>
    printf '# Design\n\n```scope\nscripts/wire.sh\n```\n\n```acceptance\n'
    printf 'SPEC-1[code]: x\nSPEC-2[no-code]: the ADR says so\n'
    printf 'WIRING: scripts/wire.sh\nTESTFILES:\nSPEC-1: tests/a-test.sh\nSPEC-2: %s\n```\n' "$1"
}
_run_gate_with_md "$(_g8_md docs/adr/ADR-011-pluggable-backends.md)"
assert_eq "[G8] a document named as a test → verdict=fail" "fail" "$VERDICT"
assert_contains "[G8] the violation names the file" "$(_viol)" "TESTFILE_NOT_A_TEST docs/adr/ADR-011-pluggable-backends.md"
assert_contains "[G8] the feedback says it in plain words" "$(cat "$FEEDBACK_PATH")" \
    "docs/adr/ADR-011-pluggable-backends.md is named as a test, but it is not in a test folder"
assert_contains "[G8] ...naming the test folders" "$(cat "$FEEDBACK_PATH")" "tests/*"
_run_gate_with_md "$(_g8_md tests/unit/b-test.sh)"
assert_eq "[G8] a file under tests/ passes" "pass" "$VERDICT"
_run_gate_with_md "$(_g8_md plugins/tool/x/tests/x-test.sh)"
assert_eq "[G8] a file in a plugin's own tests folder passes" "pass" "$VERDICT"
_run_gate_with_md "$(_g8_md scripts/lib/thing.sh)"
assert_contains "[G8] a source file is not a test either" "$(_viol)" "TESTFILE_NOT_A_TEST scripts/lib/thing.sh"
# The folders are the repository's data: its own list replaces the default.
mkdir -p "$ROOT/.zbuild"; printf '# this repo keeps its tests in spec/\nspec/*\n' > "$ROOT/.zbuild/test-paths.txt"
_run_gate_with_md "$(_g8_md spec/thing_spec.rb)"
assert_contains "[G8] a repo's own list decides: tests/ is not one of its folders" "$(_viol)" "TESTFILE_NOT_A_TEST tests/a-test.sh"
assert_eq "[G8] ...and spec/ is" "0" "$(grep -c 'TESTFILE_NOT_A_TEST spec/' <<< "$(_viol)" || true)"
rm -f "$ROOT/.zbuild/test-paths.txt"

print_test_results
