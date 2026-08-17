#!/usr/bin/env bash
# scripts/lib/stage-checkpoint.sh — engine-generic stage checkpoint (#1879).
#
# A stage that exhausts its turn or wall-clock budget loses everything it
# explored, and the next attempt starts from zero. #1052 built a plan-specific
# answer that cannot work: it reconstructs the lost context from the router's
# error envelope, and the CLI's `error_max_turns` envelope carries neither
# `.result` nor `.tool_uses` — so the "resumable exploration" it persists is
# literally `num_turns: N`.
#
# The only thing that survives a torn-down CI runner is an ARTIFACT, so the model
# writes its progress as it goes. This module owns that contract:
#
#   declaration — a stage declares an `outputs:` entry with `role: checkpoint`
#   path        — the engine resolves it and puts it in the prompt as a LITERAL
#   splice-back — a non-empty checkpoint is fed to the next attempt
#
# WHY the path is a literal and not an env var: every `claude` spawn goes through
# `_zbuild_make_fresh_shell`, which unsets the entire ZBUILD_* namespace
# (scripts/lib/env-scrub.sh, ADR-024/#671) — "it MUST NOT see ZBUILD_* pipeline
# state" (core/router/route.sh). A model cannot read an exported path, so telling
# it one would be a no-op by construction.
#
# Sourced library: inherits the caller's pipefail settings; do NOT add set -euo.

[[ -n "${_ZBUILD_STAGE_CHECKPOINT_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_CHECKPOINT_LOADED=1

# The marker the injected block opens with. Used as the idempotence guard, so a
# retry (or the agentic loop's per-iteration redaction) cannot stack the block.
# NOT a first-line check: the ADR-049 vision preamble already owns the first line,
# and a second first-line guard would fight it.
_ZB_CHECKPOINT_MARKER='## STAGE CHECKPOINT (engine-managed)'

# ─── _checkpoint_declared_path <manifest> <state_dir> ────────────────────────
# Echo the resolved path of the outputs[] entry carrying `role: checkpoint`, or
# empty when the manifest declares none.
#
# Its own parser rather than manifest_graph_get_outputs: that helper recognises
# exactly id/type/source/required/path and drops every other key, so `role:` never
# reaches it (scripts/lib/manifest-graph.sh). An unknown key is IGNORED by every
# manifest parser in the tree — not rejected — which is what makes `role:` a legal
# place to put this.
_checkpoint_declared_path() {
    local manifest="$1" state_dir="$2"
    [[ -f "$manifest" ]] || return 0
    local raw
    raw="$(awk '
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]*-[[:space:]]*id:/ { path=""; next }
        in_out && /^[[:space:]]+path:[[:space:]]*/ {
            p=$0; sub(/^[[:space:]]+path:[[:space:]]*/, "", p)
            gsub(/^["'"'"']|["'"'"']$/, "", p); path=p; next
        }
        in_out && /^[[:space:]]+role:[[:space:]]*checkpoint([[:space:]]|$|#)/ {
            if (path != "") { print path; exit }
            next
        }
    ' "$manifest" 2>/dev/null)"
    [[ -n "$raw" ]] || return 0

    # Reuse the engine's existing interpolation rather than adding a sixth copy.
    if declare -F _verdict_resolve_path >/dev/null 2>&1; then
        _verdict_resolve_path "$raw" "$state_dir"
        return 0
    fi
    local artifact_dir="${state_dir}/artifacts" p="$raw"
    p="${p//\$\{state_dir\}/$state_dir}"
    p="${p//\$\{artifact_dir\}/$artifact_dir}"
    p="${p//\$\{artifacts_dir\}/$artifact_dir}"
    [[ "$p" != /* ]] && p="$state_dir/$p"
    printf '%s' "$p"
}

# ─── _checkpoint_prior_body <checkpoint_path> ────────────────────────────────
# The prior attempt's checkpoint, if any. Two sources, one path: this run's own
# artifact area (an intra-run retry) and ZBUILD_RESTORED_ARTIFACTS_DIR (a prior
# RUN, restored from the state branch — ADR-050, which #1878 had to fix first).
# The restored copy is only consulted when the live one is absent, so a retry
# never reads stale cross-run content over its own.
_checkpoint_prior_body() {
    local cp_path="$1"
    if [[ -s "$cp_path" ]]; then
        cat "$cp_path" 2>/dev/null
        return 0
    fi
    local restored="${ZBUILD_RESTORED_ARTIFACTS_DIR:-}"
    [[ -n "$restored" && -d "$restored" ]] || return 0
    local base; base="$(basename "$cp_path")"
    [[ -s "$restored/$base" ]] || return 0
    cat "$restored/$base" 2>/dev/null
}

# ─── checkpoint_prompt_block <manifest> <state_dir> ──────────────────────────
# The engine-owned prompt block for a declaring stage: the literal path, the
# instruction, and the prior attempt's body when one exists. Empty output when
# the stage declares no checkpoint — a non-declaring stage's prompt must stay
# byte-identical to what it is today.
checkpoint_prompt_block() {
    local manifest="$1" state_dir="$2"
    local cp_path; cp_path="$(_checkpoint_declared_path "$manifest" "$state_dir")"
    [[ -n "$cp_path" ]] || return 0

    local prior; prior="$(_checkpoint_prior_body "$cp_path")"

    printf '%s\n' "$_ZB_CHECKPOINT_MARKER"
    printf '\n'
    printf 'You have a bounded budget and may run out of it before you finish.\n'
    printf 'If that happens, the ONLY thing that survives is this file:\n\n'
    printf '  %s\n\n' "$cp_path"
    printf 'As you work — not at the end — append to it, in plain prose:\n'
    printf '  - each file you read and the one thing it told you;\n'
    printf '  - each conclusion you have reached, and what is still unresolved;\n'
    printf '  - what you would do next if you had to stop right now.\n\n'
    printf 'Write it with your normal file tools. It is outside the repository, so\n'
    printf 'it will not appear in any diff and cannot violate your scope. Keep it\n'
    printf 'short and factual — a handover note, not a transcript.\n'
    printf 'It does NOT replace your required output; produce that as instructed.\n'

    if [[ -n "${prior//[[:space:]]/}" ]]; then
        printf '\n### PRIOR EXPLORATION (resumed from checkpoint)\n\n'
        printf 'A previous attempt at this stage ran out of budget. This is what it\n'
        printf 'recorded. Build on it — do NOT re-derive it from scratch.\n\n'
        printf '%s\n' "$prior"
    fi
}
