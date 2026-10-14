#!/usr/bin/env bash
# tests/integration/adr040-isolated-gate-test.sh — the ADR-040 §5 gate-reference
# check is retired (amended 2026-10-12).
#
# #2040 let a model-judged stage gate only when it DECLARED an input produced
# outside its own cycle — its "standard". Declared inputs are retired (ADR-055
# §1, amended 2026-10-12): every stage gets every stage's latest output under
# Previous work (ADR-068 §8), so a stage's standard is no longer declared
# anywhere for pre-flight to read. Which stages may gate is the template's
# `gate:` choice (ADR-040 §5 as amended); pre-flight still checks the
# aggregator wiring.
#
#   SPEC-1 [change]: a model-judged convergence:gate member of its cycle is
#                    admitted at pre-flight; no GATE_REFERENCE violation exists
#   SPEC-3 [guard] : a mechanical gate is admitted as before
#   SPEC-5 [guard] : an ADVISORY model stage is admitted as before
#   SPEC-6 [guard] : the aggregator wiring is still checked — a cycle exiting
#                    on an advisory member is refused (CYCLE_AGG_TYPE)
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

print_test_header "ADR-040 §5: the gate-reference check is retired; aggregator wiring is still checked"
setup_test_env "adr040-isolated-gate"
_test_cleanup_hook() { cleanup_test_env; }

FX="$TEST_TEMP_DIR/fx"; mkdir -p "$FX/agent" "$FX/tool"

# write_fx <dir> <id> <conv> <router:yes|no> <out_id>
write_fx() {
    local d="$FX/$1" id="$2" conv="$3" router="$4" out="$5"
    mkdir -p "$d"
    {
        printf 'id: %s\nname: %s\nkind: %s\n' "$id" "$id" "${1%%/*}"
        printf 'convergence: %s\nversion: 0.1.0\nhooks:\n  run: r\n' "$conv"
        printf 'requires:\n  core:\n    - event-bus\n'
        [[ "$router" == "yes" ]] && printf '    - router\n'
        printf 'provides:\n  role: %s\n  result_contract: 3\n' "${id//-/_}"
        printf 'outputs:\n  - id: %s\n    path: ${artifact_dir}/%s.json\n' "$out" "$out"
        printf '    type: %s.json@1\n    format: json\n    required: true\n    primary: true\n' "$out"
        # ADR-055 §9 (#2000): every stage-bound plugin declares exactly one.
        printf -- '  - id: %s_summary\n    path: ${artifact_dir}/%s-summary.md\n' "$out" "$out"
        printf '    type: %s-summary.md@1\n    format: markdown\n    required: true\n    summary: true\n' "$out"
    } > "$d/manifest.yaml"
    printf 'r() { return 0; }\n' > "$d/plugin.sh"
}

write_fx tool/iso-producer  iso-producer  gate     no  diff_patch
write_fx tool/iso-mech      iso-mech      gate     no  mech_result
write_fx agent/iso-model    iso-model     gate     yes model_result
write_fx agent/iso-advisory iso-advisory  advisory yes adv_result

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
    set +e
}

# ── SPEC-1: a model-judged gate is admitted ───────────────────────────────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-model"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-model"
_run "$(printf 'iso-producer\niso-model\n')"
assert_eq "[SPEC-1][change] a model-judged convergence:gate member is admitted" "0" "$RC"
if grep -qF 'GATE_REFERENCE' <<< "$OUT"; then
    assert_fail "[SPEC-1][change] no GATE_REFERENCE violation is raised" "$OUT"
else
    assert_pass "[SPEC-1][change] no GATE_REFERENCE violation is raised"
fi

# ── SPEC-3: a mechanical gate is admitted ──────────────────────────────────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-mech"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-mech"
_run "$(printf 'iso-producer\niso-mech\n')"
assert_eq "[SPEC-3][guard] a mechanical gate is admitted" "0" "$RC"

# ── SPEC-5: advisory model stages are admitted (today's review-lens) ───────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-mech"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-mech"
_run "$(printf 'iso-producer\niso-advisory\niso-mech\n')"
assert_eq "[SPEC-5][guard] an ADVISORY model stage is admitted" "0" "$RC"

# ── SPEC-6: the aggregator wiring is still checked ─────────────────────────
_reset
export _TPL_CYCLE_STAGES_c1="iso-producer,iso-advisory"
export _TPL_CYCLE_UNTIL_STAGE_c1="iso-advisory"
_run "$(printf 'iso-producer\niso-advisory\n')"
assert_eq "[SPEC-6][guard] a cycle exiting on an advisory member is refused" "1" "$RC"
assert_contains "[SPEC-6][guard] as CYCLE_AGG_TYPE" "$OUT" "CYCLE_AGG_TYPE"

print_test_results
exit $((FAIL > 0))
