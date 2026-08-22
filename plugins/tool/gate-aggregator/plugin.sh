#!/usr/bin/env bash
# plugins/tool/gate-aggregator/plugin.sh — Gate Aggregator (ADR-040 §2, #1137)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Collapses the mechanical gate stages into ONE convergence verdict — the single
# merge-blocking construct in the decomposed pipeline (ADR-040 §5). Reads each
# must-pass gate's recorded result artifact from the shared artifacts dir and
# aggregates: pass IFF every gate is PRESENT, well-formed, and verdict ∈
# {pass, skip}. FAIL-CLOSED (ADR-019, re-expressed by ADR-040): a missing /
# malformed REQUIRED gate, or any fail/error verdict → verdict=fail. Writes the
# verdict to gate-aggregator-result.json and ALWAYS returns 0 (verdict-in-
# artifact, mirrors shape-floor).
#
# Hook prefix: gate_aggregator_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_GATE_AGGREGATOR_LOADED:-}" ]] && return 0
_ZBUILD_GATE_AGGREGATOR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_GA_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_GA_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# Manifest libs for ROSTER-DRIVEN discovery (ADR-040 §2): the must-pass set is
# derived at runtime from the cycle members' own `convergence:` markers — no
# hardcoded gate list — so adding/removing a gate needs NO edit to this plugin.
# shellcheck source=../../../scripts/lib/manifest-graph.sh
source "$_GA_ROOT/scripts/lib/manifest-graph.sh" 2>/dev/null || true
# yaml_get (top-level + single-level-nested scalar reader): convergence / role /
# provides.artifact_type. manifest-validation.sh is a leaf (sources nothing).
# shellcheck source=../../../core/plugin-registry/manifest-validation.sh
source "$_GA_ROOT/core/plugin-registry/manifest-validation.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_ga_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# Legacy fallback must-pass set (ADR-040 §2, REGRESSION SAFETY). Used ONLY when
# no cycle roster is in scope — i.e. ZBUILD_CYCLE_ID / _TPL_CYCLE_STAGES_<id> are
# ABSENT (the aggregator invoked standalone with result files in a dir but no
# cycle env, as the unit tests do). The cycle path (see _ga_build_roster) learns
# the must-pass set from the present `convergence: gate` members instead.
# Format: "<gate_name>:<result_filename>", stable aggregation/reporting order.
_GA_LEGACY_MUST_PASS=(
    "suite:test-results.json"
    "shape-floor:shape-floor-result.json"
    "acceptance-gate:acceptance-gate-result.json"
    "lint:lint-result.json"
    "coverage:coverage-result.json"
    "mutation:mutation-result.json"
    "secret-scan:secret-scan-result.json"
)

# Populated by _ga_build_roster: "<name>:<result_filename>" entries (the order
# is the deterministic aggregation/reporting order). _GA_ROSTER_MODE records
# whether the roster came from the live cycle or the legacy fallback.
_GA_ROSTER=()
_GA_ROSTER_MODE=""

# ─── _ga_member_manifest / _ga_manifest_result_file ──────────────────────────
# Thin wrappers over the SHARED roster-resolution primitives in manifest-graph.sh
# (manifest_graph_resolve_member / manifest_graph_result_filename), so the
# gate-aggregator and the cycle engine's generic member-disposition contract
# resolve members identically (id-match then role binding; artifact_type then
# primary-output basename). Kept as named locals for readability at call sites.
_ga_member_manifest()      { manifest_graph_resolve_member "$1" "$2"; }
_ga_manifest_result_file() { manifest_graph_result_filename "$1"; }

