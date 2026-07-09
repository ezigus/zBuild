#!/usr/bin/env bash
# core/pipeline/strategies/common.sh — shared helpers for strategy modules (issue #222)
# ADR-009 (platform-aware modularity), ADR-011 (pluggable orch backend)
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_STRATEGY_COMMON_LOADED:-}" ]] && return 0
_ZBUILD_STRATEGY_COMMON_LOADED=1

_ZBUILD_STRATEGIES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="${_ZBUILD_ROOT:-$(cd "${_ZBUILD_STRATEGIES_DIR}/../../.." && pwd)}"

# ─── _strategy_validate_stage ────────────────────────────────────────────────
# Allowlist: non-empty, no path-traversal sequences, no shell metacharacters.
# exit 0: valid; exit 2: invalid.
_strategy_validate_stage() {
    local stage="$1"
    [[ -z "$stage" ]] && return 2
    # Strict allowlist — identical to platform: prevents ' injection in the
    # heredoc literal and path-traversal in scratch dir names.
    if [[ ! "$stage" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
        warn "strategy: invalid stage name: ${stage}" || true
        return 2
    fi
    return 0
}

# ─── _strategy_validate_platform ─────────────────────────────────────────────
# Allowlist: non-empty, ^[a-zA-Z0-9_-]{1,64}$.
# exit 0: valid; exit 2: invalid.
_strategy_validate_platform() {
    local platform="$1"
    [[ -z "$platform" ]] && return 2
    if [[ ! "$platform" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
        warn "strategy: invalid platform name: ${platform}" || true
        return 2
    fi
    return 0
}

# ─── _strategy_orch_scratch_dir ──────────────────────────────────────────────
# #898: resolve the orch scratch dir. Default → per-run isolation under
# ~/.zbuild/state/runs/<run_id>/orch (the orchestrator analog of #889 state
# isolation) so concurrent runs never share scratch. An explicit
# ZBUILD_ORCH_SCRATCH overrides. ZBUILD_RUN_ID is exported by the runner before
# any stage dispatch (falls back to "default" only if somehow unset).
_strategy_orch_scratch_dir() {
    if [[ -n "${ZBUILD_ORCH_SCRATCH:-}" ]]; then
        printf '%s' "$ZBUILD_ORCH_SCRATCH"
    else
        printf '%s' "${ZBUILD_STATE_ROOT:-${HOME}/.zbuild/state}/runs/${ZBUILD_RUN_ID:-default}/orch"
    fi
}

# ─── _strategy_make_work_unit <plugin_dir> <stage> <state_file> [<platform>] [<map_element>] [<map_dimension>] [<env_target>] ───
# Creates a self-contained executable shell script that calls plugin_hook_call.
# Validates stage and platform before baking into the script body.
# Prints the path of the temp file; caller is responsible for cleanup (rm -f).
# exit 0: success; exit 2: validation failure; exit 1: temp file creation failure.
#
# map_element / map_dimension (issue #1295, ADR-047 §2): generic element identity
# for non-platform map dimensions. When set, exports to the work unit:
#   ZBUILD_MAP_ELEMENT=<element>    — the current element (e.g. "security")
#   ZBUILD_MAP_DIMENSION=<dim>      — the dimension name (e.g. "lenses")
# Plugins read ZBUILD_MAP_ELEMENT to derive per-element identity when
# ZBUILD_CURRENT_STAGE is the group id, not an element-specific stage id.
#
# env_target (issue #1295, ADR-047 §2): an optional caller-named env var, set to
# the map element in the work unit — a generic dimension→env mapping declared by
# the template's `as:` field (e.g. lenses → ZBUILD_REVIEW_LENS_ID). Keeps existing
# plugins that read their own env var working unchanged; the var name lives in the
# template, never hardcoded here. Validated as a shell identifier before baking.
_strategy_make_work_unit() {
    local plugin_dir="$1" stage="$2" state_file="$3" platform="${4:-generic}"
    local map_element="${5:-}" map_dimension="${6:-}" env_target="${7:-}"

    _strategy_validate_stage "$stage"   || return 2
    _strategy_validate_platform "$platform" || return 2
    [[ -z "$plugin_dir" ]] && { warn "strategy: _strategy_make_work_unit: empty plugin_dir" || true; return 2; }
    # #1295 Copilot: map_element/map_dimension are baked as single-quoted literals
    # into the work-unit script — a value with ', whitespace, or a newline would
    # break out of the quotes (shell-injection). Fail closed with an actionable
    # error. Element allows '-' (matches stage/platform); dimension is a shell-safe
    # token used to name a bash array (_MAP_DIM_<dim>), so no '-'.
    if [[ -n "$map_element" && ! "$map_element" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
        warn "strategy: invalid map element: ${map_element} (expected ^[A-Za-z0-9_-]{1,64}$)" || true
        return 2
    fi
    if [[ -n "$map_dimension" && ! "$map_dimension" =~ ^[a-zA-Z0-9_]{1,64}$ ]]; then
        warn "strategy: invalid map dimension: ${map_dimension} (expected ^[A-Za-z0-9_]{1,64}$)" || true
        return 2
    fi
    if [[ -n "$env_target" && ! "$env_target" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,63}$ ]]; then
        warn "strategy: invalid env_target var name: ${env_target}" || true
        return 2
    fi

    local scratch_dir; scratch_dir="$(_strategy_orch_scratch_dir)"
    mkdir -p "$scratch_dir" 2>/dev/null && chmod 700 "$scratch_dir" 2>/dev/null || {
        warn "strategy: cannot create orch scratch dir: ${scratch_dir}" || true
        return 1
    }

    local wu
    # Note: no .sh suffix — macOS mktemp does not randomize names when a suffix follows XXXXXX.
    wu="$(mktemp "${scratch_dir}/wu-XXXXXX")" || {
        warn "strategy: mktemp failed for work unit" || true
        return 1
    }

    # Bake in fully-qualified, immutable paths at construction time.
    # Values are embedded as single-quoted literals to prevent re-expansion.
    # event-bus.sh is sourced so plugin_hook_call emits events to the shared
    # ZBUILD_EVENTS_JSONL / ZBUILD_EVENTS_DB (inherited env vars from runner).
    #
    # Issue #307: ADR-009 §"ZBUILD_PLATFORM env contract" promises plugins
    # see ZBUILD_PLATFORM=<single-platform> per per-platform invocation.
    # ADR-001's hook-context table lists the older name ZBUILD_TARGET_PLATFORM
    # for the same value. We export both so plugins can rely on either; the
    # canonical name going forward is ZBUILD_PLATFORM (ADR-009 §6).
    local _map_env_lines=""
    if [[ -n "$map_element" ]]; then
        _map_env_lines="export ZBUILD_MAP_ELEMENT='${map_element}'
export ZBUILD_MAP_DIMENSION='${map_dimension}'"
        # env_target: template-named var also carrying the element (generic
        # dimension→env mapping). var name validated above; element is a bare
        # dimension token, single-quoted like the others.
        if [[ -n "$env_target" ]]; then
            _map_env_lines="${_map_env_lines}
export ${env_target}='${map_element}'"
        fi
    fi

    cat > "$wu" <<WORKUNIT
#!/usr/bin/env bash
set -euo pipefail
source '${_ZBUILD_ROOT}/scripts/lib/helpers.sh'
source '${_ZBUILD_ROOT}/core/event-bus/event-bus.sh'
source '${_ZBUILD_ROOT}/core/plugin-registry/registry.sh'
export ZBUILD_PLATFORM='${platform}'
export ZBUILD_TARGET_PLATFORM='${platform}'
export ZBUILD_ROOT='${_ZBUILD_ROOT}'
${_map_env_lines}
plugin_hook_call '${plugin_dir}' run '${stage}' '${state_file}'
WORKUNIT

    chmod 700 "$wu"
    printf '%s\n' "$wu"
    return 0
}
