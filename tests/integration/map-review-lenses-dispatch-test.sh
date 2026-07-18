#!/usr/bin/env bash
# Integration (#1295): map operator wired to review_lenses in simple.yaml.
#
# SPEC-1: template loads and review_lenses emits a "map:review_lenses" dispatch unit;
#         the `as:` env-target resolves to ZBUILD_REVIEW_LENS_ID.
# SPEC-2: _strategy_run_map dispatches exactly 6 work units (one per element).
# SPEC-3: each work unit bakes a DISTINCT ZBUILD_MAP_ELEMENT value AND the
#         template-named ZBUILD_REVIEW_LENS_ID (via `as:`) — six elements
#         security/performance/red-team/correctness/scope/sre.
# SPEC-4: ZBUILD_MAP_ELEMENT + the `as:` env-target are readable in the work unit.
# SPEC-5: ZBUILD_PLATFORM stays "generic" for all elements (platform not hijacked).
# SPEC-6: the (UNCHANGED) review-lens plugin's _review_lens_id() resolves to the
#         element name via ZBUILD_REVIEW_LENS_ID — golden-parity: same artifact
#         filename (lens-<element>.json) as the old per-stage approach.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "map operator — review_lenses dispatch + work-unit env contract (#1295)"
setup_test_env "map-review-lenses-dispatch"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
export ZBUILD_TEMPLATES_DIR=""   # use shipped templates

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/strategies/map.sh
source "$REPO_ROOT/core/pipeline/strategies/map.sh"
# shellcheck source=../../core/pipeline/strategies/common.sh
source "$REPO_ROOT/core/pipeline/strategies/common.sh"

SIMPLE_TPL="$REPO_ROOT/config/templates/simple.yaml"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# ─── SPEC-1: template load ────────────────────────────────────────────────────
print_test_section "SPEC-1: review_lenses is a map dispatch unit in simple.yaml"

set +e; load_template "$SIMPLE_TPL"; _load_rc=$?; set -e
assert_eq "[SPEC-1] simple.yaml loads rc=0" "0" "$_load_rc"

_has_map_unit=0
for _u in "${_TPL_DISPATCH_UNITS[@]}"; do
    [[ "$_u" == "map:review_lenses" ]] && { _has_map_unit=1; break; }
done
if [[ $_has_map_unit -eq 1 ]]; then
    assert_pass "[SPEC-1] map:review_lenses is in _TPL_DISPATCH_UNITS"
else
    assert_fail "[SPEC-1] map:review_lenses missing from dispatch units" "${_TPL_DISPATCH_UNITS[*]}"
fi

assert_eq "[SPEC-1] _TPL_MAP_OVER_review_lenses == lenses" "lenses" "${_TPL_MAP_OVER_review_lenses:-MISSING}"
assert_eq "[SPEC-1] _TPL_MAP_ELEMENTS_review_lenses has 6 elements" \
    "security,performance,red-team,correctness,scope,sre" \
    "${_TPL_MAP_ELEMENTS_review_lenses:-MISSING}"
assert_eq "[SPEC-1] _TPL_MAP_ROLES_review_lenses == review_lens" "review_lens" "${_TPL_MAP_ROLES_review_lenses:-MISSING}"
assert_eq "[SPEC-1] _TPL_MAP_AS_review_lenses == ZBUILD_REVIEW_LENS_ID (as: env-target)" \
    "ZBUILD_REVIEW_LENS_ID" "${_TPL_MAP_AS_review_lenses:-MISSING}"

# ─── SPEC-2 / SPEC-3 / SPEC-4 / SPEC-5: work-unit dispatch ──────────────────
print_test_section "SPEC-2/3/4/5: 6 distinguishable work units with correct env"

PLUGINS_ROOT="$REPO_ROOT/plugins"
WU_ENV_LOG="$TEST_TEMP_DIR/wu-env.log"
: > "$WU_ENV_LOG"

