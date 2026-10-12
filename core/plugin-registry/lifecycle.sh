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

# #1809 (ADR-058 C9): declared-output path resolution is shared with
# core/pipeline/write-boundary.sh so the artifact scanner and the write-boundary
# classifier can never disagree about where a declared output lives.
# shellcheck source=output-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output-paths.sh"
# shellcheck source=write-ownership.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/write-ownership.sh"
# shellcheck source=attempt-archive.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/attempt-archive.sh"
# shellcheck source=../../scripts/lib/stage-dispatch-mark.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/stage-dispatch-mark.sh"

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
    # #2252: `probe` answers present-or-not with no events, findings or marker.
    local probe="${4:-}"
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
    # #511 F2: respect `required: false` on outputs. Without this, the scanner
    # would flag a legitimately optional artifact as a fail-closed contract
    # violation. (test_failures_summary was the original example; ADR-055 §9
    # since made it `required: true` — a summary is published on every terminal
    # verdict, so its absence IS a violation now.)
    local paths
    paths="$(_registry_output_path_rows "$manifest")"

    [[ -z "$paths" ]] && return 0

    local missing=0
    local raw_path raw_primary resolved _violation _event
    while IFS=$'\t' read -r raw_path raw_primary; do
        [[ -z "$raw_path" ]] && continue
        resolved="$(_registry_resolve_output_path "$raw_path" "$state_dir" "$artifact_dir")"

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

        if [[ -n "$_violation" && "$probe" == "probe" ]]; then
            return 1
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
                # #1809: file-backed marker so runner_read_stage_disposition (a separate
                # process under map:) can detect the violation and return broken.
                mkdir -p "${state_dir}/runtime"
                touch "${state_dir}/runtime/artifact-contract-violated" 2>/dev/null || true
            fi
            missing=$((missing + 1))
        fi
    done <<< "$paths"

    return $((missing > 0))
}

