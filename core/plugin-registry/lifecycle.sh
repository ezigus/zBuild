#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugin-registry — lifecycle hook dispatch + fail-closed output scanner    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Split from registry.sh (#364). Owns the runtime dispatch path:
# `plugin_hook_call` (sources plugin.sh in an isolated subshell, applies
# pre-source tamper checks, calls the hook function, then verifies declared
# outputs) and `scan_plugin_outputs` (ADR-001 fail-closed artifact-presence
# scanner). Depends on yaml_get / verify_plugin_for_source from the other two
# split modules — sourced together via the registry.sh facade.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_REGISTRY_LIFECYCLE_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_LIFECYCLE_LOADED=1

# ─── scan_plugin_outputs — fail-closed artifact-presence scanner (#288) ─────
# ADR-001 §Fail-closed scanner contract:
#   "If a plugin declares an output but no artifact exists at outputs[].path
#    after run completes with exit 0, the engine emits a synthetic blocking
#    finding."
# #1906 retired provides.artifact_type, which the original wording keyed on;
# outputs[].required is the single declaration the scan now honours.
#
# Arguments:
#   $1 — plugin_dir
#   $2 — state_file (so $state_dir / $artifacts_dir can substitute into paths)
#
# Returns:
#   0 if all declared outputs are present (or no outputs declared).
#   1 if any declared output is missing — and emits one
#      `plugin.artifact.missing` event per missing path.
#
# Path-template substitution (Phase 0.5): supports ${state_dir} and
# ${artifact_dir} / ${artifacts_dir}. Any other ${VAR} resolves from the work
# unit's exported environment (#1803) — per-member outputs such as review-lens's
# `lens-${ZBUILD_REVIEW_LENS_ID}.json` (ADR-047 §2) are only checkable once the
# element var is expanded. A var that is unset stays literal and fails the check.
scan_plugin_outputs() {
    local plugin_dir="$1"
    local state_file="${2:-}"
    local stage="${3:-}"
    local manifest="$plugin_dir/manifest.yaml"

    # No manifest, no outputs to scan — silently succeed.
    [[ ! -f "$manifest" ]] && return 0

    local plugin_id; plugin_id="$(yaml_get "$manifest" "id" 2>/dev/null || true)"
    local kind; kind="$(yaml_get "$manifest" "kind" 2>/dev/null || true)"
    # ADR-047 §4 capability flag: build legitimately writes a zero-byte diff.patch
    # when a turn changed no code. The exemption is deliberately narrow — it never
    # covers a `primary: true` output, so a stage cannot mask an empty verdict
    # artifact (e.g. build-summary.json) by declaring the flag in its own manifest.
    local empty_diff_ok; empty_diff_ok="$(yaml_get "$manifest" "capabilities.empty_diff_legitimate" 2>/dev/null || true)"

    # Compute substitution roots from state_file.
    local state_dir="" artifact_dir=""
    if [[ -n "$state_file" ]]; then
        state_dir="$(dirname "$state_file")"
        artifact_dir="${state_dir}/artifacts"
    fi

    # Pull outputs[].path entries from the manifest. yaml_get/yaml_get_list
    # don't model lists of objects, so grep the YAML directly. Format we
    # support (per ADR-001):
    #   outputs:
    #     - name: foo
    #       path: ${artifact_dir}/foo.json
    #       type: foo.json
    # #511 F2: respect `required: false` on outputs (e.g. test plugin's
    # `test_failures_summary` which is intentionally ABSENT when the test
    # verdict is `pass` — missing == empty). Without this, the scanner
    # would flag the missing optional artifact as a fail-closed contract
    # violation on every passing run, breaking the parity goldens.
    local paths
    paths="$(awk '
        BEGIN { in_block = 0; cur_path = ""; cur_required = ""; cur_primary = "" }
        function flush() {
            if (cur_path != "" && cur_required != "false") {
                print cur_path "\t" cur_primary
            }
            cur_path = ""; cur_required = ""; cur_primary = ""
        }
        /^outputs:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z_]/ { flush(); in_block = 0 }
        in_block && /^[[:space:]]*-[[:space:]]/ { flush() }
        in_block && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_path = line
            next
        }
        in_block && /^[[:space:]]+required:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+required:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_required = line
            next
        }
        in_block && /^[[:space:]]+primary:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+primary:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            # Case-folded: a manifest writing `primary: True` must not read as
            # non-primary and so slip past the empty-artifact guard below.
            # `required` is deliberately NOT folded — a non-canonical value there
            # already fails closed (treated as required).
            cur_primary = tolower(line)
            next
        }
        END { flush() }
    ' "$manifest" 2>/dev/null)"

    [[ -z "$paths" ]] && return 0

    local missing=0
    local raw_path raw_primary resolved _violation _event _var _expansions
    while IFS=$'\t' read -r raw_path raw_primary; do
        [[ -z "$raw_path" ]] && continue
        resolved="$raw_path"
        # Phase 0.5 substitutions.
        resolved="${resolved//\$\{state_dir\}/$state_dir}"
        resolved="${resolved//\$\{artifact_dir\}/$artifact_dir}"
        resolved="${resolved//\$\{artifacts_dir\}/$artifact_dir}"
        # Remaining ${VAR} tokens come from the work unit's exported env (the
        # template's `as:` mapping, e.g. ZBUILD_REVIEW_LENS_ID). Indirect
        # expansion only — never eval — so a manifest cannot inject a command.
        # Bounded, and an unset var is left literal so the check fails loudly.
        _expansions=0
        while [[ $_expansions -lt 16 ]] && [[ "$resolved" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
            _var="${BASH_REMATCH[1]}"
            [[ -z "${!_var+x}" ]] && break
            resolved="${resolved//\$\{$_var\}/${!_var}}"
            _expansions=$((_expansions + 1))
        done

        # An absent output always violates; a zero-byte one violates unless the
        # plugin declared the empty-diff capability AND this is not its primary.
        _violation=""
        if [[ ! -e "$resolved" ]]; then
            _violation="absent"
            _event="plugin.artifact.missing"
        elif [[ ! -s "$resolved" ]] &&
             ! { [[ "$empty_diff_ok" == "true" ]] && [[ "$raw_primary" != "true" ]]; }; then
            _violation="empty"
            _event="plugin.artifact.empty"
        fi

        if [[ -n "$_violation" ]]; then
            if [[ "$_violation" == "absent" ]]; then
                error "scan_plugin_outputs: plugin=$plugin_id declared output missing: $resolved (template: $raw_path)"
            else
                error "scan_plugin_outputs: plugin=$plugin_id declared output is empty (zero bytes): $resolved (template: $raw_path)"
            fi
            emit_event "$_event" \
                "plugin=$plugin_id" \
                "kind=$kind" \
                "expected_path=$resolved" \
                "template=$raw_path"
            # ADR-001 §Fail-closed contract: emit plugin.contract.violated and write
            # synthetic blocking findings.json so the output stage can surface the violation.
            local _stage_id="${stage:-${plugin_id}}"
            emit_event "plugin.contract.violated" \
                "stage=$_stage_id" \
                "plugin=$plugin_id" \
                "expected_path=$resolved" \
                "reason=artifact_missing_or_empty"
            if [[ -n "$state_dir" ]]; then
                mkdir -p "${state_dir}/artifacts"
                local _findings_file="${state_dir}/artifacts/${_stage_id}-${plugin_id}-contract-violated-findings.json"
                jq -n \
                    --arg stage "$_stage_id" \
                    --arg plugin "$plugin_id" \
                    --arg path "$resolved" \
                    --arg violation "$_violation" \
                    '{
                        schema_version: 1,
                        findings: [{
                            id: "artifact-contract-violated",
                            title: ("Plugin contract violated: " + $plugin +
                                    (if $violation == "empty"
                                     then " wrote an empty (zero-byte) required output"
                                     else " declared a required output but wrote no artifact" end)),
                            severity: "blocking",
                            stage: $stage,
                            plugin: $plugin,
                            detail: ("Expected artifact at: " + $path)
                        }]
                    }' > "$_findings_file" 2>/dev/null || true
            fi
            missing=$((missing + 1))
        fi
    done <<< "$paths"

    return $((missing > 0))
}

