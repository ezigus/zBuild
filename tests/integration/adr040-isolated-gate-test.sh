#!/usr/bin/env bash
# tests/integration/adr040-isolated-gate-test.sh — a model-judged stage may gate
# only when it cannot see what it grades (#2040, ADR-040 §5).
#
# §5 stated the invariant as mechanical-vs-model, but its own justification names
# a different property: it "does not read what a stage DOES, it reads where a
# stage SITS … un-gameable by prompt wording". Mechanical-ness was a PROXY for
# un-gameability — the only one available when every model-judged stage read the
# artifact it was grading.
#
# The proxy and the property come apart for a stage whose inputs are fixed and
# upstream-authored. The structural test is cycle-relative: a model-judged gate
# must not consume an output produced by a member of the SAME cycle, because
# that output is the artifact under review. review-lens consuming diff_patch is
# the shape that must stay refused; a stage consuming only an upstream artifact
# is admitted.
#
#   SPEC-1 [change]: a convergence:gate model stage consuming a SAME-CYCLE
#                    member's output is REFUSED at load, naming stage and input
#   SPEC-2 [change]: the same stage consuming only UPSTREAM inputs is ADMITTED
#   SPEC-3 [guard] : a mechanical gate is untouched — form (a) as before
#   SPEC-4 [change]: fail-closed — a model-judged gate declaring NO inputs is
#                    refused, because it cannot prove isolation
#   SPEC-5 [guard] : an ADVISORY model stage consuming the diff is fine; it is
#                    not on a convergence path, which is today's review-lens
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh" 2>/dev/null || true
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh"

print_test_header "ADR-040 §5: a gate may be model-judged when it cannot see what it grades (#2040)"
setup_test_env "adr040-isolated-gate"
_test_cleanup_hook() { cleanup_test_env; }

FX="$TEST_TEMP_DIR/fx"; mkdir -p "$FX/agent" "$FX/tool"

# write_fx <dir> <id> <conv> <router:yes|no> <inputs_csv> <out_id>
write_fx() {
    local d="$FX/$1" id="$2" conv="$3" router="$4" ins="$5" out="$6"
    mkdir -p "$d"
    {
        printf 'id: %s\nname: %s\nkind: %s\n' "$id" "$id" "${1%%/*}"
        printf 'convergence: %s\nversion: 0.1.0\nhooks:\n  run: r\n' "$conv"
        printf 'requires:\n  core:\n    - event-bus\n'
        [[ "$router" == "yes" ]] && printf '    - router\n'
        printf 'provides:\n  role: %s\n  result_contract: 2\n' "${id//-/_}"
        printf 'config:\n  valid_verdicts: [pass, fail]\n'
        if [[ -n "$ins" ]]; then
            printf 'inputs:\n'
            local _i; local _IFS="$IFS"; IFS=','
            for _i in $ins; do printf -- '  - id: %s\n    required: true\n' "$_i"; done
            IFS="$_IFS"
        else
            printf 'inputs: []\n'
        fi
        printf 'outputs:\n  - id: %s\n    path: ${artifact_dir}/%s.json\n' "$out" "$out"
        printf '    type: %s.json@1\n    format: json\n    required: true\n    primary: true\n' "$out"
        # ADR-055 §9 (#2000): every stage-bound plugin declares exactly one.
        printf -- '  - id: %s_summary\n    path: ${artifact_dir}/%s-summary.md\n' "$out" "$out"
        printf '    type: %s-summary.md@1\n    format: markdown\n    required: true\n    summary: true\n' "$out"
    } > "$d/manifest.yaml"
    printf 'r() { return 0; }\n' > "$d/plugin.sh"
}

# The producer whose output IS the artifact under review, and an upstream one.
write_fx tool/iso-producer  iso-producer  gate     no  ""             diff_patch
write_fx agent/iso-upstream iso-upstream  advisory no  ""             design_doc
write_fx tool/iso-mech      iso-mech      gate     no  "diff_patch"   mech_result
write_fx agent/iso-sees     iso-sees      gate     yes "diff_patch"   sees_result
write_fx agent/iso-blind    iso-blind     gate     yes "design_doc"   blind_result
write_fx agent/iso-noinput  iso-noinput   gate     yes ""             noinput_result
write_fx agent/iso-advisory iso-advisory  advisory yes "diff_patch"   adv_result

_reset() {
    unset _TPL_CYCLES _TPL_CYCLE_STAGES_c1 _TPL_CYCLE_UNTIL_STAGE_c1 2>/dev/null || true
    _TPL_CYCLES=(c1)
}
_run() {
    local stages="$1" sf="$TEST_TEMP_DIR/st/state.json"
    mkdir -p "$(dirname "$sf")"; rm -f "$sf"
    set +e
    OUT="$(ZBUILD_CONTRACT_VALIDATOR=enforce \
        _contract_validate_pipeline "$stages" "$FX" "$sf" 2>&1)"
    RC=$?
    set -e
}

# ── SPEC-1: model gate consuming a same-cycle member's output → refused ──────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-sees"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-sees"
_run "$(printf 'iso-producer\niso-sees\n')"
assert_eq "[SPEC-1][change] a model-judged gate seeing a same-cycle output is refused" "2" "$RC"
assert_contains "[SPEC-1][change] and the message names the stage" "$OUT" "iso-sees"
assert_contains "[SPEC-1][change] and names the offending input" "$OUT" "diff_patch"

# ── SPEC-2: same stage, upstream-only inputs → admitted ─────────────────────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-blind"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-blind"
_run "$(printf 'iso-upstream\niso-producer\niso-blind\n')"
assert_eq "[SPEC-2][change] upstream-only inputs are admitted on the convergence path" "0" "$RC"

# ── SPEC-3: a mechanical gate is untouched ─────────────────────────────────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-mech"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-mech"
_run "$(printf 'iso-producer\niso-mech\n')"
assert_eq "[SPEC-3][guard] a mechanical gate consuming the same output is unaffected" "0" "$RC"

# ── SPEC-4: fail-closed when isolation cannot be proven ────────────────────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-noinput"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-noinput"
_run "$(printf 'iso-producer\niso-noinput\n')"
assert_eq "[SPEC-4][change] a model-judged gate declaring NO inputs is refused" "2" "$RC"

# ── SPEC-5: advisory model stages are untouched (today's review-lens) ──────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-mech"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-mech"
_run "$(printf 'iso-producer\niso-advisory\niso-mech\n')"
assert_eq "[SPEC-5][guard] an ADVISORY model stage may still read the diff" "0" "$RC"

print_test_results
exit $((FAIL > 0))