# Spy on orch_dispatch to capture ZBUILD_MAP_ELEMENT / ZBUILD_PLATFORM baked
# into each work unit before executing it.
orch_spawn()    { mkdir -p "${TMPDIR:-/tmp}/zbuild-map-pool-$1/results" "${TMPDIR:-/tmp}/zbuild-map-pool-$1/pids"; return 0; }
orch_dispatch() {
    local _pool="$1" _wu="${2:-}"
    # Extract the env vars baked into the work unit script.
    local _elem _plat _lens
    _elem="$(/usr/bin/grep -m1 "^export ZBUILD_MAP_ELEMENT=" "$_wu" 2>/dev/null \
              | sed "s/^export ZBUILD_MAP_ELEMENT='//;s/'$//" || true)"
    _plat="$(/usr/bin/grep -m1 "^export ZBUILD_PLATFORM=" "$_wu" 2>/dev/null \
              | sed "s/^export ZBUILD_PLATFORM='//;s/'$//" || true)"
    # The `as:` env-target — the template-named var the review-lens plugin reads.
    _lens="$(/usr/bin/grep -m1 "^export ZBUILD_REVIEW_LENS_ID=" "$_wu" 2>/dev/null \
              | sed "s/^export ZBUILD_REVIEW_LENS_ID='//;s/'$//" || true)"
    printf 'elem=[%s] plat=[%s] lens=[%s]\n' "$_elem" "${_plat:-generic}" "$_lens" >> "$WU_ENV_LOG"
    printf 'slot-001\n'
    return 0
}
orch_collect()  { return 0; }
orch_shutdown() { rm -rf "${TMPDIR:-/tmp}/zbuild-map-pool-$1" 2>/dev/null || true; return 0; }

# Stub plugin resolution so no real plugin lookup occurs.
resolve_plugin_for_role() { echo "$PLUGINS_ROOT/agent/review-lens"; }
_check_artifact_contract() { return 0; }

# Build the dimension array that the runner would build from _TPL_MAP_ELEMENTS_*.
declare -ga "_MAP_DIM_lenses"
IFS=',' read -ra "_MAP_DIM_lenses" <<< "${_TPL_MAP_ELEMENTS_review_lenses}"
export "_MAP_DIM_lenses"

ROLES_OUT="${_TPL_MAP_ROLES_review_lenses:-review_lens}"

set +e
_strategy_run_map "map-pool-spec2" "review_lenses" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" \
    "lenses" "${_TPL_MAP_AS_review_lenses}"
_map_rc=$?
set -e
# rc=3 (empty dim) is treated as 0 by the runner — allow it here too.
if [[ $_map_rc -eq 0 ]] || [[ $_map_rc -eq 3 ]]; then
    assert_pass "[SPEC-2] _strategy_run_map exits 0 (or 3=empty treated as pass)"
else
    assert_fail "[SPEC-2] _strategy_run_map exits 0" "rc=$_map_rc"
fi

# Count dispatched work units.
_dispatch_count=0
_dispatch_count=$(/usr/bin/grep -c "^elem=" "$WU_ENV_LOG" 2>/dev/null) || _dispatch_count=0
assert_eq "[SPEC-2] exactly 6 work units dispatched" "6" "$_dispatch_count"

# Each element must appear exactly once.
_expected_elements=("security" "performance" "red-team" "correctness" "scope" "sre")
for _el in "${_expected_elements[@]}"; do
    _found=$(/usr/bin/grep -c "elem=\[${_el}\]" "$WU_ENV_LOG" 2>/dev/null || echo 0)
    assert_eq "[SPEC-3] element '$_el' dispatched exactly once" "1" "$_found"
    # The `as:` env-target (ZBUILD_REVIEW_LENS_ID) must carry the same element —
    # this is what the UNCHANGED review-lens plugin reads for its identity.
    _lens_found=$(/usr/bin/grep -c "elem=\[${_el}\] plat=\[generic\] lens=\[${_el}\]" "$WU_ENV_LOG" 2>/dev/null || echo 0)
    assert_eq "[SPEC-3] ZBUILD_REVIEW_LENS_ID=='$_el' for element '$_el'" "1" "$_lens_found"
done

# All work units must have platform=generic (not hijacked by element name).
_generic_count=$(/usr/bin/grep -c "plat=\[generic\]" "$WU_ENV_LOG" 2>/dev/null || echo 0)
assert_eq "[SPEC-5] all 6 work units have platform=generic" "6" "$_generic_count"