# ─── plugin_hook_call ───────────────────────────────────────────────────────
# Source the plugin's plugin.sh and call a lifecycle hook by name.
# Plugin functions are isolated by sub-shell to prevent namespace pollution.
plugin_hook_call() {
    local plugin_dir="$1"
    local hook_name="$2"   # run | cleanup (or kind-specific)
    shift 2
    local manifest="$plugin_dir/manifest.yaml"
    local plugin_sh="$plugin_dir/plugin.sh"

    if [[ ! -f "$plugin_sh" ]]; then
        error "plugin_hook_call: plugin.sh missing: $plugin_sh"
        return 1
    fi

    local plugin_id; plugin_id="$(yaml_get "$manifest" "id")"
    local kind; kind="$(yaml_get "$manifest" "kind")"

    # ADR-054 §3 (#1862): the engine states, for exactly the span of one
    # dispatch, which stage this is and which plugin serves it.
    #
    # A plugin IS self-defining about what it is — plugin-bootstrap.sh resolves
    # _ZBUILD_PLUGIN_DIR from its own BASH_SOURCE, and 18 plugins do. It can
    # never be self-defining about which STAGE it is: `review_lenses`
    # (simple.yaml) is served by plugin `review-lens` via role `review_lens` —
    # three namespaces the template alone maps, and under `map:` all six lens
    # members receive that one stage name. Everything keyed to the flow (the
    # timeline, stage_statuses, the per-stage router knobs) needs the stage
    # name; introspection can only ever yield the plugin id.
    #
    # `local -x`, not `export`, for three reasons: it reaches the emit_event
    # calls below, which fire OUTSIDE the plugin subshell (the blank envelope
    # .plugin/.kind of #1705); it reaches the subshell and anything it spawns;
    # and it unsets on return, so stage N's identity cannot bleed into stage
    # N+1 — a plain export would trade a blank field for a stale one.
    #
    # This is the only site that reaches all four dispatch arms. The `map:` arm
    # runs a generated standalone script (strategies/common.sh) the runner
    # cannot export into — but plugin_hook_call is its last line.
    #
    # ZBUILD_PLUGINS_ROOT is deliberately NOT set: it is an operator override
    # every reader spells `${ZBUILD_PLUGINS_ROOT:-<default>}`, and ADR-024 /
    # persona-resolve.sh forbid relying on it as a root. Derive from
    # ZBUILD_PLUGIN_DIR instead.
    #
    # Stage id is $1 post-shift for both hooks — run(stage_id, state_file, ...)
    # and cleanup(stage_id, state_file, scope), ADR-054 §2. Same assumption
    # scan_plugin_outputs already makes below.
    #
    # `:-` is deliberate and deliberately unlike `stage_arg="${1:-}"` below: an
    # empty $1 keeps the ambient stage rather than blanking it. A caller with no
    # stage to name must not erase the one its own caller established — the
    # throttle marker's path is keyed on this value and is written inside the
    # dispatch but read outside it (router-rc-classify.sh:154), so a blank here
    # would split the key across the boundary. scan_plugin_outputs has no such
    # cross-boundary reader and wants the literal argument.
    local -x ZBUILD_CURRENT_STAGE="${1:-${ZBUILD_CURRENT_STAGE:-}}"
    local -x ZBUILD_PLUGIN="$plugin_id"
    local -x ZBUILD_PLUGIN_KIND="$kind"
    local -x ZBUILD_PLUGIN_DIR="$plugin_dir"

    # ADR-058 §2 (#1918): the engine states WHERE this stage may write, for
    # exactly the span of one dispatch. #1809 makes a declared output a write
    # boundary; a boundary cannot be enforced until the permitted areas are
    # defined, and the per-stage scratch area did not exist at all.
    #
    # Same site and same `local -x` as the identity block above, for the same
    # reasons: it is the only site reaching all four dispatch arms (the `map:`
    # arm runs a generated standalone script the runner cannot export into, and
    # this call is that script's last line), and `local -x` restores the prior
    # value AND the prior export attribute on return, so stage N's scratch
    # cannot bleed into stage N+1 and the test harness's sandboxed
    # ZBUILD_ARTIFACT_DIR (scripts/lib/test-helpers.sh) comes back intact.
    #
    # Guarded on `$2` being an ABSOLUTE path — the state_file, post-shift, per
    # ADR-054 §2, the same argument scan_plugin_outputs reads below.
    #
    # Absolute, not merely non-empty, and the difference is load-bearing.
    # `dirname` of a bare relative name is `.`, and by the time a stage
    # dispatches, the runner has cd'd into the RUN'S WORKTREE (ADR-052) — so a
    # relative state_file would put `scratch/` and `artifacts/` inside the
    # repository under change. That is the exact leak this block exists to close,
    # reintroduced by the block itself.
    #
    # It cannot happen from the engine: runner.sh absolutizes state_dir "BEFORE
    # anything derives a path from state_dir" precisely so no caller has to think
    # about this (ADR-052, #1640). A relative or empty `$2` therefore means an
    # ad-hoc caller — the `plugin_hook_call … ""` of
    # tests/unit/plugin-lifecycle-event-balance-test.sh, or the positional
    # `… "arg1" "arg2"` of tests/integration/core-plugin-registry-test.sh — which
    # has no job folder to be inside and must reach the plugin with the
    # environment it has today.
    #
    # Setting TMPDIR is the load-bearing part. scripts/lib/env-scrub.sh
    # wildcard-unsets every ZBUILD_* before each model spawn — with the
    # unset-until-gone loop #1873 added specifically to defeat `local -x`
    # layering at this seam — while TMPDIR is explicitly PRESERVED. It is
    # therefore the only channel that reaches the model. Redirecting it puts the
    # model's own temp writes in bounds and relocates every `${TMPDIR:-/tmp}`
    # consumer in the engine and the plugins with zero plugin edits.
    #
    # ZBUILD_ARTIFACT_DIR is a definition, not a leak fix: the gate plugins test
    # for a live state file first and only fall back to temp when invoked
    # ad-hoc, so their outputs land correctly today. What changes is that the
    # plugin's own fallback and scan_plugin_outputs' `${artifact_dir}`
    # substitution below become the same directory BY CONSTRUCTION, instead of
    # two independent derivations that a caller can silently split.
    if [[ "${2:-}" == /* ]]; then
        local _ws_state_dir; _ws_state_dir="$(dirname "$2")"
        local -x ZBUILD_ARTIFACT_DIR="${_ws_state_dir}/artifacts"

        if ! declare -F stage_scratch_ensure >/dev/null 2>&1; then
            # shellcheck source=../pipeline/stage-scratch.sh
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../pipeline" && pwd)/stage-scratch.sh" 2>/dev/null || true
        fi
        if declare -F stage_scratch_ensure >/dev/null 2>&1; then
            local _ws_scratch
            # Fail-open: an unnameable stage or an uncreatable directory leaves
            # both vars unset and every consumer on the fallback it has today.
            # A stage must not be refused dispatch because scratch was
            # unavailable — that would make a diagnostic convenience a new way
            # for a run to die.
            if _ws_scratch="$(stage_scratch_ensure "$_ws_state_dir" "${ZBUILD_CURRENT_STAGE:-}" "${ZBUILD_MAP_ELEMENT:-}" 2>/dev/null)" \
               && [[ -n "$_ws_scratch" ]]; then
                local -x ZBUILD_STAGE_SCRATCH="$_ws_scratch"
                local -x TMPDIR="$_ws_scratch"
            fi
        fi
    fi

    # ADR-055 §1 (#1826): the engine resolves what this stage DECLARED it needs
    # and states where each artifact is, so a plugin stops hardcoding filenames.
    # Same site and same `local -x` as the identity vars above, for the same two
    # reasons: it is the only site reaching all four dispatch arms (the `map:` arm
    # runs a generated standalone script the runner cannot export into, and this
    # call is that script's last line), and `local -x` unsets on return so stage
    # N's index cannot bleed into stage N+1.
    #
    # Unconditional as of #1825 — the resolved-input index is always built and
    # never declared, so the dispatch is byte-identical to today.
    #
    # plugins_root is derived from plugin_dir (plugins/<kind>/<id>/), not read
    # from ZBUILD_PLUGINS_ROOT — ADR-024 / persona-resolve.sh forbid relying on
    # that override as a root, exactly as the block above says.
    if [[ "$hook_name" == "run" ]]; then
        if ! declare -F _inputs_resolve_stage >/dev/null 2>&1; then
            # shellcheck source=../pipeline/input-resolve.sh
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../pipeline" && pwd)/input-resolve.sh" 2>/dev/null || true
        fi
        if declare -F _inputs_resolve_stage >/dev/null 2>&1; then
            local _ir_proot; _ir_proot="$(cd "$plugin_dir/../.." 2>/dev/null && pwd)"
            local _ir_state="${ZBUILD_STATE_DIR:-}"
            if [[ -n "$_ir_state" && -n "$ZBUILD_CURRENT_STAGE" ]]; then
                # Pre-dispatch: a missing `required: true` input means the stage
                # is never launched — we return before plugin.sh is sourced, so
                # its entrypoint does not run at all.
                #
                # rc=1, not a private code: ADR-054 §4 narrows this boundary to
                # {0,1} and dispatch-rc-guard-test.sh ratchets it. "Which input,
                # from which producer" rides the refusal render and the
                # plugin.run.refused event — the declared channels — exactly as
                # the lockfile-mismatch refusal below does.
                if ! _inputs_check_required "$ZBUILD_CURRENT_STAGE" "$_ir_proot" "$_ir_state" "$manifest"; then
                    emit_event "plugin.$hook_name.refused" "plugin=$plugin_id" "kind=$kind" \
                        "reason=required-input-missing"
                    return 1
                fi
                local -x ZBUILD_STAGE_INPUTS
                ZBUILD_STAGE_INPUTS="$(_inputs_resolve_stage "$ZBUILD_CURRENT_STAGE" "$_ir_proot" "$_ir_state" "$manifest" 2>/dev/null || true)"
            fi
        fi
    fi

    local hook_fn; hook_fn="$(yaml_get "$manifest" "hooks.$hook_name")"
    if [[ -z "$hook_fn" ]]; then
        if [[ "$hook_name" == "cleanup" ]]; then
            # #1823 (ADR-054 §4): an absent OPTIONAL hook had nothing to do and
            # did it — rc 0. The absence is not lost: it rides
            # `plugin.cleanup.absent`, a declared channel, which is what #1828's
            # own acceptance asked for ("distinguishable in the engine's
            # RECORDS"). ADR-056 additionally returned rc=3 for this, justified
            # against ADR-001's "0=ok, 1=recoverable, 2=fatal" — the very table
            # ADR-054 §4 supersedes. Nothing in the engine ever read it.
            #
            # Consumers that need to tell "skipped" from "ran cleanly" — #1829's
            # teardown dispatch and #1830's teardown stage — read the event.
            # Two channels carrying one fact is the defect this contract exists
            # to end, and the rc is the one that cannot be enforced.
            emit_event "plugin.$hook_name.absent" "plugin=$plugin_id" "kind=$kind"
            return 0
        fi
        # Absent required hook: emit refused event and fail.
        emit_event "plugin.$hook_name.refused" "plugin=$plugin_id" "kind=$kind" "reason=hook-not-declared"
        return 1
    fi

    # Pre-source tamper check (#290). Honors ZBUILD_STRICT_PLUGIN_LOCK.
    if ! verify_plugin_for_source "$manifest"; then
        emit_event "plugin.$hook_name.refused" "plugin=$plugin_id" "kind=$kind" "reason=lockfile-mismatch"
        return 1
    fi

    emit_event "plugin.$hook_name.start" "plugin=$plugin_id" "kind=$kind"

    # Run in a subshell to isolate plugin's variables/functions
    (
        # shellcheck disable=SC1090
        source "$plugin_sh"
        if declare -F "$hook_fn" >/dev/null 2>&1; then
            "$hook_fn" "$@"
        else
            echo "plugin_hook_call: function $hook_fn not defined in $plugin_sh" >&2
            exit 1
        fi
    )
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        # #288: after a successful `run`, verify the plugin actually produced
        # the artifacts it declared. Absent evidence IS blocking evidence —
        # emit synthetic findings for each missing output and surface the
        # failure as a non-zero hook exit so the caller can react.
        if [[ "$hook_name" == "run" ]]; then
            # Per ADR-001 hook signature: $@ after shift 2 is (stage_id, state_file, ...).
            local stage_arg="${1:-}"
            local state_file_arg="${2:-}"
            if ! scan_plugin_outputs "$plugin_dir" "$state_file_arg" "$stage_arg"; then
                emit_event "plugin.$hook_name.artifact_check_failed" \
                    "plugin=$plugin_id" "kind=$kind"
                return 1
            fi
        fi
        emit_event "plugin.$hook_name.complete" "plugin=$plugin_id" "kind=$kind"
    else
        emit_event "plugin.$hook_name.error" "plugin=$plugin_id" "kind=$kind" "rc=$rc"
    fi

    # #1823 (ADR-054 §4): the plugin's raw status passes through UNCHANGED, and
    # deliberately so during versioned coexistence. A v1 plugin has no result
    # field in which to say what its rc says — `plan`'s rc=10 IS its only way to
    # report `scope_too_large` — so narrowing here would destroy the meaning of
    # every unmigrated plugin at once. The narrowing is gated on the result
    # contract at the dispatch boundary instead (see cycle_dispatch_stage), and
    # becomes unconditional in #1850 when the last v1 reader is dropped.
    return $rc
}
