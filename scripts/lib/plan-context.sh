#!/usr/bin/env bash
# scripts/lib/plan-context.sh — durable, collision-safe plan-stage context cache
# + max_turns envelope recovery (#1052, EPIC #966 Phase 1).
#
# Why this exists: when the plan stage burns its turn budget mid-tool-call it
# emits no plan.json — the exploration is thrown away and a rerun re-derives
# everything from scratch. This lib (a) persists the planner's recovered
# exploration to a namespaced cross-run cache so a rerun RESUMES, and (b)
# recovers a complete plan from a max_turns envelope when the model happened to
# emit one before exhausting its budget. It is the plan-stage analogue of the
# impact-stage resilience work (#864/#891/#908); _plan_recover_envelope_json
# deliberately mirrors _impact_recover_envelope_json (impact-prefilter.sh).
#
# WHY no emit_event here: the 4 new plan events (plan.context.persisted/resumed/
# scope_too_large/envelope.recovered) are emitted from plugins/agent/plan/
# plugin.sh, NOT this lib. event-schema-emitted-coverage-test.sh scans only
# core/ and plugins/agent/ for emitters; emitting from scripts/lib/ would make
# the events invisible to that coverage gate. These functions return/echo data
# and let plugin.sh do the emitting.

# Idempotent source guard.
if [[ "${_ZBUILD_PLAN_CONTEXT_LOADED:-}" == "1" ]]; then
    return 0
fi
_ZBUILD_PLAN_CONTEXT_LOADED=1

# #944 (ADR-028 v1.2): _plan_recover_envelope_json delegates to the shared
# framework recovery helper (_llm_recover_envelope_json). Source it here so the
# lib resolves standalone — e.g. tests/unit/plan-context-lib-test.sh sources
# this file without going through plugin.sh. Idempotent (llm-agent.sh guards).
_PLAN_CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./llm-agent.sh
source "$_PLAN_CONTEXT_LIB_DIR/llm-agent.sh"
# ADR-059 §6 (#1930): repo id and goal hash moved to the identity module, which
# owns identity and nothing else. This file is one of its consumers, not its
# owner — the whole point of the extraction is that cleanup.sh and worktree.sh
# can source identity.sh WITHOUT the llm-agent.sh line above coming with it.
# shellcheck source=./identity.sh
source "$_PLAN_CONTEXT_LIB_DIR/identity.sh"

# ─── plan_context_dir ────────────────────────────────────────────────────────
# Root of the cross-run cache. Test- and operator-overridable.
plan_context_dir() {
    printf '%s' "${ZBUILD_PLAN_CONTEXT_DIR:-$HOME/.zbuild/plan-context}"
}

# ─── plan_context_path <repo_id> <scope_key> <goal_hash> ─────────────────────
# Namespaced JSON leaf path: <dir>/<repo_id>/<scope_key>/<goal_hash>.json
plan_context_path() {
    local repo_id="$1" scope_key="$2" goal_hash="$3"
    printf '%s/%s/%s/%s.json' "$(plan_context_dir)" "$repo_id" "$scope_key" "$goal_hash"
}

# ─── plan_context_md_path <repo_id> <scope_key> <goal_hash> ──────────────────
# The .md banner sibling of plan_context_path.
plan_context_md_path() {
    local repo_id="$1" scope_key="$2" goal_hash="$3"
    printf '%s/%s/%s/%s.md' "$(plan_context_dir)" "$repo_id" "$scope_key" "$goal_hash"
}

