#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/build — Build stage agent (issues #341, #467)              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: build (ADR-013 T2, ADR-018 Pattern 2 — agent-loop with derived diff)
# Produces: state/artifacts/diff.patch AND state/artifacts/build-summary.json
#
# Lifecycle:
#   build_stage_init        — set env vars, emit plugin.init.start
#   build_stage_run         — derive paths, delegate to _build_stage_run_inner
#   _build_stage_run_inner  — redact → route_to_model_loop → git diff → write
#   build_stage_finalize    — emit plugin.finalize.complete
#   build_stage_cleanup     — emit plugin.cleanup.complete
#
# CRITICAL: diff.patch is NEVER applied here — it is the working-tree diff
# left by the agent loop, captured via `git diff HEAD` after the loop returns.
# The downstream test stage applies and validates it.

[[ -n "${_ZBUILD_BUILD_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_BUILD_DIR="$_ZBUILD_PLUGIN_DIR"
_BUILD_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_BUILD_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_BUILD_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_BUILD_ROOT/core/router/route.sh"
# #498: stage_io_begin/end emit the post-loop changed-files summary banner.
# route.sh already sources stage-io, but make the dependency explicit so
# unit tests that load only the plugin (not the router) still get it.
# shellcheck source=../../../core/output/stage-io.sh
source "$_BUILD_ROOT/core/output/stage-io.sh"
# ADR-018 (#470): artifact renderer registry for inter-stage markdown.
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_BUILD_ROOT/scripts/lib/artifact-render.sh"
# #506: shared numstat banner formatter (also used by review).
# shellcheck source=../../../scripts/lib/numstat-format.sh
source "$_BUILD_ROOT/scripts/lib/numstat-format.sh"

# ─── init ───────────────────────────────────────────────────────────────────
build_stage_init() {
    export ZBUILD_PLUGIN="build"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=build"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
build_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "build_stage_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    local scope_manifest="$state_dir/scope-manifest.md"
    local plan_json_path="$artifacts_dir/plan.json"

    _build_stage_run_inner \
        "$scope_manifest" \
        "$plan_json_path" \
        "$artifacts_dir/diff.patch" \
        "$artifacts_dir/build-summary.json" \
        "$artifacts_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan_json_path
#   $3 = output_diff_patch path
#   $4 = output_summary_json path
#   $5 = artifact_dir for intermediate files
_build_stage_run_inner() {
    local scope_manifest="$1"
    local plan_json_path="$2"
    local output_diff_patch="$3"
    local output_summary_json="$4"
    local artifact_dir="${5:-$(dirname "$output_summary_json")}"

    if [[ -z "$scope_manifest" || -z "$plan_json_path" || -z "$output_diff_patch" || -z "$output_summary_json" ]]; then
        error "_build_stage_run_inner: requires <scope_manifest> <plan_json_path> <output_diff_patch> <output_summary_json> [artifact_dir]"
        return 2
    fi

    mkdir -p "$artifact_dir"

    if [[ ! -f "$plan_json_path" ]]; then
        error "_build_stage_run_inner: plan.json not found at $plan_json_path"
        emit_event "plugin.run.error" "plugin=build" "reason=missing_plan_json"
        return 2
    fi

    local plan_json
    plan_json="$(cat "$plan_json_path")"

    # Extract plan.files[] — the canonical scope for this build. Falls back to
    # plan.steps[].files[] for the legacy plan shape used by some fixtures.
    local plan_files_csv=""
    plan_files_csv="$(printf '%s' "$plan_json" | \
        jq -r '[(.files // []), ([.steps[]?.files[]?] // [])] | flatten | unique | join(",")' \
        2>/dev/null || echo "")"

    # ─── Write build prompt (ADR-018 Pattern 2) ──────────────────────────────
    local prompt_input_file="$artifact_dir/build-prompt.txt"
    local _build_instructions
    _build_instructions="$(_build_compose_instructions "$plan_files_csv")"

    # ADR-018 (#470): render plan.json as markdown for LLM consumption when
    # the renderer registry is available. Falls back to raw JSON otherwise.
    local plan_payload="$plan_json"
    if declare -F render_artifact >/dev/null 2>&1; then
        plan_payload="$(render_artifact plan "$plan_json" 2>/dev/null || echo "$plan_json")"
    fi
    local prompt
    printf -v prompt '%s\n\n## Plan\n%s\n' "$_build_instructions" "$plan_payload"

    # ─── #511 F2: cycle-feedback preamble at byte 0 ──────────────────────────
    # When the prior cycle iter's test stage produced a failures summary,
    # prepend it AHEAD of the standard instructions so the model sees prior
    # failures BEFORE its rules. Empty/missing file → preamble omitted
    # entirely (silent-failure guard: `[[ -s file ]]`, not just `-f`).
    local _preamble
    _preamble="$(_build_read_prior_failures 2>/dev/null || true)"
    if [[ -n "$_preamble" ]]; then
        prompt="${_preamble}${prompt}"
    fi
    printf '%s\n' "$prompt" > "$prompt_input_file"

    local redacted_file="$artifact_dir/build-prompt.redacted.txt"

    if ! apply_scope_redaction "$prompt_input_file" "$redacted_file" "$scope_manifest" "" "0"; then
        error "_build_stage_run_inner: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=build" "reason=redaction_failed"
        return 1
    fi

    # ─── Route through agent loop (ADR-018 Pattern 2) ────────────────────────
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier="${ZBUILD_BUILD_TIER:-T2}"
    local max_iter; max_iter="$(_route_resolve_max_iterations 2>/dev/null || echo 10)"
    [[ "$max_iter" =~ ^[0-9]+$ ]] || max_iter=10
    # ─── #511 F2: cycle-budget clamp ─────────────────────────────────────────
    # When running INSIDE a cycle iter (ZBUILD_CYCLE_ITER set by orchestrator),
    # clamp the inner agent-loop max_iterations to 15 to bound worst-case cost
    # (cycle.max_iter × stage_count × inner.max_iter). Default upper bound is
    # 25 (per ADR-018), so we cap to 15 only when it would exceed.
    if [[ -n "${ZBUILD_CYCLE_ITER:-}" && "$max_iter" -gt 15 ]]; then
        local _orig="$max_iter"
        max_iter=15
        emit_event "build.cycle.max_turns_clamped" "plugin=build" \
            "iter=${ZBUILD_CYCLE_ITER}" "orig=$_orig" "clamped=$max_iter" \
            >/dev/null 2>&1 || true
    fi

    # Expose the scope manifest path so per-iteration redaction inside the loop
    # can satisfy C6 without inlining the manifest at every consumer.
    export ZBUILD_SCOPE_MANIFEST="$scope_manifest"

    local router_rc=0
    # #491: do NOT redirect route_to_model_loop's stderr — the per-iteration
    # stage-io input banner writes to fd 2 (ZBUILD_STAGE_IO_FD default) and
    # 2>/dev/null would swallow every iteration's input banner, breaking the
    # ADR-015 §v4 input-before-action ordering contract for Pattern 2.
    route_to_model_loop "$tier" "$redacted_file" "$repo_root" "$max_iter" \
        --scope-allowlist "$plan_files_csv" || router_rc=$?

    local iterations="${_ROUTE_LOOP_ITERATIONS:-0}"
    local terminated_reason="${_ROUTE_LOOP_TERMINATED_REASON:-error}"
    local loop_input_tokens="${_ROUTE_LOOP_INPUT_TOKENS:-0}"
    local loop_output_tokens="${_ROUTE_LOOP_OUTPUT_TOKENS:-0}"

    if [[ $router_rc -ge 2 ]]; then
        warn "_build_stage_run_inner: route_to_model_loop rc=$router_rc — writing empty diff and summary"
        terminated_reason="error"
    fi

    # ─── Derive diff.patch from git working tree ─────────────────────────────
    # `git add -N` (intent-to-add) makes untracked files appear in `git diff HEAD`
    # without staging their content. Without it, new files created by the agent
    # would be silently dropped from the canonical diff.
    git -C "$repo_root" add -N . 2>/dev/null || true
    local diff_content="" diff_rc=0
    diff_content="$(git -C "$repo_root" diff HEAD 2>/dev/null)" || diff_rc=$?
    if [[ $diff_rc -ne 0 ]]; then
        warn "_build_stage_run_inner: git diff HEAD failed in $repo_root"
        emit_event "loop.git_diff_failed" "plugin=build" "cwd=$repo_root" "rc=$diff_rc"
        diff_content=""
    fi

    # ─── Scope post-validation via git diff --name-status -z ─────────────────
    local scope_violation="false"
    local -a scope_violations=()
    if [[ -n "$diff_content" && -n "$plan_files_csv" ]]; then
        local -a allowed_files=()
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206,SC2034
        # SC2206: word-split intentional. SC2034: passed to _build_path_in_scope
        # via nameref (local -n _allowed_ref), which shellcheck cannot follow.
        allowed_files=( $plan_files_csv )
        IFS="$IFS_save"

        # name-status -z output: <STATUS>\0<path1>[\0<path2>] for renames.
        # NULs are stripped by command substitution; route through a temp file
        # so the NUL-delimited tokens survive intact.
        local _ns_file="$artifact_dir/.build-name-status.bin"
        git -C "$repo_root" diff --name-status -z HEAD > "$_ns_file" 2>/dev/null || :

        local -a tokens=()
        while IFS= read -r -d '' tok; do
            tokens+=("$tok")
        done < "$_ns_file"
        rm -f "$_ns_file"

        local i n=${#tokens[@]}
        i=0
        while (( i < n )); do
            local status="${tokens[$i]}"
            i=$((i+1))
            local first_path="${tokens[$i]:-}"
            i=$((i+1))
            local -a paths_to_check=("$first_path")
            # Renames/copies (R*/C*) emit two paths: old + new.
            if [[ "$status" =~ ^[RC] ]]; then
                paths_to_check+=("${tokens[$i]:-}")
                i=$((i+1))
            fi
            local p
            for p in "${paths_to_check[@]}"; do
                [[ -z "$p" ]] && continue
                if ! _build_path_in_scope "$p" allowed_files; then
                    scope_violation="true"
                    scope_violations+=("$p")
                    emit_event "build.scope.violation" "plugin=build" \
                        "path=$p" "status=$status"
                fi
            done
        done
    fi

    # #498: capture numstat BEFORE the scope-violation zero-out so the operator
    # banner (emitted after the summary) can surface what the LLM attempted
    # even when diff_content is forcibly emptied below.
    local pre_zero_numstat=""
    if [[ "$scope_violation" == "true" ]]; then
        pre_zero_numstat="$(git -C "$repo_root" diff HEAD --numstat 2>/dev/null || true)"
        warn "_build_stage_run_inner: scope violation — writing empty diff.patch"
        diff_content=""
    fi

    # Empty-diff signal: emit warn event when prose-only / no edits produced.
    if [[ -z "$diff_content" && "$scope_violation" != "true" && $router_rc -lt 2 ]]; then
        emit_event "build.empty_diff" "plugin=build" \
            "iterations=$iterations" "terminated_reason=$terminated_reason"
    fi

    # ─── Write diff.patch (NEVER applied here) ───────────────────────────────
    printf '%s' "$diff_content" > "$output_diff_patch"

    # ─── Parse diff stats ────────────────────────────────────────────────────
    local files_changed_json="[]" lines_added=0 lines_removed=0
    if [[ -n "$diff_content" ]]; then
        local changed_files_raw
        changed_files_raw="$(printf '%s' "$diff_content" \
            | grep '^diff --git' \
            | sed 's|^diff --git a/[^ ]* b/||' || true)"
        if [[ -n "$changed_files_raw" ]]; then
            files_changed_json="$(printf '%s\n' "$changed_files_raw" \
                | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
        fi
        lines_added="$(printf '%s' "$diff_content" | grep -c '^+' 2>/dev/null || true)"
        lines_removed="$(printf '%s' "$diff_content" | grep -c '^-' 2>/dev/null || true)"
        local header_plus header_minus
        header_plus="$(printf '%s' "$diff_content" | grep -c '^+++' 2>/dev/null || true)"
        header_minus="$(printf '%s' "$diff_content" | grep -c '^---' 2>/dev/null || true)"
        lines_added=$(( lines_added - header_plus ))
        lines_removed=$(( lines_removed - header_minus ))
        [[ $lines_added -lt 0 ]] && lines_added=0
        [[ $lines_removed -lt 0 ]] && lines_removed=0
    fi
    local files_changed_count
    files_changed_count="$(printf '%s' "$files_changed_json" | jq 'length' 2>/dev/null || echo 0)"

    # ─── Write build-summary.json (schema_version=2) ─────────────────────────
    local issue="${ZBUILD_ISSUE:-0}"
    [[ "$issue" =~ ^[0-9]+$ ]] || issue=0

    local violations_json="[]"
    if [[ ${#scope_violations[@]} -gt 0 ]]; then
        violations_json="$(printf '%s\n' "${scope_violations[@]}" \
            | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
    fi

    # #507: .verdict field paired with .scope_violation drives the runner's
    # stage-complete indicator (ADR-020 amendment). schema_version bumped to 3.
    local build_verdict="pass"
    [[ "$scope_violation" == "true" ]] && build_verdict="scope_violation"

    # ─── #509: corrupt-patch guard ────────────────────────────────────────────
    # Run `git apply --check` on the post-loop diff.patch BEFORE the atomic
    # write so apply_check.* fields can be folded into the single summary
    # write. Fail-CLOSED: on failure, set verdict=corrupt_diff AND force
    # the plugin to return rc=1 (defense in depth — runner.sh:672-686 halts
    # on rc!=0; verdict surfaces in the indicator + downstream consumers).
    # Skip the gate entirely if the diff was zero'd by a scope_violation —
    # that path has its own verdict.
    local _gate_tmp; _gate_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-applycheck.XXXXXX")"
    set +e
    _build_apply_check "$repo_root" "$output_diff_patch" "$_gate_tmp"
    local _gate_rc=$?
    set -e
    local apply_check_json
    apply_check_json="$(cat "$_gate_tmp" 2>/dev/null || echo '{}')"
    rm -f "$_gate_tmp"

    local force_fail_rc=0
    if [[ "$scope_violation" != "true" && "$_gate_rc" -ne 0 ]]; then
        build_verdict="corrupt_diff"
        force_fail_rc=1
    fi

    jq -n \
        --argjson schema_version 3 \
        --argjson issue "$issue" \
        --argjson files_changed "$files_changed_json" \
        --argjson lines_added "$lines_added" \
        --argjson lines_removed "$lines_removed" \
        --arg diff_patch_path "$output_diff_patch" \
        --argjson iterations "$iterations" \
        --arg terminated_reason "$terminated_reason" \
        --arg verdict "$build_verdict" \
        --argjson scope_violation "$([[ "$scope_violation" == "true" ]] && echo true || echo false)" \
        --argjson scope_violations "$violations_json" \
        --argjson loop_input_tokens "$loop_input_tokens" \
        --argjson loop_output_tokens "$loop_output_tokens" \
        --argjson apply_check "$apply_check_json" \
        --arg notes "Build stage completed. Diff written to artifact; not applied." \
        '{
            schema_version: $schema_version,
            issue: $issue,
            files_changed: $files_changed,
            lines_added: $lines_added,
            lines_removed: $lines_removed,
            diff_patch_path: $diff_patch_path,
            iterations: $iterations,
            terminated_reason: $terminated_reason,
            verdict: $verdict,
            scope_violation: $scope_violation,
            scope_violations: $scope_violations,
            loop_input_tokens: $loop_input_tokens,
            loop_output_tokens: $loop_output_tokens,
            apply_check: $apply_check,
            notes: $notes
        }' | atomic_write "$output_summary_json"

    # ─── #498: changed-files numstat summary banner (kind=computed) ──────────
    # Emit a NEW stage-level operator banner after route_to_model_loop returns
    # so the operator sees BOTH the LLM's per-iteration prose (#482's kind=llm
    # banners) AND what files actually changed on disk. kind=computed is
    # DISTINCT from #482's kind=llm — the build-loop-banner-test regex matches
    # `[llm]` literally; using llm here would collide with #491's ordering
    # contract.
    _BUILD_PLAN_FILES_CSV="$plan_files_csv" \
    _build_emit_changed_files_summary \
        "$repo_root" "$terminated_reason" \
        "$scope_violation" "$pre_zero_numstat" || true

    emit_event "plugin.run.complete" "stage=build" \
        "plugin=build" \
        "files_changed_count=$files_changed_count" \
        "lines_added=$lines_added" \
        "lines_removed=$lines_removed" \
        "iterations=$iterations" \
        "terminated_reason=$terminated_reason" \
        "scope_violation=$scope_violation" \
        "verdict=$build_verdict" \
        "artifact=build-summary.json"
    # #509: rc-wins fail-CLOSED — corrupt-patch gate makes the plugin exit 1
    # so runner.sh:672-686 halts the pipeline (verdict=corrupt_diff is
    # defense-in-depth for the indicator + downstream consumers).
    return "$force_fail_rc"
}

# ─── _build_read_prior_failures (#511 F2) ──────────────────────────────────
# Read the prior cycle iter's test-failures-summary (wired in by the cycle
# orchestrator's _cycle_apply_feedback as
# $ZBUILD_CYCLE_FEEDBACK_DIR/prior_test_failures.txt). Returns the preamble
# text on stdout (with trailing blank line) OR empty stdout when:
#   - not running in a cycle (ZBUILD_CYCLE_ITER unset)
#   - cycle feedback dir not exported
#   - file missing OR empty (silent-failure guard: `[[ -s file ]]`)
#
# Empty stdout → caller omits the preamble entirely (NEVER silent emit).
_build_read_prior_failures() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    local f="$fb_dir/prior_test_failures.txt"
    # `-s`: present AND non-empty. `-f` alone would let empty-but-present
    # files through and inject a no-op preamble (silent failure).
    [[ ! -s "$f" ]] && return 0
    local prev_iter=$(( iter - 1 ))
    [[ "$prev_iter" -lt 1 ]] && prev_iter=1
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "$body" ]] && return 0
    printf '## Previous test failures (iter %d)\n%s\nFix these before LOOP_COMPLETE.\n\n' \
        "$prev_iter" "$body"
}

# _build_compose_instructions <plan_files_csv>
# Emits the static portion of the build prompt. Per ADR-018 Pattern 2:
# Read/Edit/Write/Bash tools are available; the loop watches `git diff HEAD`;
# completion is signaled by emitting `LOOP_COMPLETE` on its own line.
_build_compose_instructions() {
    local plan_files_csv="${1:-}"
    local scope_section=""
    if [[ -n "$plan_files_csv" ]]; then
        scope_section="$(printf '%s\n' "$plan_files_csv" | tr ',' '\n' | sed 's/^/  - /')"
    else
        scope_section="  (no plan.files[] declared — refuse to edit if scope is unclear)"
    fi
    cat <<BUILD_PROMPT
You are an autonomous build agent for zBuild. You have Read, Edit, Write, and
Bash tools available. Your job is to edit the working tree to implement the
plan below.

## Scope (plan.files[])
You may ONLY touch files listed here. Refuse any out-of-scope edit.
${scope_section}

## How the loop works
- Each iteration you may make code changes via Edit/Write/Bash.
- After each iteration the pipeline captures \`git diff HEAD\` and feeds it
  back to you so you can verify progress.
- Do NOT emit a unified diff in your response — the pipeline derives the
  canonical \`diff.patch\` artifact from \`git diff HEAD\` automatically.

## Completion sentinel
When the implementation is complete and tests would pass, emit \`LOOP_COMPLETE\`
on its own line as the FINAL line of your response. This terminates the loop.

## Rules
- Touch only files in the scope list above.
- Do not run \`git commit\` — the pipeline owns commit semantics.
- Keep changes minimal and aligned with the plan.
BUILD_PROMPT
}

# _build_path_in_scope <path> <allowed_files_array_name>
# Thin wrapper around the shared _numstat_path_in_scope helper (#506).
_build_path_in_scope() {
    _numstat_path_in_scope "$@"
}

# ─── _build_apply_check (#509) ──────────────────────────────────────────────
# Run `git apply --check` on the post-loop diff.patch to catch the class
# of corruption that has been silently producing empty build artifacts:
# `git add -N` zero-line stat entries, stale @@ line numbers from cumulative
# multi-iter edits, malformed payloads, etc. Fail-CLOSED.
#
# Output contract: helper writes a JSON object to <result_path> so the
# caller (a subshell at this site would lose vars per the precedent at
# plugin.sh:493-501 — capture state via tmp file, not $()).
#
# Args:
#   $1 = repo_root           absolute path of working tree
#   $2 = output_diff_patch   path to diff.patch produced by build loop
#   $3 = result_path         tmp file to write JSON result into
#
# JSON fields written to <result_path>:
#   { ok: true|false,
#     reason: "<classification>" (only on fail),
#     stderr_first_line: "<line>" (only on fail),
#     truncation_observed: bool,
#     diff_bytes: <int>,
#     skipped: bool }
#
# Returns rc=0 on pass or empty-diff skip; rc=1 fail-CLOSED on everything
# else (corruption, missing git, precondition state, catastrophic git rc>1).
_build_apply_check() {
    local repo_root="$1"
    local diff_path="$2"
    local result_path="${3:?_build_apply_check: missing result_path}"

    # NB: callers MUST invoke under `set +e` (e.g. wrapped in `set +e; ...; set -e`)
    # because the gate's whole point is to surface failure rc to a caller that
    # then folds the result into the build summary. Do NOT touch errexit state
    # here — bash flag changes leak to the caller and have burned us before.

    local diff_bytes=0
    if [[ -f "$diff_path" ]]; then
        diff_bytes="$(wc -c < "$diff_path" 2>/dev/null | tr -d ' ' || echo 0)"
    fi

    # ── (a) Empty-diff short-circuit: skip gate, emit event, return 0 ───────
    if [[ ! -s "$diff_path" ]]; then
        emit_event "build.apply_check.skipped" "plugin=build" \
            "reason=empty_diff" "diff_bytes=$diff_bytes" >/dev/null 2>&1 || true
        jq -n --argjson db "$diff_bytes" \
            '{ok:true, skipped:true, reason:"empty_diff_skipped",
              truncation_observed:false, diff_bytes:$db}' > "$result_path"
        return 0
    fi

    # ── (b) Invariant: defensive guard against cap-exceeded stat stubs ─────
    if head -c 64 "$diff_path" 2>/dev/null | grep -q '^(diff exceeded cap'; then
        emit_event "build.invariant.diff_is_stub" "plugin=build" \
            "diff_bytes=$diff_bytes" >/dev/null 2>&1 || true
        jq -n --argjson db "$diff_bytes" \
            '{ok:false, reason:"truncated", truncation_observed:true,
              stderr_first_line:"diff payload is a stat stub, not real patch",
              diff_bytes:$db}' > "$result_path"
        return 1
    fi

    # ── (c) Tool availability ──────────────────────────────────────────────
    if ! command -v git >/dev/null 2>&1; then
        emit_event "build.apply_check.unavailable" "plugin=build" \
            "reason=git_missing" >/dev/null 2>&1 || true
        jq -n --argjson db "$diff_bytes" \
            '{ok:false, reason:"tool_unavailable",
              stderr_first_line:"git binary not on PATH",
              truncation_observed:false, diff_bytes:$db}' > "$result_path"
        return 1
    fi

    # ── (d) Precondition gate (mirror _build_emit_changed_files_summary) ───
    local _pre_reason=""
    if [[ -d "$repo_root/.git/rebase-merge" || -d "$repo_root/.git/rebase-apply" ]]; then
        _pre_reason="rebase"
    elif [[ -f "$repo_root/.git/MERGE_HEAD" ]]; then
        _pre_reason="merge"
    elif [[ -f "$repo_root/.git/BISECT_LOG" ]]; then
        _pre_reason="bisect"
    elif ! git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1; then
        # Detached HEAD or unborn — distinguish via symbolic-ref.
        if ! git -C "$repo_root" symbolic-ref -q HEAD >/dev/null 2>&1; then
            _pre_reason="detached"
        else
            _pre_reason="unborn"
        fi
    fi
    if [[ -n "$_pre_reason" ]]; then
        emit_event "build.apply_check.precondition_failed" "plugin=build" \
            "reason=$_pre_reason" "repo_root=$repo_root" >/dev/null 2>&1 || true
        jq -n --argjson db "$diff_bytes" --arg r "$_pre_reason" \
            '{ok:false, reason:"precondition_failed",
              stderr_first_line:("git state precondition failed: " + $r),
              truncation_observed:false, diff_bytes:$db}' > "$result_path"
        return 1
    fi

    # ── (e) The check: git apply --check (default whitespace handling) ─────
    # Capture stderr separately so the first line can be classified.
    #
    # The post-loop diff.patch is `git diff HEAD`, so the changes ALREADY
    # exist in the working tree — a forward `git apply --check` would fail
    # context matching ("patch failed: file.txt:N") since the lines are
    # already changed. The downstream test stage applies the patch to a
    # clean tree (resets first), so the equivalent validation here is:
    #   - reverse-check: confirm the patch reverses cleanly against the
    #     current working tree (i.e. forward-applicable against HEAD).
    # `-R` also exercises the same parser, so corrupt-patch / @@-line
    # errors surface identically.
    local _stderr_file; _stderr_file="$(mktemp "${TMPDIR:-/tmp}/zb-applycheck-err.XXXXXX")"
    git -C "$repo_root" apply --check -R "$diff_path" 2>"$_stderr_file"
    local _check_rc=$?

    if [[ $_check_rc -eq 0 ]]; then
        rm -f "$_stderr_file"
        jq -n --argjson db "$diff_bytes" \
            '{ok:true, truncation_observed:false, diff_bytes:$db}' > "$result_path"
        return 0
    fi

    local _stderr_first
    _stderr_first="$(head -n 1 "$_stderr_file" 2>/dev/null || true)"
    rm -f "$_stderr_file"

    # Classify stderr → reason. Most common: "corrupt patch", "patch does not
    # apply", "does not match index", "No such file or directory".
    local _reason="context"
    if printf '%s' "$_stderr_first" | grep -qi 'corrupt patch'; then
        _reason="context"
    elif printf '%s' "$_stderr_first" | grep -qiE 'no such file|does not exist|new file .* exists in working dir'; then
        _reason="missing_target"
    elif printf '%s' "$_stderr_first" | grep -qiE 'binary|cannot represent'; then
        _reason="binary"
    elif printf '%s' "$_stderr_first" | grep -qiE 'patch does not apply|does not match'; then
        _reason="context"
    elif printf '%s' "$_stderr_first" | grep -qi 'whitespace'; then
        _reason="whitespace"
    fi
    # Catastrophic rc>1 → unavailable (could not even attempt the check).
    if [[ $_check_rc -gt 1 ]]; then
        emit_event "build.apply_check.unavailable" "plugin=build" \
            "rc=$_check_rc" "stderr_first_line=$_stderr_first" >/dev/null 2>&1 || true
        jq -n --argjson db "$diff_bytes" --arg s "$_stderr_first" --argjson rc "$_check_rc" \
            '{ok:false, reason:"tool_unavailable",
              stderr_first_line:$s, truncation_observed:false,
              diff_bytes:$db, git_apply_rc:$rc}' > "$result_path"
        return 1
    fi

    emit_event "build.apply_check.failed" "plugin=build" \
        "reason=$_reason" "stderr_first_line=$_stderr_first" \
        "diff_bytes=$diff_bytes" >/dev/null 2>&1 || true
    jq -n --argjson db "$diff_bytes" --arg s "$_stderr_first" --arg r "$_reason" \
        '{ok:false, reason:$r, stderr_first_line:$s,
          truncation_observed:false, diff_bytes:$db}' > "$result_path"
    return 1
}

# ─── _build_format_numstat ──────────────────────────────────────────────────
# Thin wrapper around the shared format_numstat (#506). Delegates to the
# extracted helper with build's defaults (event prefix=build, full-at
# pointer=build-summary.json) and mirrors _NUMSTAT_FILES_COUNT into the
# legacy _BUILD_NUMSTAT_FILES_COUNT name the caller still reads.
_BUILD_NUMSTAT_MAX_LINES=50
_BUILD_NUMSTAT_FILES_COUNT=0
_build_format_numstat() {
    local raw="$1"
    local allowed_name="$2"
    # event-prefix=build → emits "build.numstat.truncated" (stable name).
    format_numstat "$raw" "$allowed_name" \
        --event-prefix "build" \
        --full-at "build-summary.json"
    _BUILD_NUMSTAT_FILES_COUNT="$_NUMSTAT_FILES_COUNT"
    return 0
}

# ─── _build_emit_changed_files_summary ──────────────────────────────────────
# Emit the post-loop kind=computed stage_io banner showing `git diff HEAD
# --numstat` so the operator sees what the build loop actually changed on
# disk (independent of the LLM's per-iteration prose).
#
# Args:
#   $1 = repo_root
#   $2 = terminated_reason (from _ROUTE_LOOP_TERMINATED_REASON)
#   $3 = scope_violation ("true"/"false")
#   $4 = pre_zero_numstat (captured BEFORE diff zero-out on scope violation)
#
# Side effects:
#   - emits stage_io_begin/_end pair (kind=computed) on the build stage's
#     configured destinations (no-op when none configured — fail-soft)
#   - emits build.numstat.precondition_failed when git rev-parse HEAD fails
#   - emits build.discrepancy.detected when LOOP_COMPLETE + 0 files
#   - emits build.numstat.truncated via _build_format_numstat when capped
_build_emit_changed_files_summary() {
    local repo_root="$1"
    local terminated_reason="$2"
    local scope_violation="$3"
    local pre_zero_numstat="$4"

    local stage_id="${ZBUILD_CURRENT_STAGE:-build}"
    local start_ms="${EPOCHREALTIME/./}"
    start_ms=$(( 10#${start_ms:-0} / 1000 ))

    # ── Pre-check git state (detached HEAD, mid-rebase, unborn branch) ──────
    if ! git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1; then
        local reason="unknown"
        if [[ -d "$repo_root/.git/rebase-merge" || -d "$repo_root/.git/rebase-apply" ]]; then
            reason="rebase"
        elif [[ -f "$repo_root/.git/BISECT_LOG" ]]; then
            reason="bisect"
        elif [[ -f "$repo_root/.git/MERGE_HEAD" ]]; then
            reason="merge"
        elif ! git -C "$repo_root" symbolic-ref -q HEAD >/dev/null 2>&1; then
            reason="detached"
        else
            reason="unborn"
        fi
        emit_event "build.numstat.precondition_failed" "plugin=build" \
            "reason=$reason" "repo_root=$repo_root" >/dev/null 2>&1 || true
        local _seq=""
        stage_io_begin --stage "$stage_id" --kind computed \
            --input "git diff HEAD --numstat" \
            --metadata "diff_source=git_diff_HEAD_numstat" \
            --metadata "precondition_failed=true" \
            --metadata "reason=$reason" >/dev/null 2>&1 || return 0
        _seq="${_STAGE_IO_LAST_SEQ:-}"
        [[ -z "$_seq" ]] && return 0
        local now_ms="${EPOCHREALTIME/./}"
        now_ms=$(( 10#${now_ms:-0} / 1000 ))
        stage_io_end --stage "$stage_id" --kind computed --seq "$_seq" \
            --output "WARN: git state precondition failed (reason=$reason); numstat skipped" \
            --duration-ms $(( now_ms - start_ms )) \
            --metadata "precondition_failed=true" \
            --metadata "reason=$reason" >/dev/null 2>&1 || true
        return 0
    fi

    # ── Run numstat (use pre-zeroed snapshot on scope_violation) ───────────
    local numstat_out=""
    local scope_violation_mode="false"
    if [[ "$scope_violation" == "true" ]]; then
        numstat_out="$pre_zero_numstat"
        scope_violation_mode="true"
    else
        numstat_out="$(git -C "$repo_root" diff HEAD --numstat 2>/dev/null || true)"
    fi

    # ── Build allow-list from plan_files_csv (caller-scoped via env) ───────
    # We don't have direct access to plan_files_csv here; reconstruct from
    # ZBUILD_SCOPE_MANIFEST or fall back to empty (which disables redaction).
    # The simpler approach: caller passes via env var BUILD_PLAN_FILES_CSV.
    local -a allowed_files=()
    local _csv="${_BUILD_PLAN_FILES_CSV:-}"
    if [[ -n "$_csv" ]]; then
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206,SC2034
        # SC2206: word-split intentional. SC2034: passed to _build_format_numstat
        # via nameref (local -n _fmt_allowed_ref), which shellcheck cannot follow.
        allowed_files=( $_csv )
        IFS="$IFS_save"
    fi

    # ── Format with redaction + truncation ─────────────────────────────────
    # NB: capture via tmp file (not $()) so _BUILD_NUMSTAT_FILES_COUNT,
    # which _build_format_numstat sets on the caller, isn't lost across a
    # subshell boundary. The $(_build_format_numstat …) path would forfeit
    # the count and force a discrepancy false-positive (caught by #498's
    # integration test).
    local _fmt_tmp; _fmt_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-numstat.XXXXXX")"
    _build_format_numstat "$numstat_out" allowed_files > "$_fmt_tmp"
    local formatted; formatted="$(cat "$_fmt_tmp")"
    rm -f "$_fmt_tmp"
    local files_count="$_BUILD_NUMSTAT_FILES_COUNT"

    # ── Discrepancy: LOOP_COMPLETE + 0 files changed ──────────────────────
    local discrepancy="false"
    if [[ "$terminated_reason" == "done_sentinel" && "$files_count" -eq 0 \
          && "$scope_violation_mode" != "true" ]]; then
        discrepancy="true"
        emit_event "build.discrepancy.detected" "plugin=build" \
            "reason=loop_complete_no_changes" \
            "terminated_reason=$terminated_reason" \
            "files_changed=0" >/dev/null 2>&1 || true
        formatted="WARN: LLM signaled success but numstat shows 0 files changed"$'\n'"$formatted"
    fi

    # ── Emit stage_io banner pair (computed) ───────────────────────────────
    local _seq=""
    local -a begin_meta=(
        --metadata "diff_source=git_diff_HEAD_numstat"
        --metadata "files_changed=$files_count"
    )
    local -a end_meta=(
        --metadata "diff_source=git_diff_HEAD_numstat"
        --metadata "files_changed=$files_count"
    )
    if [[ "$scope_violation_mode" == "true" ]]; then
        begin_meta+=( --metadata "scope_violation=true" )
        end_meta+=( --metadata "scope_violation=true" )
    fi
    if [[ "$discrepancy" == "true" ]]; then
        end_meta+=( --metadata "discrepancy=loop_complete_no_changes" )
    fi

    stage_io_begin --stage "$stage_id" --kind computed \
        --input "git diff HEAD --numstat" \
        "${begin_meta[@]}" >/dev/null 2>&1 || return 0
    _seq="${_STAGE_IO_LAST_SEQ:-}"
    [[ -z "$_seq" ]] && return 0
    local now_ms="${EPOCHREALTIME/./}"
    now_ms=$(( 10#${now_ms:-0} / 1000 ))
    stage_io_end --stage "$stage_id" --kind computed --seq "$_seq" \
        --output "$formatted" \
        --duration-ms $(( now_ms - start_ms )) \
        "${end_meta[@]}" >/dev/null 2>&1 || true
    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
build_stage_finalize() {
    emit_event "plugin.finalize.complete" "plugin=build"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
build_stage_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=build"
    return 0
}
