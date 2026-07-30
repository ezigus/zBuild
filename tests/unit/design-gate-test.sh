#!/usr/bin/env bash
# Tests: plugins/tool/design-gate — the PRE-build mechanical structural gate
# (ADR-046, EPIC #1216 issue #1218). T0, no-LLM, no-baseline; pure grep over
# design.md. Runs 5 structural checks (C1..C5), reports ALL violations in ONE
# pass, verdict-in-artifact, ALWAYS exits rc=0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design-gate — PRE-build mechanical structural gate (#1218, ADR-046)"
setup_test_env "design-gate"
_test_cleanup_hook() { cleanup_test_env; }

# design-gate is a T0 tool: no event-bus/db needed, but plug the events sink so
# emits are no-ops rather than errors.
export ZBUILD_EVENTS_DB="/dev/null"

# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/tool/design-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh"

# repo_root for the checks = a temp tree where declared TESTFILES/WIRING live.
ROOT="$TEST_TEMP_DIR/repo"
mkdir -p "$ROOT/tests" "$ROOT/scripts"
export ZBUILD_REPO_ROOT="$ROOT"

# _run_gate_with_md <design.md content>  → runs design_gate_run against a fresh
# state dir; sets $VERDICT + $RESULT_JSON + $FEEDBACK_PATH + $GATE_RC.
_state_seq=0
_run_gate_with_md() {
    local md_content="$1"
    _state_seq=$((_state_seq + 1))
    local state_dir="$TEST_TEMP_DIR/state-$_state_seq"
    local art="$state_dir/artifacts"
    mkdir -p "$art"
    printf '%s' "$md_content" > "$art/design.md"
    local state_file="$state_dir/pipeline-state.json"
    printf '{"schema_version":1}' > "$state_file"
    set +e
    design_gate_run "design-gate" "$state_file"
    GATE_RC=$?
    set -e
    RESULT_JSON="$art/design-gate-result.json"
    FEEDBACK_PATH="$art/design-gate-feedback.md"
    VERDICT="$(jq -r '.verdict' "$RESULT_JSON" 2>/dev/null || echo MISSING)"
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
    "0" "$(jq -r '.violations|length' "$RESULT_JSON")"

# ─── SPEC-2 (C3 classified): an UNCLASSIFIED SPEC → verdict=fail ──────────────
_run_gate_with_md '# Design

```scope
scripts/wire.sh
```

```acceptance
SPEC-1: no classifier here
TESTFILES:
tests/a-test.sh
WIRING: scripts/wire.sh
```
'
assert_eq "[SPEC-2] unclassified SPEC → verdict=fail" "fail" "$VERDICT"
assert_contains "[SPEC-2] violation names UNCLASSIFIED SPEC-1" \
    "$(jq -r '.violations|join(" ")' "$RESULT_JSON")" "UNCLASSIFIED SPEC-1"

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
    "$(jq -r '.violations|join(" ")' "$RESULT_JSON")" "WIRING_MISSING"

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
    "$(jq -r '.violations|join(" ")' "$RESULT_JSON")" "SCOPE_MISSING"

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
    "0" "$(jq -r '.violations|length' "$RESULT_JSON")"

# ─── SPEC-6 (happy path): a CLEAN design → verdict=pass, proceeds to build ────
_run_gate_with_md "$_clean_md"
assert_eq "[SPEC-6] clean design → verdict=pass" "pass" "$VERDICT"
assert_eq "[SPEC-6] clean design → zero violations" \
    "0" "$(jq -r '.violations|length' "$RESULT_JSON")"

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
_all="$(jq -r '.violations|join(" ")' "$RESULT_JSON")"
assert_eq "[SPEC-7] multi-violation design → verdict=fail" "fail" "$VERDICT"
assert_contains "[SPEC-7] reports SCOPE_MISSING in one pass"    "$_all" "SCOPE_MISSING"
assert_contains "[SPEC-7] reports UNCLASSIFIED in one pass"     "$_all" "UNCLASSIFIED"
assert_contains "[SPEC-7] reports WIRING_MISSING in one pass"   "$_all" "WIRING_MISSING"
assert_contains "[SPEC-7] reports MISSING_TESTFILE_FOR_SPEC in one pass" "$_all" "MISSING_TESTFILE_FOR_SPEC"

# ─── SPEC-8 (verdict-in-artifact): design_gate_run ALWAYS returns rc=0 ────────
# Even on a failing verdict the plugin returns 0 — the verdict lives in the
# artifact (shape-floor / gate-aggregator idiom); the cycle reads .verdict.
assert_eq "[SPEC-8] design_gate_run returns rc=0 on a FAIL verdict" "0" "$GATE_RC"
_run_gate_with_md "$_clean_md"
assert_eq "[SPEC-8] design_gate_run returns rc=0 on a PASS verdict" "0" "$GATE_RC"

# ─── SPEC-9 (feedback): feedback markdown written ONLY on fail ───────────────
_run_gate_with_md "$_clean_md"
assert_eq "[SPEC-9] no feedback file on a passing verdict" "absent" \
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

# ─── SPEC-10 (classifier helper): acceptance_spec_is_change / _classifier ────
# The C3 helper added to acceptance-block.sh distinguishes change/guard/unset.
_cls_md="$TEST_TEMP_DIR/cls-design.md"
printf '```acceptance\nSPEC-1[change]: a\nSPEC-2[guard]: b\nSPEC-3: c\nTESTFILES:\ntests/a-test.sh\n```\n' > "$_cls_md"
assert_eq "[SPEC-10] classifier SPEC-1 == change" "change" "$(acceptance_spec_classifier "$_cls_md" SPEC-1)"
assert_eq "[SPEC-10] classifier SPEC-2 == guard"  "guard"  "$(acceptance_spec_classifier "$_cls_md" SPEC-2)"
assert_eq "[SPEC-10] classifier SPEC-3 == '' (unclassified)" "" "$(acceptance_spec_classifier "$_cls_md" SPEC-3)"
set +e
acceptance_spec_is_change "$_cls_md" SPEC-1; _isc1=$?
acceptance_spec_is_change "$_cls_md" SPEC-2; _isc2=$?
set -e
assert_eq "[SPEC-10] acceptance_spec_is_change SPEC-1 → 0" "0" "$_isc1"
assert_eq "[SPEC-10] acceptance_spec_is_change SPEC-2 → 1 (guard)" "1" "$_isc2"

# ─── SPEC-11 (#1227 fix 1): C1 fence tolerates trailing whitespace ───────────
# The design stage asserts the scope block with `grep -q '^```scope'`, which
# accepts a fence line carrying trailing whitespace. C1's fence check must
# mirror that tolerance so a trailing-space fence does NOT falsely trip
# SCOPE_MISSING. Build a clean design whose scope fence has a trailing space.
_ws_md="$(printf '# Design\n\n```scope \nscripts/wire.sh\n```\n\n```acceptance\nSPEC-1[change]: the thing works\nTESTFILES:\ntests/a-test.sh\nWIRING: scripts/wire.sh\n```\n')"
_run_gate_with_md "$_ws_md"
_ws_viol="$(jq -r '.violations|join(" ")' "$RESULT_JSON")"
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
    "0" "$(jq -r '.violations|length' "$RESULT_JSON")"

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
    "0" "$(jq -r '.violations|length' "$RESULT_JSON")"

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
    "$(jq -r '.violations|join(" ")' "$RESULT_JSON")" "MISSING_TESTFILE_FOR_SPEC SPEC-2"

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
    "$(jq -r '.violations|join(" ")' "$RESULT_JSON")" "MISSING_TESTFILE_FOR_SPEC"

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
    "$(jq -r '.violations|join(" ")' "$RESULT_JSON")" "MISSING_TESTFILE_FOR_SPEC"

print_test_results