# ─── plan_context_write <goal_hash> <scope_key> <status> <num_turns> \
#                        <reasoning> <scope_ref> ─────────────────────────────
# Build the plan-context JSON + .md banner and write BOTH atomically to the
# namespaced cache path; ALSO echo the JSON to stdout so plugin.sh can mirror it
# into the per-run artifacts dir. Uses a PID/run-scoped temp + atomic mv so
# concurrent runs on one host never leave a torn or interleaved file (Pillar E).
plan_context_write() {
    local goal_hash="$1" scope_key="$2" status="$3" num_turns="$4" reasoning="$5" scope_ref="$6"

    local repo_id branch created_at run_id num_turns_json candidate_split
    repo_id="$(zbuild_repo_id)"
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run_id="${ZBUILD_RUN_ID:-}"

    # num_turns is an int or JSON null (never a quoted string).
    if [[ "$num_turns" =~ ^[0-9]+$ ]]; then
        num_turns_json="$num_turns"
    else
        num_turns_json="null"
    fi
    # candidate_split is true only for the scope_too_large terminal.
    if [[ "$status" == "scope_too_large" ]]; then
        candidate_split="true"
    else
        candidate_split="false"
    fi

    local json
    json="$(jq -n \
        --arg goal_hash "$goal_hash" \
        --arg scope_ref "$scope_ref" \
        --arg status "$status" \
        --argjson num_turns "$num_turns_json" \
        --arg reasoning "$reasoning" \
        --argjson candidate_split "$candidate_split" \
        --arg run_id "$run_id" \
        --arg repo_id "$repo_id" \
        --arg scope_key "$scope_key" \
        --arg branch "$branch" \
        --arg created_at "$created_at" \
        '{
            schema_version: 1,
            goal_hash: $goal_hash,
            scope_manifest_ref: $scope_ref,
            status: $status,
            num_turns: $num_turns,
            partial_reasoning: $reasoning,
            candidate_split: $candidate_split,
            run_id: $run_id,
            repo_id: $repo_id,
            scope_key: $scope_key,
            branch: $branch,
            created_at: $created_at
        }')"

    local json_path md_path ns_dir base_dir
    json_path="$(plan_context_path "$repo_id" "$scope_key" "$goal_hash")"
    md_path="$(plan_context_md_path "$repo_id" "$scope_key" "$goal_hash")"
    ns_dir="$(dirname "$json_path")"
    # The cache holds model-authored reasoning; keep the base dir user-private
    # (0700) per review. mkdir must succeed; chmod is best-effort.
    base_dir="$(plan_context_dir)"
    mkdir -p "$ns_dir"
    chmod 700 "$base_dir" 2>/dev/null || true

    # PID/run-scoped temp + atomic mv (Pillar E concurrency contract): a reader
    # either sees the prior leaf or the new one, never a partial.
    local json_tmp md_tmp
    json_tmp="${json_path}.tmp.$$.${ZBUILD_RUN_ID:-0}"
    md_tmp="${md_path}.tmp.$$.${ZBUILD_RUN_ID:-0}"

    printf '%s\n' "$json" > "$json_tmp"
    # Check the primary JSON write's atomic mv: a failed write must NOT report
    # success (no echoed success JSON) or plugin.sh would emit a false-positive
    # plan.context.persisted. The .md banner below stays best-effort.
    if ! mv "$json_tmp" "$json_path"; then
        rm -f "$json_tmp" 2>/dev/null || true
        return 1
    fi

    {
        printf '# plan-context — %s\n\n' "$status"
        printf -- '- goal_hash: `%s`\n' "$goal_hash"
        printf -- '- scope_manifest_ref: `%s`\n' "$scope_ref"
        printf -- '- repo_id: `%s`\n' "$repo_id"
        printf -- '- branch: `%s`\n' "$branch"
        printf -- '- num_turns: %s\n' "$num_turns_json"
        printf -- '- run_id: `%s`\n' "$run_id"
        printf -- '- created_at: %s\n\n' "$created_at"
        printf '## Accumulated exploration\n\n'
        if [[ -n "$reasoning" ]]; then
            printf '%s\n\n' "$reasoning"
        else
            printf '_(none recovered)_\n\n'
        fi
        printf '## Candidate: split this issue?\n\n'
        if [[ "$candidate_split" == "true" ]]; then
            printf 'Yes — the plan stage exhausted its turn budget. Split into smaller sub-issues.\n'
        else
            printf 'No.\n'
        fi
    } > "$md_tmp"
    mv "$md_tmp" "$md_path"

    printf '%s\n' "$json"
}

# ─── plan_context_read_for_resume <repo_id> <scope_key> <goal_hash> \
#                                  <scope_ref> ───────────────────────────────
# Echo the prior partial_reasoning ONLY when resume is safe: ZBUILD_PLAN_RESUME
# != 0 (default on) AND the cache leaf exists AND its goal_hash/repo_id/
# scope_manifest_ref all match the args AND status != complete. Any mismatch
# degrades to a safe full re-exploration (echo nothing, rc=1) — never a
# wrong-context resume (Pillar E).
plan_context_read_for_resume() {
    local repo_id="$1" scope_key="$2" goal_hash="$3" scope_ref="$4"

    [[ "${ZBUILD_PLAN_RESUME:-1}" != "0" ]] || return 1

    local json_path
    json_path="$(plan_context_path "$repo_id" "$scope_key" "$goal_hash")"
    [[ -f "$json_path" ]] || return 1
    jq empty "$json_path" >/dev/null 2>&1 || return 1

    local c_goal c_repo c_ref c_status
    c_goal="$(jq -r '.goal_hash // ""' "$json_path" 2>/dev/null)"
    c_repo="$(jq -r '.repo_id // ""' "$json_path" 2>/dev/null)"
    c_ref="$(jq -r '.scope_manifest_ref // ""' "$json_path" 2>/dev/null)"
    c_status="$(jq -r '.status // ""' "$json_path" 2>/dev/null)"

    [[ "$c_goal" == "$goal_hash" ]] || return 1
    [[ "$c_repo" == "$repo_id" ]] || return 1
    [[ "$c_ref" == "$scope_ref" ]] || return 1
    [[ "$c_status" != "complete" ]] || return 1

    jq -r '.partial_reasoning // ""' "$json_path" 2>/dev/null
    return 0
}