# ─── _ga_build_roster <plugins_root> ─────────────────────────────────────────
# ADR-040 §2 roster-driven must-pass discovery. When a cycle is in scope
# (ZBUILD_CYCLE_ID set by cycle-orchestrator + _TPL_CYCLE_STAGES_<id> exported by
# template.sh), the must-pass set is every cycle member whose manifest declares
# `convergence: gate` — EXCLUDING the aggregator itself and any advisory/absent
# member. Otherwise FALL BACK to the legacy hardcoded set (cycle-less invocation,
# e.g. unit tests). Populates _GA_ROSTER + _GA_ROSTER_MODE.
_ga_build_roster() {
    local plugins_root="$1"
    _GA_ROSTER=()
    local cyc="${ZBUILD_CYCLE_ID:-}" stages=""
    if [[ -n "$cyc" ]]; then
        local stages_var="_TPL_CYCLE_STAGES_${cyc//-/_}"
        stages="${!stages_var:-}"
    fi
    if [[ -z "$stages" ]]; then
        _GA_ROSTER=("${_GA_LEGACY_MUST_PASS[@]}")
        _GA_ROSTER_MODE="fallback"
        return 0
    fi
    local IFS_save="$IFS"; IFS=','
    # shellcheck disable=SC2206
    local -a members=($stages)
    IFS="$IFS_save"
    local member manifest conv file
    for member in "${members[@]}"; do
        [[ -z "$member" ]] && continue
        [[ "$member" == "gate-aggregator" ]] && continue   # never aggregate self
        manifest="$(_ga_member_manifest "$plugins_root" "$member")" || continue
        conv="$(yaml_get "$manifest" "convergence" 2>/dev/null)"
        [[ "$conv" == "gate" ]] || continue                # advisory/absent excluded
        file="$(_ga_manifest_result_file "$manifest")" || continue
        [[ -z "$file" ]] && continue
        _GA_ROSTER+=("$member:$file")
    done
    # Safety net: a cycle that resolved to zero gates must NOT vacuously pass —
    # fall back to the legacy set so a misconfiguration fails closed, not open.
    if [[ ${#_GA_ROSTER[@]} -eq 0 ]]; then
        _GA_ROSTER=("${_GA_LEGACY_MUST_PASS[@]}")
        _GA_ROSTER_MODE="fallback"
    else
        _GA_ROSTER_MODE="cycle"
    fi
    return 0
}

# ─── _ga_gate_detail <name> <result_path> ────────────────────────────────────
# B2 (ADR-040): render one failing gate's actionable detail for the consolidated
# gate→build feedback. Best-effort jq extraction of the common result fields
# (summary / reason / failures[] / findings[] / test_output); a missing artifact
# is a fail-closed "did not run" note.
# #1244: the suite gate (test-results.json) records failing-test detail in
# `.test_output` (already sanitized + ≤10KB by the test plugin), NOT in any of
# the list fields — harvest it too so the gate→build feedback lists WHICH tests
# failed instead of the empty "no structured detail" fallback. Repo-agnostic: any
# gate that writes `.test_output` benefits; gates that don't are unaffected.
_ga_gate_detail() {
    local name="$1" path="$2" reason summary fails finds test_output f
    printf '## %s\n\n' "$name"
    if [[ ! -f "$path" ]]; then
        printf -- '- artifact missing: the gate did not run (fail-closed).\n\n'
        return 0
    fi
    summary="$(jq -r '.summary // empty' "$path" 2>/dev/null)"
    reason="$(jq -r '.reason // empty' "$path" 2>/dev/null)"
    [[ -n "$summary" ]] && printf -- '- summary: %s\n' "$summary"
    [[ -n "$reason" ]] && printf -- '- reason: %s\n' "$reason"
    fails="$(jq -r '(.failures // [])[]? | tostring' "$path" 2>/dev/null)"
    if [[ -n "$fails" ]]; then
        printf -- '- failures:\n'
        while IFS= read -r f; do [[ -n "$f" ]] && printf '    - %s\n' "$f"; done <<< "$fails"
    fi
    finds="$(jq -rc '(.findings // [])[]?' "$path" 2>/dev/null)"
    if [[ -n "$finds" ]]; then
        printf -- '- findings:\n'
        while IFS= read -r f; do [[ -n "$f" ]] && printf '    - %s\n' "$f"; done <<< "$finds"
    fi
    test_output="$(jq -r '.test_output // empty' "$path" 2>/dev/null)"
    if [[ -n "$test_output" ]]; then
        printf -- '- test output:\n'
        printf '```\n%s\n```\n' "$test_output"
    fi
    [[ -z "$summary$reason$fails$finds$test_output" ]] && printf -- '- verdict=fail (no structured detail in artifact).\n'
    printf '\n'
}

# ─── _ga_read_gate_verdict ────────────────────────────────────────────────────
# Reads one gate's recorded verdict from its result artifact. Echoes a status
# token for the aggregate:
#   pass|skip      → the gate is satisfied (skip = ran, nothing to check)
#   advisory       → verdict=fail BUT the gate declared disposition=advisory
#                    (generic member-disposition contract, ADR-021): a non-
#                    blocking failure (e.g. an infra flake) that must NOT block
#                    convergence. Satisfied for aggregation.
#   fail           → the gate blocked (verdict=fail, disposition terminal /
#                    recoverable / absent — the latter fail-closed)
#   missing        → artifact absent (fail-closed: the gate did not run)
#   malformed      → artifact present but unparseable / no usable verdict
# The test stage's "error" verdict (interrupted / unparseable suite) maps to
# fail — an indeterminate suite must never satisfy convergence.
# Usage: _ga_read_gate_verdict <result_path>
_ga_read_gate_verdict() {
    local result_path="$1"
    [[ -f "$result_path" ]] || { echo "missing"; return 0; }
    local v
    v="$(jq -r '.verdict // empty' "$result_path" 2>/dev/null)" || { echo "malformed"; return 0; }
    case "$v" in
        pass | skip) echo "$v" ;;
        fail | error)
            # disposition=advisory demotes a fail to a non-blocking status so an
            # infra-flake never blocks convergence (recoverable/terminal/absent
            # stay blocking — recoverable drives another build iteration).
            local disp
            disp="$(jq -r '.disposition // ""' "$result_path" 2>/dev/null || echo "")"
            if [[ "$disp" == "advisory" ]]; then echo "advisory"; else echo "fail"; fi
            ;;
        *)           echo "malformed" ;;
    esac
}