# ─── _lc_owned_by_others_deny <state_dir> <stage> (#2189) ────────────────────
# One absolute path per line: every file a stage OTHER than <stage> reported
# owning (artifacts/stage-reports.json). Empty when nothing is owned.
_lc_owned_by_others_deny() {
    local rec="${1:-}/artifacts/stage-reports.json" me="${2:-}"
    [[ -s "$rec" ]] || return 0
    # Read without a fork: nothing owned (most runs) needs no jq at all.
    local _body; _body="$(<"$rec")"
    [[ "$_body" == *'"owned_files"'* ]] || return 0
    jq -r --arg me "$me" --arg root "${ZBUILD_REPO_ROOT:-.}" '
        [(.owned_files // {}) | to_entries[] | select(.key != $me) | .value[] | "\($root)/\(.)"]
        | unique[]' <<< "$_body" 2>/dev/null
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

    # ADR-068 §8: mark when this run of the stage started, FIRST — before any
    # refusal below can return — so a run that writes no result, refused or
    # not, is never credited with the previous run's (stage_result_is_current).
    [[ "$hook_name" == "run" ]] && stage_dispatch_mark "${2:-}" "${1:-}"

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
    # #1706 (ADR-054 §3.1): the unit's own name — the stage, or <stage>.<element>
    # for a map member — for this dispatch only. The element is consumed here, so
    # a stage dispatched from inside the member is named by its own stage.
    local -x ZBUILD_UNIT="${ZBUILD_CURRENT_STAGE}${ZBUILD_UNIT_ELEMENT:+.${ZBUILD_UNIT_ELEMENT}}"
    local -x ZBUILD_UNIT_ELEMENT=""
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

        # #2022: the acceptance TESTFILES belong to the stage that AUTHORS them.
        # Every other spawn is denied Edit() on them, so build cannot rewrite an
        # assertion to agree with its own implementation. Derived from the role
        # the plugin declares, never from a stage id: naming `build` here would
        # be a stage naming a stage, the shape #1767 removed from routing.
        # core/router/permissions.sh renders the rules; the decision is here.
        local -x ZBUILD_PERMISSION_DENY_EDIT=""
        # #2170: `$1` here is the STAGE ID — the function `shift 2`s its
        # plugin_dir/hook_name arguments away above. Looked up on the stage id
        # the role was always empty, so the author was denied its own testfiles
        # (invisible while the rule rendered as `Edit(/abs)`, #2163).
        # #2189: files ANOTHER stage reported owning (test-author reports the
        # testfiles it authored) — from the run's stage-reports record, never
        # design.md by path and never a role name. The owner is not denied.
        ZBUILD_PERMISSION_DENY_EDIT+="$(_lc_owned_by_others_deny "$_ws_state_dir" "${1:-}")"
        [[ -n "$ZBUILD_PERMISSION_DENY_EDIT" ]] && ZBUILD_PERMISSION_DENY_EDIT+=$'\n'

        # #2174: write ownership from the manifests (write-ownership.sh) —
        # other plugins' declared outputs, and the repo unless declared.
        _lc_other_outputs_deny "$plugin_dir" "$_ws_state_dir"   # parent shell: fills the memo
        ZBUILD_PERMISSION_DENY_EDIT+="$_LC_DENY_OUT"
        local _lc_wr; _lc_wr="$(manifest_index_get "$manifest" capabilities.writes_repository 2>/dev/null)" \
            || _lc_wr="$(yaml_get "$manifest" "capabilities.writes_repository" 2>/dev/null || true)"
        if [[ "${_lc_wr%$'\n'}" != "true" ]]; then
            _lc_repo_entries_deny "${ZBUILD_REPO_ROOT:-.}"
            ZBUILD_PERMISSION_DENY_EDIT+="$_LC_DENY_OUT"
        fi

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

        # #2024: this seam records that a stage STARTED. It does not record a
        # process group, and the distinction is the whole point.
        #
        # It used to write `<stage>.pgid` from `$$`, which conflated two jobs.
        # As a process handle it was inert: a stage is a bash function call, so
        # no group exists at this seam and `$$` names the ENGINE's group, which
        # teardown then skipped — correctly, since signalling your own group
        # takes the runner down. But as a STARTED MARKER it was load-bearing:
        # `stage_statuses` is written only when a stage completes, so a stage
        # killed mid-flight is known to teardown by this file alone.
        #
        # One file could not honestly be both. Groups are registered by whoever
        # creates one (zbuild_pg_register); this writes `<stage>.started`, and
        # nothing reads it as a pgid. Do not reinstate a `.pgid` write here: any
        # pgid observable at dispatch cannot be signalled from inside the run.
        if [[ "$hook_name" == "run" && -n "${ZBUILD_CURRENT_STAGE:-}" ]]; then
            local _st_dir="${_ws_state_dir}/runtime/stages"
            if mkdir -p "$_st_dir" 2>/dev/null; then
                # One path component, so no stage name can climb out of runtime/.
                local _st_key="${ZBUILD_CURRENT_STAGE//[^A-Za-z0-9_-]/_}"
                # Fail-open: a stage is never refused dispatch over bookkeeping.
                : > "${_st_dir}/${_st_key}.started" 2>/dev/null || true
            fi
        fi

        # #1809 (ADR-058 C9): load the write-boundary enforcer lazily, same
        # pattern as stage-scratch.sh above. Fail-open: an unloadable module
        # leaves the mark unset and write_boundary_check returns 0 immediately.
        if ! declare -F write_boundary_mark >/dev/null 2>&1; then
            # shellcheck source=../pipeline/write-boundary.sh
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../pipeline" && pwd)/write-boundary.sh" 2>/dev/null || true
        fi
    fi

    # ADR-055 / ADR-067 §8 (amended): every stage gets the same three blocks —
    # what comes from the repository, the previous work, and the rules for the
    # stage — and the index of every stage's latest output, its own included.
    # Nothing is checked against what a stage "needs": there is no such list, and
    # a stage that finds something it needs missing says so in its own result.
    #
    # This is the only site reaching all four dispatch arms (the `map:` arm runs
    # a generated standalone script the runner cannot export into, and this call
    # is that script's last line), and `local -x` unsets on return so stage N's
    # blocks cannot bleed into stage N+1.
    #
    # plugins_root is derived from plugin_dir (plugins/<kind>/<id>/), not read
    # from ZBUILD_PLUGINS_ROOT — ADR-024 / persona-resolve.sh forbid relying on
    # that override as a root.
    if [[ "$hook_name" == "run" ]]; then
        if ! declare -F _inputs_resolve_stage >/dev/null 2>&1; then
            # shellcheck source=../pipeline/input-resolve.sh
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../pipeline" && pwd)/input-resolve.sh" 2>/dev/null || true
        fi
        if ! declare -F stage_blocks_write >/dev/null 2>&1; then
            # shellcheck source=../../scripts/lib/stage-prompt.sh
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/stage-prompt.sh" 2>/dev/null || true
        fi
        local _ir_proot; _ir_proot="$(cd "$plugin_dir/../.." 2>/dev/null && pwd)"
        local _ir_state="${ZBUILD_STATE_DIR:-}"
        if [[ -n "$_ir_state" && -n "${ZBUILD_CURRENT_STAGE:-}" ]] && declare -F _inputs_resolve_stage >/dev/null 2>&1; then
            local -x ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS
            # Built here, in this shell, so the two readers below — each in its
            # own subshell — share one producer index instead of each building it.
            _inputs_build_producer_index "$_ir_proot" "$_ir_state" 2>/dev/null || true
            ZBUILD_STAGE_INPUTS="$(_inputs_resolve_stage "$ZBUILD_CURRENT_STAGE" "$_ir_proot" "$_ir_state" 2>/dev/null || true)"
            if declare -F stage_blocks_write >/dev/null 2>&1; then
                local _sb_repo="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
                ZBUILD_STAGE_BLOCKS="$(stage_blocks_write "$ZBUILD_CURRENT_STAGE" "$_ir_state" "$manifest" \
                    "$_ir_proot" "$ZBUILD_STAGE_INPUTS" "$_sb_repo" 2>/dev/null || true)"
                # What Previous work carried, so a run's record says what each
                # stage was given (#2124).
                if [[ -s "${ZBUILD_STAGE_BLOCKS:-}/previous-work.md" ]]; then
                    local _pw_n=0 _pw_f=0 _pw_l
                    while IFS= read -r _pw_l; do
                        [[ "$_pw_l" == "### "*" (verdict: "* ]] || continue
                        _pw_n=$((_pw_n + 1))
                        [[ "$_pw_l" == *"(verdict: fail)"* || "$_pw_l" == *"(verdict: failed)"* ]] && _pw_f=$((_pw_f + 1))
                    done < "$ZBUILD_STAGE_BLOCKS/previous-work.md"
                    emit_event "stage.previous_work.written" "stage=$ZBUILD_CURRENT_STAGE" \
                        "stages=$_pw_n" "failing=$_pw_f" 2>/dev/null || true
                fi
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

    # #1809 (ADR-058 C9): mark the dispatch start so write_boundary_check can
    # find files written during this dispatch. Fail-open: missing function = no-op.
    if declare -F write_boundary_mark >/dev/null 2>&1; then
        # Keyed on stage + map element so nested, map and parallel dispatches
        # against one state file do not share (and re-stamp) one window.
        write_boundary_mark "${2:-}" "${1:-}" "${ZBUILD_MAP_ELEMENT:-}" || true
    fi

    # #2186: what the declared outputs were before this run, so the attempt
    # record can say which ones the run actually changed. Fail-open.
    local _lc_outputs_before=""
    if [[ "$hook_name" == "run" ]] && declare -F attempt_outputs_fingerprint >/dev/null 2>&1; then
        _lc_outputs_before="$(attempt_outputs_fingerprint "$plugin_dir" "${2:-}" 2>/dev/null || true)"
    fi

    emit_event "plugin.$hook_name.start" "plugin=$plugin_id" "kind=$kind"

    # Run in a subshell to isolate plugin's variables/functions.
    # For the "run" hook: arm a per-dispatch watchdog so a hung stage is killed at
    # stage_timeout_s (issue #1801, SPEC-1/SPEC-2). Precedence: template
    # _TPL_STAGE_TIMEOUT_S_<stage> > ZBUILD_STAGE_TIMEOUT_S env > 5400 s default.
    local rc=0
    if [[ "$hook_name" == "run" ]]; then
        if ! declare -F zbuild_pg_kill >/dev/null 2>&1; then
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/proc-group.sh" 2>/dev/null || true
        fi
        local _lc_stage_safe="${ZBUILD_CURRENT_STAGE//-/_}"
        local _lc_to_var="_TPL_STAGE_TIMEOUT_S_${_lc_stage_safe}"
        local _lc_hook_to="${!_lc_to_var:-}"
        [[ "$_lc_hook_to" =~ ^[0-9]+$ && "$_lc_hook_to" -gt 0 ]] || _lc_hook_to="${ZBUILD_STAGE_TIMEOUT_S:-5400}"
        [[ "$_lc_hook_to" =~ ^[0-9]+$ && "$_lc_hook_to" -gt 0 ]] || _lc_hook_to=5400
        local _lc_hook_pid _lc_wd_pid _lc_m_before=0
        [[ "$-" == *m* ]] && _lc_m_before=1
        set -m
        (
            # Always clear monitor mode: the hook subshell is already in its own
            # process group (created by set -m + & above). Any background job the
            # hook spawns must stay in that group so kill -KILL -- -<pgid> reaches
            # them. If the caller had set -m (e.g. _runner_dispatch_always_run's
            # outer subshell), the hook would inherit it and its children would get
            # their own groups, escaping the KILL (#2333 SPEC-6b).
            set +m
            # shellcheck disable=SC1090
            source "$plugin_sh"
            if declare -F "$hook_fn" >/dev/null 2>&1; then
                "$hook_fn" "$@"
            else
                echo "plugin_hook_call: function $hook_fn not defined in $plugin_sh" >&2
                exit 1
            fi
        ) &
        _lc_hook_pid=$!
        ( set +m; sleep "$_lc_hook_to"; zbuild_pg_kill "$_lc_hook_pid" 10 2>/dev/null || true ) &
        _lc_wd_pid=$!
        set +m
        # Restore runner's monitor mode: set +m above always clears it, even when
        # ZBUILD_RUNNER_JOB_CONTROL=1 had it enabled before this call.
        (( _lc_m_before == 1 )) && set -m
        wait "$_lc_hook_pid" 2>/dev/null; rc=$?
        # #2333: the group leader exiting does not mean its group members did.
        # A child that ignored TERM would survive if the watchdog is cancelled before
        # it delivers KILL, so KILL the whole group now.
        kill -KILL -- -"$_lc_hook_pid" 2>/dev/null || true
        declare -F zbuild_pg_kill >/dev/null 2>&1 && zbuild_pg_kill "$_lc_wd_pid" 1 2>/dev/null || true
        wait "$_lc_wd_pid" 2>/dev/null || true
        if (( rc == 143 || rc == 137 )); then
            emit_event "plugin.run.timed_out" "plugin=$plugin_id" "kind=$kind" \
                "stage=${ZBUILD_CURRENT_STAGE:-}" "timeout_s=${_lc_hook_to}" \
                "disposition=timed_out" 2>/dev/null || true
        fi
    else
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
        rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        # #288: after a successful `run`, verify the plugin actually produced
        # the artifacts it declared. Absent evidence IS blocking evidence —
        # emit synthetic findings for each missing output and surface the
        # failure as a non-zero hook exit so the caller can react.
        if [[ "$hook_name" == "run" ]]; then
            # Per ADR-001 hook signature: $@ after shift 2 is (stage_id, state_file, ...).
            local stage_arg="${1:-}"
            local state_file_arg="${2:-}"
            # #2252: a stage that SAYS it did not finish (timed_out, out_of_turns,
            # interrupted) is expected to be missing outputs — failing it for them
            # overwrote its retryable word with `broken` and halted the run
            # (#1844: design timed out, and the run ended instead of retrying).
            # Its own word stands; the retry rule decides what happens next.
            # Read the stage's word only when an output IS missing (a quiet
            # probe first): the read costs several jq calls per dispatch, and a
            # probe that passes means there is nothing for the full check to say.
            local _lcr_state="" _lcr_contract="" _lcr_verdict="" _lcr_disp="" _lcr_reason="" \
                  _lcr_viol="" _lcr_path="" _lcr_present="" _lc_unfinished="" _lc_missing=0
            scan_plugin_outputs "$plugin_dir" "$state_file_arg" "$stage_arg" probe 2>/dev/null || _lc_missing=1
            if (( _lc_missing )) && declare -F _verdict_read_result >/dev/null 2>&1 \
                    && declare -F disposition_unfinished >/dev/null 2>&1 \
                    && [[ -n "$state_file_arg" ]]; then
                _verdict_read_result "$(dirname "$state_file_arg")" "$manifest" "$stage_arg" 0 _lcr 2>/dev/null || true
                disposition_unfinished "${_lcr_disp:-}" && _lc_unfinished="$_lcr_disp"
            fi
            if [[ -n "$_lc_unfinished" ]]; then
                emit_event "plugin.$hook_name.artifact_check_skipped" "plugin=$plugin_id" \
                    "kind=$kind" "disposition=$_lc_unfinished"
            elif (( _lc_missing )) && ! scan_plugin_outputs "$plugin_dir" "$state_file_arg" "$stage_arg"; then
                emit_event "plugin.$hook_name.artifact_check_failed" \
                    "plugin=$plugin_id" "kind=$kind"
                # A dispatch that STARTED must also END. This arm and the
                # write-boundary arm below both `return 1` from inside the rc=0
                # branch, so neither reaches the `complete` emit nor the `else`
                # arm's `error` emit — the start was left without a partner and
                # the run's own log could not say which stage died (run
                # 33899683569: 54 start, 48 complete, 5 error). `reason=` is a
                # data field on an already-declared event name, so the event-NAME
                # set is unchanged and the sequence goldens are untouched.
                emit_event "plugin.$hook_name.error" "plugin=$plugin_id" \
                    "kind=$kind" "rc=1" "reason=artifact-check-failed"
                return 1
            fi
            # #1809 (ADR-058 C9): sweep for writes outside declared outputs and
            # engine-owned areas. Fail-open: unloaded module = write_boundary_check
            # undefined = this arm is unreachable.
            if declare -F write_boundary_check >/dev/null 2>&1; then
                _ZBUILD_WB_ACTION=""
                if ! write_boundary_check "$plugin_dir" "$state_file_arg" "$stage_arg" \
                        "${ZBUILD_MAP_ELEMENT:-}"; then
                    # See the artifact-check arm above: same missing-terminal
                    # defect. write_boundary_violation_recorded has already named
                    # the offending path on its own three channels; this event
                    # is what closes the start/end pair.
                    local _wb_reason="write-boundary-violation"
                    [[ "${_ZBUILD_WB_ACTION:-}" == "reverted" ]] && _wb_reason="write-boundary-reverted"
                    emit_event "plugin.$hook_name.error" "plugin=$plugin_id" \
                        "kind=$kind" "rc=1" "reason=$_wb_reason"
                    return 1
                fi
            fi
        fi
        emit_event "plugin.$hook_name.complete" "plugin=$plugin_id" "kind=$kind"
    else
        emit_event "plugin.$hook_name.error" "plugin=$plugin_id" "kind=$kind" "rc=$rc"
    fi

    # #2183: keep THIS attempt's declared outputs before the next dispatch can
    # overwrite them. After the rc branches, so a FAILED attempt — the one whose
    # record matters most — is archived too. Fail-open by construction.
    if [[ "$hook_name" == "run" ]] && declare -F attempt_archive_outputs >/dev/null 2>&1; then
        attempt_archive_outputs "$plugin_dir" "${2:-}" "${1:-}" "$rc" "$_lc_outputs_before" 2>/dev/null || true
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