# ─── SPEC-4: ZBUILD_MAP_ELEMENT readable inside the work unit ────────────────
print_test_section "SPEC-4: ZBUILD_MAP_ELEMENT is baked and readable in the work unit"

# Build a single work unit for element "security" and verify the env vars are set.
_wu_path="$(_strategy_make_work_unit \
    "$PLUGINS_ROOT/agent/review-lens" "review_lenses" "$STATE_FILE" \
    "generic" "security" "lenses" "ZBUILD_REVIEW_LENS_ID" 2>/dev/null)" || true

if [[ -n "$_wu_path" ]] && [[ -f "$_wu_path" ]]; then
    _elem_line="$(/usr/bin/grep "ZBUILD_MAP_ELEMENT" "$_wu_path" || true)"
    _dim_line="$(/usr/bin/grep "ZBUILD_MAP_DIMENSION" "$_wu_path" || true)"
    _lens_line="$(/usr/bin/grep "^export ZBUILD_REVIEW_LENS_ID=" "$_wu_path" || true)"
    if [[ "$_elem_line" == *"'security'"* ]]; then
        assert_pass "[SPEC-4] ZBUILD_MAP_ELEMENT='security' baked into work unit"
    else
        assert_fail "[SPEC-4] ZBUILD_MAP_ELEMENT='security' baked into work unit" "line: $_elem_line"
    fi
    if [[ "$_dim_line" == *"'lenses'"* ]]; then
        assert_pass "[SPEC-4] ZBUILD_MAP_DIMENSION='lenses' baked into work unit"
    else
        assert_fail "[SPEC-4] ZBUILD_MAP_DIMENSION='lenses' baked into work unit" "line: $_dim_line"
    fi
    if [[ "$_lens_line" == *"'security'"* ]]; then
        assert_pass "[SPEC-4] as: env-target ZBUILD_REVIEW_LENS_ID='security' baked into work unit"
    else
        assert_fail "[SPEC-4] as: env-target ZBUILD_REVIEW_LENS_ID='security' baked" "line: $_lens_line"
    fi
else
    assert_fail "[SPEC-4] work unit file created" "path=$_wu_path"
fi

# The `as:` env-target must be OMITTED when not requested (no stray export).
_wu_noas="$(_strategy_make_work_unit \
    "$PLUGINS_ROOT/agent/review-lens" "review_lenses" "$STATE_FILE" \
    "generic" "security" "lenses" 2>/dev/null)" || true
if [[ -n "$_wu_noas" ]] && [[ -f "$_wu_noas" ]]; then
    if /usr/bin/grep -q "ZBUILD_REVIEW_LENS_ID" "$_wu_noas"; then
        assert_fail "[SPEC-4] no env-target export when as: omitted" "unexpected ZBUILD_REVIEW_LENS_ID"
    else
        assert_pass "[SPEC-4] no env-target export when as: omitted"
    fi
fi

# ─── SPEC-6: _review_lens_id() resolves to element name (golden-parity) ─────
print_test_section "SPEC-6: _review_lens_id() resolves element name (golden artifact parity)"

# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"

# The plugin is UNCHANGED from origin/main: _review_lens_id() reads
# ZBUILD_REVIEW_LENS_ID. The map `as:` mapping populates exactly that var, so the
# same lens-<element>.json artifact names are produced (golden parity).
export ZBUILD_CURRENT_STAGE="review_lenses"

for _el in "security" "performance" "red-team" "correctness" "scope" "sre"; do
    export ZBUILD_REVIEW_LENS_ID="$_el"
    _resolved="$(_review_lens_id)"
    assert_eq "[SPEC-6] _review_lens_id() with ZBUILD_REVIEW_LENS_ID='$_el'" "$_el" "$_resolved"
done

# Without ZBUILD_REVIEW_LENS_ID set (old path): falls back to ZBUILD_CURRENT_STAGE.
# The group id "review_lenses" has no strippable prefix → id = "review_lenses".
unset ZBUILD_REVIEW_LENS_ID 2>/dev/null || true
_resolved_fallback="$(_review_lens_id)"
assert_eq "[SPEC-6] fallback to ZBUILD_CURRENT_STAGE when ZBUILD_REVIEW_LENS_ID unset" \
    "review_lenses" "$_resolved_fallback"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