# ─── gate_aggregator_run ──────────────────────────────────────────────────────
# Aggregates the must-pass gate verdicts into a single convergence verdict.
# Writes gate-aggregator-result.json and ALWAYS returns 0.
# Args: $1 = stage_id, $2 = state_file
gate_aggregator_run() {
    local stage_id="${1:-gate-aggregator}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-gate-aggregator-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/gate-aggregator-result.json"
    local feedback_path="$artifacts_dir/gate-feedback.md"
    # #1219 (ADR-045/ADR-046): the FOCUSED design-rooted feedback the
    # build_test_cycle route_back carries to the design_verify_cycle on a
    # route_<target> verdict. Persists across the rewind (per-run artifacts dir is
    # shared and durable) → design reads it on replay.
    local design_feedback_path="$artifacts_dir/design-feedback.md"

    # ADR-040 §2: discover the must-pass roster (cycle-driven or legacy fallback).
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_GA_ROOT/plugins}"
    _ga_build_roster "$plugins_root"

    local verdict="pass"
    local failed=()         # gate names that blocked convergence
    local failed_files=()   # parallel to failed[]: the result filename
    local gate_pairs=()     # "name=status" for the artifact's gates map
    local entry name file status

    for entry in "${_GA_ROSTER[@]}"; do
        name="${entry%%:*}"
        file="${entry#*:}"
        status="$(_ga_read_gate_verdict "$artifacts_dir/$file")"
        gate_pairs+=("$name=$status")
        case "$status" in
            pass | skip | advisory) : ;;          # satisfied (advisory = non-blocking fail)
            *) verdict="fail"; failed+=("$name"); failed_files+=("$file") ;; # fail|missing|malformed
        esac
    done

    # ─── #1219 (ADR-045): DESIGN-ROOTED route verdict ─────────────────────────
    # Roster-driven (NO plugin vocabulary): read each FAILED gate's generic
    # `route_target` scalar; the FIRST non-empty wins. When set, the aggregate
    # verdict becomes `route_<target>` (e.g. route_design). route_<target> != pass
    # so the cycle exit_when never falsely converges and merge (verdict != pass →
    # PR path) never auto-merges — the runner owns the bounded rewind. The
    # aggregator stays the single convergence authority (ADR-040 §5): it merely
    # gains a route verdict alongside pass/fail.
    #
    # Selection is deterministic: ROSTER ORDER, first non-empty wins. When the
    # failed gates name more than one distinct target the loser used to be
    # dropped with no log, no event and no record that a conflict existed
    # (#1757), so the full scan below runs to completion and emits
    # gate_aggregator.route_conflict naming every target it saw. No target is
    # emitted today besides "design", so the event is expected to stay silent —
    # it exists so that the day a second one appears, it is visible.
    # _ga_rt_of[] caches each failed gate's target by its failed[] index: this is
    # the only place the artifacts are read for it, and the partition below reuses
    # the cache rather than re-shelling jq per gate.
    local _ga_route_target="" _rt_i _rt
    local _ga_rt_of=() _ga_route_seen=() _ga_seen_i
    if [[ "$verdict" == "fail" ]]; then
        for _rt_i in "${!failed[@]}"; do
            _rt="$(jq -r '.route_target // empty' "$artifacts_dir/${failed_files[$_rt_i]}" 2>/dev/null || true)"
            [[ "$_rt" == "null" ]] && _rt=""
            _ga_rt_of[$_rt_i]="$_rt"
            if [[ -z "$_rt" ]]; then continue; fi
            # `if`, not `[[ ]] && x` — the latter returns 1 once the target is
            # already set, which is a live abort should this ever be sourced
            # under errexit.
            if [[ -z "$_ga_route_target" ]]; then _ga_route_target="$_rt"; fi
            # An ARRAY of distinct targets, not a space-joined string: a compound
            # target name ("re plan") must count as one target, not two.
            local _ga_dup=0
            for _ga_seen_i in ${_ga_route_seen[@]+"${_ga_route_seen[@]}"}; do
                [[ "$_ga_seen_i" == "$_rt" ]] && { _ga_dup=1; break; }
            done
            [[ $_ga_dup -eq 0 ]] && _ga_route_seen+=("$_rt")
        done
        [[ -n "$_ga_route_target" ]] && verdict="route_${_ga_route_target}"
        if [[ ${#_ga_route_seen[@]} -gt 1 ]]; then
            _ga_emit "gate_aggregator.route_conflict" \
                "targets=${_ga_route_seen[*]}" "selected=$_ga_route_target"
        fi
    fi

    # Build the gates {name: status} object and the failed[] array via jq so the
    # JSON is well-formed regardless of gate-name content.
    local gates_json failed_json
    gates_json="$(printf '%s\n' "${gate_pairs[@]}" \
        | jq -R 'select(length>0) | (index("=") ) as $i | {(.[:$i]): .[$i+1:]}' \
        | jq -sc 'add // {}')"
    if [[ ${#failed[@]} -gt 0 ]]; then
        failed_json="$(printf '%s\n' "${failed[@]}" | jq -R . | jq -sc .)"
    else
        failed_json="[]"
    fi

    # Mirror route_target into the artifact ONLY when set (byte-shape-identical to
    # today on the pass/plain-fail paths).
    jq -n --arg v "$verdict" --argjson g "$gates_json" --argjson f "$failed_json" \
        --arg rt "$_ga_route_target" \
        '{"verdict":$v,"gates":$g,"failed":$f}
         + (if $rt=="" then {} else {"route_target":$rt} end)' | atomic_write "$result_path"

    # ─── Feedback payloads ────────────────────────────────────────────────────
    # The failure set is MIXED in general, so the two payloads are INDEPENDENT,
    # not a three-way choice (#1757). Partition failed[] by each gate's own
    # route_target and write whichever payloads have members:
    #   routed[]   (route_target == the winning target) → design-feedback.md,
    #              the FOCUSED payload the route_back rewind carries to the
    #              design_verify_cycle (#1219, ADR-045/ADR-046).
    #   residual[] (everything else)                    → gate-feedback.md, the
    #              consolidated gate→build payload (B2, ADR-040).
    #
    # Previously a route_<tgt> verdict took an `elif` that wrote design-feedback.md
    # and `rm -f`'d gate-feedback.md unconditionally. One design-rooted gate
    # (e.g. shape-floor's out-of-scope escalation) therefore SUPPRESSED the
    # build-facing detail for every build-fixable gate failing beside it — a
    # failing test suite and a `tautology:SPEC-n` (which by #1583 carries NO
    # route_target precisely so it reaches build) both went to /dev/null, and the
    # cycle spun on empty diffs because build was never told what was wrong.
    #
    # A gate carrying a non-winning route_target lands in residual[] rather than
    # being dropped: only "design" is emitted today, so the set is empty in
    # practice, and silently discarding a failure is the bug being fixed.
    # On a plain fail (no route_target anywhere) routed[] is empty and
    # residual[] == failed[] — byte-identical to the previous else branch.
    local _i
    local routed=() routed_files=() residual=() residual_files=()
    for _i in "${!failed[@]}"; do
        _rt="${_ga_rt_of[$_i]:-}"
        if [[ -n "$_ga_route_target" && "$_rt" == "$_ga_route_target" ]]; then
            routed+=("${failed[$_i]}"); routed_files+=("${failed_files[$_i]}")
        else
            residual+=("${failed[$_i]}"); residual_files+=("${failed_files[$_i]}")
        fi
    done

    if [[ "$verdict" == "pass" || ${#routed[@]} -eq 0 ]]; then
        rm -f "$design_feedback_path" 2>/dev/null || true
    else
        {
            printf '# Design-rooted gate feedback\n\n'
            printf 'The build_test_cycle cannot fix these — they route back to design.\n'
            printf 'Re-author the named acceptance assertions, then the pipeline re-verifies.\n\n'
            for _i in "${!routed[@]}"; do
                _ga_gate_detail "${routed[$_i]}" "$artifacts_dir/${routed_files[$_i]}"
            done
        } | atomic_write "$design_feedback_path"
    fi

    if [[ "$verdict" == "pass" || ${#residual[@]} -eq 0 ]]; then
        rm -f "$feedback_path" 2>/dev/null || true
    else
        {
            printf '# Gate Aggregator Feedback\n\n'
            printf 'The build_test_cycle did not converge: %d mechanical gate(s) failed. ' "${#residual[@]}"
            printf 'Address every finding below, then re-run.\n\n'
            for _i in "${!residual[@]}"; do
                _ga_gate_detail "${residual[$_i]}" "$artifacts_dir/${residual_files[$_i]}"
            done
            # Name the routed gates without their detail, so build does not read a
            # partial payload as the complete failure set and declare itself done.
            if [[ ${#routed[@]} -gt 0 ]]; then
                printf '## Handled elsewhere\n\n'
                printf -- '- %d further gate(s) route to `%s` and are addressed there, not by build: %s\n\n' \
                    "${#routed[@]}" "$_ga_route_target" "${routed[*]}"
            fi
        } | atomic_write "$feedback_path"
    fi

    if [[ "$verdict" == "pass" ]]; then
        _ga_emit "gate_aggregator.pass"
    else
        _ga_emit "gate_aggregator.fail" "failed=${failed[*]}" "verdict=$verdict"
    fi

    _ga_emit "plugin.result" "plugin=gate-aggregator" "verdict=$verdict"
    return 0
}

# ─── gate_aggregator_cleanup ──────────────────────────────────────────────────
gate_aggregator_cleanup() {
    # No self-emit (#1705): plugin_hook_call already brackets this hook with
    # plugin.cleanup.start/complete. A second pair from here is the same
    # two-emitters-one-name collision the run pair was filed for.
    return 0
}