# ─── plan_context_recover_sidecar_reasoning <stage> <artifact_dir> ───────────
# Locate the router max_turns diagnostic sidecar and distill a reasoning blob
# from it: the partial .result text, .num_turns, and a compact list of
# .tool_uses[] file paths when present. Echoes "" on absence/parse-failure.
#
# WHY this is a fidelity-limited proxy: the live in-progress transcript is not
# available to the plugin. The router only persists this final envelope on a
# non-zero claude exit; .result holds whatever partial text the model emitted
# before the budget ran out, which is the most faithful capturable signal.
plan_context_recover_sidecar_reasoning() {
    local stage="$1" artifact_dir="$2"

    # Resolve the sidecar dir from the SAME expression route.sh writes it to
    # (${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR:-...}/artifacts}/stage-io), so a
    # caller that set ZBUILD_ARTIFACT_DIR differently from $artifact_dir still
    # finds the router's max_turns envelope. Falls back to the passed-in
    # $artifact_dir (the existing behavior) when neither env var is set.
    local sidecar_base
    if [[ -n "${ZBUILD_ARTIFACT_DIR:-}" ]]; then
        sidecar_base="$ZBUILD_ARTIFACT_DIR"
    elif [[ -n "${ZBUILD_STATE_DIR:-}" ]]; then
        sidecar_base="$ZBUILD_STATE_DIR/artifacts"
    else
        sidecar_base="$artifact_dir"
    fi
    local sidecar_dir="$sidecar_base/stage-io"

    local sidecar="$sidecar_dir/${stage}-sync-error.raw-claude-output.json"
    if [[ ! -f "$sidecar" ]]; then
        # Glob-fallback: newest <stage>-*error*.raw-claude-output.json
        local newest="" f
        for f in "$sidecar_dir"/"${stage}"-*error*.raw-claude-output.json; do
            [[ -e "$f" ]] || continue
            if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
                newest="$f"
            fi
        done
        sidecar="$newest"
    fi
    [[ -n "$sidecar" && -f "$sidecar" ]] || { printf ''; return 0; }
    jq empty "$sidecar" >/dev/null 2>&1 || { printf ''; return 0; }

    local result num_turns tool_files
    result="$(jq -r '.result // ""' "$sidecar" 2>/dev/null)"
    num_turns="$(jq -r '.num_turns // "unknown"' "$sidecar" 2>/dev/null)"
    # Best-effort: tool_uses[] may carry file paths under .input.file_path or
    # .input.path; absence is normal (older envelopes).
    tool_files="$(jq -r '
        (.tool_uses // [])
        | map(.input.file_path // .input.path // empty)
        | unique
        | .[]' "$sidecar" 2>/dev/null)"

    {
        printf 'num_turns: %s\n' "$num_turns"
        if [[ -n "$tool_files" ]]; then
            printf 'files explored:\n%s\n' "$tool_files"
        fi
        if [[ -n "$result" ]]; then
            printf 'partial reasoning:\n%s\n' "$result"
        fi
    }
    return 0
}

# ─── _plan_envelope_schema_ok <json> ─────────────────────────────────────────
# The plan envelope schema gate, factored out so the happy-path validation in
# plugin.sh AND the recovery helper below share ONE definition and never drift.
# rc=0 iff $1 is a valid plan envelope (schema_version==1 and a non-empty
# steps[] array).
_plan_envelope_schema_ok() {
    printf '%s' "${1:-}" | jq -e '
        type == "object"
        and (.schema_version == 1)
        and (.steps | type == "array")
        and (.steps | length > 0)
    ' >/dev/null 2>&1
}

# ─── _plan_recover_envelope_json <raw> (#1052; framework-delegated #944) ─────
# Schema-aware recovery from a max_turns envelope whose .result may still carry
# a valid final plan amid prose/examples. #944 (ADR-028 v1.2) retires the
# duplicated awk brace-grammar this function used to carry: it now delegates to
# the shared framework helper _llm_recover_envelope_json with the plan schema
# gate. Recovers ONLY when exactly one top-level balanced object passes
# _plan_envelope_schema_ok; fails closed on ambiguity (≥2 passers) and on zero
# passers — an honest schema_violation is safer than shipping an example as the
# plan (#908 lesson). rc=0 + object on stdout when recovered; rc=1 otherwise.
_plan_recover_envelope_json() {
    _llm_recover_envelope_json "${1:-}" _plan_envelope_schema_ok
}

# ─── plan_context_gc ─────────────────────────────────────────────────────────
# Lightweight self-trim of the cross-run cache (Pillar F opportunistic path).
# Prunes per <repo_id>/<scope_key> namespace by age (ZBUILD_PLAN_CONTEXT_RETAIN_DAYS,
# default 14) and an LRU max-entries cap (ZBUILD_PLAN_CONTEXT_MAX_ENTRIES,
# default 50). scope_too_large contexts are RETAINED preferentially (they are
# the resumable ones worth keeping). Quota-bounded, never prompts. No-op unless
# ZBUILD_PLAN_CONTEXT_GC != 0. The full operator CLI (Wave A3,
# cleanup-artifacts.sh) may call into this; keep it robust + side-effect-guarded.
plan_context_gc() {
    [[ "${ZBUILD_PLAN_CONTEXT_GC:-1}" != "0" ]] || return 0

    local root retain_days max_entries
    root="$(plan_context_dir)"
    retain_days="${ZBUILD_PLAN_CONTEXT_RETAIN_DAYS:-14}"
    max_entries="${ZBUILD_PLAN_CONTEXT_MAX_ENTRIES:-50}"
    [[ -d "$root" ]] || return 0

    # Path-sanitize guard: refuse to operate outside a non-empty cache root.
    [[ -n "$root" && "$root" != "/" ]] || return 0

    # 1) Age-based prune by mtime, but never drop a scope_too_large context.
    local age_min f status
    age_min=$(( retain_days * 24 * 60 ))
    if [[ "$age_min" -gt 0 ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            status="$(jq -r '.status // ""' "$f" 2>/dev/null)"
            [[ "$status" == "scope_too_large" ]] && continue
            rm -f "$f" "${f%.json}.md"
        done < <(find "$root" -type f -name '*.json' -mmin "+${age_min}" 2>/dev/null)
    fi

    # 2) LRU max-entries cap per <repo_id>/<scope_key> namespace dir. Keep the
    # newest $max_entries non-scope_too_large entries (by mtime); scope_too_large
    # entries are ALWAYS retained and never count toward the deletable budget.
    # Delete the oldest non-stl entries beyond the cap.
    local ns_dir prunable keep_from f idx
    while IFS= read -r ns_dir; do
        [[ -d "$ns_dir" ]] || continue
        # Collect non-stl .json oldest-first.
        prunable=()
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            status="$(jq -r '.status // ""' "$f" 2>/dev/null)"
            [[ "$status" == "scope_too_large" ]] && continue
            prunable+=("$f")
        done < <(_plan_context_ls_by_mtime_oldest "$ns_dir")
        # Keep the newest $max_entries of the prunable set → delete the first
        # (oldest) (count - max_entries) of them.
        keep_from=$(( ${#prunable[@]} - max_entries ))
        [[ "$keep_from" -gt 0 ]] || continue
        idx=0
        for f in "${prunable[@]}"; do
            [[ "$idx" -lt "$keep_from" ]] || break
            rm -f "$f" "${f%.json}.md"
            idx=$(( idx + 1 ))
        done
    done < <(find "$root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)
}

# List *.json in a namespace dir, oldest mtime first. Portable across BSD/GNU
# stat (macOS lacks `stat -c`); falls back to find's printf when available.
_plan_context_ls_by_mtime_oldest() {
    local dir="$1" f mtime
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        if mtime="$(stat -f '%m' "$f" 2>/dev/null)"; then
            :
        else
            mtime="$(stat -c '%Y' "$f" 2>/dev/null || printf '0')"
        fi
        printf '%s\t%s\n' "$mtime" "$f"
    done | sort -n | cut -f2-
}
