#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild artifact-render — registry-pattern markdown renderer (ADR-018)   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Provides a registry of artifact renderers so plugins/stages can declare a
# canonical id (plan, diff, review, …) and emit a markdown shape for LLM
# consumption and banner display. Built-in renderers cover plan.json /
# diff.patch / review.json. New stages register their own via
# `register_artifact_renderer` — no edits to this file required.
#
# Public API:
#   register_artifact_renderer <id> <fn>   # idempotent; rc=2 on conflict
#   render_artifact <id> <input>           # dispatch; passthrough on miss
#   artifact_renderer_for <id>             # prints fn name, rc=1 if unknown
#
# Convention: built-in renderer fns are named render_<id>_md.
#
# Sourced library: do not set -euo pipefail (would leak to caller).

[[ -n "${_ZBUILD_ARTIFACT_RENDER_LOADED:-}" ]] && return 0
_ZBUILD_ARTIFACT_RENDER_LOADED=1

_ZBUILD_ARTIFACT_RENDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./compat.sh
source "$_ZBUILD_ARTIFACT_RENDER_DIR/compat.sh"

# Registry — Bash 5 associative array (Bash 5 enforced by compat.sh).
declare -gA _ARTIFACT_RENDERERS=()

# ─── register_artifact_renderer <id> <fn> ────────────────────────────────────
# Idempotent for the same (id, fn) pair. Returns rc=2 if <id> is already bound
# to a DIFFERENT fn unless ZBUILD_ARTIFACT_RENDERER_FORCE=1 is set.
register_artifact_renderer() {
    local id="${1:-}" fn="${2:-}"
    if [[ -z "$id" || -z "$fn" ]]; then
        printf 'register_artifact_renderer: usage: <id> <fn>\n' >&2
        return 2
    fi
    if [[ -n "${_ARTIFACT_RENDERERS[$id]:-}" ]]; then
        if [[ "${_ARTIFACT_RENDERERS[$id]}" == "$fn" ]]; then
            return 0
        fi
        if [[ "${ZBUILD_ARTIFACT_RENDERER_FORCE:-0}" == "1" ]]; then
            _ARTIFACT_RENDERERS[$id]="$fn"
            return 0
        fi
        printf 'register_artifact_renderer: conflict for id=%s (existing=%s, new=%s); set ZBUILD_ARTIFACT_RENDERER_FORCE=1 to override\n' \
            "$id" "${_ARTIFACT_RENDERERS[$id]}" "$fn" >&2
        return 2
    fi
    _ARTIFACT_RENDERERS[$id]="$fn"
    return 0
}

# ─── artifact_renderer_for <id> — print fn name or rc=1 ──────────────────────
artifact_renderer_for() {
    local id="${1:-}"
    [[ -z "$id" ]] && return 1
    local fn="${_ARTIFACT_RENDERERS[$id]:-}"
    [[ -z "$fn" ]] && return 1
    printf '%s' "$fn"
}

# ─── render_artifact <id> <input> ────────────────────────────────────────────
# Dispatches to the renderer registered for <id>. Unknown id OR renderer rc!=0
# → raw passthrough (rc=0) + best-effort stage.io.render.fallback event.
render_artifact() {
    local id="${1:-}" input="${2:-}"
    if [[ -z "$id" ]]; then
        printf '%s' "$input"
        return 0
    fi
    local fn="${_ARTIFACT_RENDERERS[$id]:-}"
    if [[ -z "$fn" ]]; then
        if declare -f eb_emit_event >/dev/null 2>&1; then
            eb_emit_event "stage.io.render.fallback" "artifact_id=$id" "reason=unknown_id" 2>/dev/null || true
        fi
        printf '%s' "$input"
        return 0
    fi
    local rendered rc
    rendered="$("$fn" "$input" 2>/dev/null)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        if declare -f eb_emit_event >/dev/null 2>&1; then
            eb_emit_event "stage.io.render.fallback" "artifact_id=$id" "reason=renderer_error" "fn=$fn" 2>/dev/null || true
        fi
        printf '%s' "$input"
        return 0
    fi
    printf '%s' "$rendered"
    return 0
}

# ─── _artifact_jq_or_passthrough <expr> <input> ──────────────────────────────
# Runs jq with the given expression; on parse failure returns input unchanged
# (rc=0).
_artifact_jq_or_passthrough() {
    local expr="$1" input="$2"
    local out
    if out="$(printf '%s' "$input" | jq -r "$expr" 2>/dev/null)"; then
        printf '%s' "$out"
        return 0
    fi
    printf '%s' "$input"
    return 0
}

# ─── _artifact_md_escape_inline <s> — single-line user-controlled string ─────
# Strips ANSI/CSI, collapses CR/LF to single space, escapes backticks so an
# attacker-controlled title can't break out of our intended block structure.
_artifact_md_escape_inline() {
    local s="$1"
    # #830: LC_ALL=C so sed treats input as raw bytes; otherwise non-UTF-8
    # fragments in attacker- or LLM-controlled titles abort with "RE error:
    # illegal byte sequence" on macOS BSD sed.
    s="$(printf '%s' "$s" | LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g; s/\x1b.//g')"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    s="${s//\`/\\\`}"
    printf '%s' "$s"
}

# ─── _artifact_md_escape_block <s> — multi-line user-controlled text ─────────
# Preserves newlines; strips ANSI escapes.
#
# #777: backtick escaping removed. The previous behavior escaped all backticks
# to `\\\`` which broke LLM-authored markdown bodies containing inline-code
# spans (the dogfood showed `assert_eq foo` rendering as literal `\\`assert_eq
# foo\\\``). Stage-io banner safety is provided by the outer banner's fence
# isolation, not by per-block backtick escaping. As a side effect this also
# fixes #776 — fence markers in llm-comment prose now render as ```` ``` ````
# instead of ```` \\\`\\\` ```` triggers, restoring readable forensic output.
_artifact_md_escape_block() {
    local s="$1"
    # #830: LC_ALL=C — same rationale as _artifact_md_escape_inline.
    s="$(printf '%s' "$s" | LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g; s/\x1b.//g')"
    printf '%s' "$s"
}

# ─── _artifact_pick_fence <body> — pick triple or quadruple backtick fence ──
_artifact_pick_fence() {
    local body="$1"
    if printf '%s' "$body" | grep -qE '`{3,}'; then
        printf '%s' '````'
    else
        printf '%s' '```'
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Helper: _artifact_split_prose_json — wraps extract_json_and_surrounding_prose
# and assigns the two slices into caller-provided variable names. Caller MUST
# `local _prose _json` (or equivalent) before calling. Uses sentinel-line
# parsing to tolerate embedded newlines on either slice. (#510)
# ═══════════════════════════════════════════════════════════════════════════
_artifact_split_prose_json() {
    local input="$1" out_prose_var="$2" out_json_var="$3"
    local raw
    raw="$(printf '%s' "$input" | extract_json_and_surrounding_prose)"
    local _p _j
    _p="$(printf '%s' "$raw" | awk '
        BEGIN { mode = "" }
        /^__PROSE__$/ { mode = "prose"; next }
        /^__JSON__$/  { mode = "json";  next }
        { if (mode == "prose") { if (out=="") out=$0; else out=out "\n" $0 } }
        END { printf "%s", out }
    ')"
    _j="$(printf '%s' "$raw" | awk '
        BEGIN { mode = "" }
        /^__PROSE__$/ { mode = "prose"; next }
        /^__JSON__$/  { mode = "json";  next }
        { if (mode == "json")  { if (out=="") out=$0; else out=out "\n" $0 } }
        END { printf "%s", out }
    ')"
    printf -v "$out_prose_var" '%s' "$_p"
    printf -v "$out_json_var"  '%s' "$_j"
}

# ═══════════════════════════════════════════════════════════════════════════
# Helper: _artifact_emit_llm_comment — emit a ── llm comment ── block carrying
# escaped prose. No-op when prose is empty. (#510)
# ═══════════════════════════════════════════════════════════════════════════
_artifact_emit_llm_comment() {
    local prose="$1"
    [[ -z "$prose" ]] && return 0
    printf '\n── llm comment ──\n%s\n' "$(_artifact_md_escape_block "$prose")"
}

# ═══════════════════════════════════════════════════════════════════════════
# Built-in renderer: render_plan_md
# Input: plan.json text. Recognised fields: title, goal,
#        steps[{description, files, estimated_lines}], notes. Missing fields
#        are silently skipped (only what exists is rendered).
#
# #510: when the LLM emits prose alongside JSON in the same assistant turn
# (envelope mode separates turns but not in-turn prose), split the captured
# payload into rendered plan FIRST (eye-target priority) + a
# ── llm comment ── block carrying the surrounding prose. The pure-JSON happy
# path remains byte-identical so existing goldens are unchanged.
# ═══════════════════════════════════════════════════════════════════════════
render_plan_md() {
    local input="$1"
    if [[ -z "$input" ]]; then
        printf '_empty plan_'
        return 0
    fi

    # #510 split: peel prose around the LAST balanced top-level JSON object.
    local _prose _json
    _artifact_split_prose_json "$input" _prose _json

    # No balanced JSON found. Two sub-paths:
    #   (a) input contains a `{` → looks like malformed JSON; preserve the
    #       legacy fenced-raw-passthrough so the visual cue ("this was meant
    #       to be JSON but didn't parse") matches the pre-#510 contract.
    #       (Regression lock for P4 in artifact-render-plan-test.sh.)
    #   (b) input has no `{` at all → genuine prose-only payload; emit the
    #       placeholder heading + ── llm comment ── block.
    if [[ -z "$_json" ]]; then
        if [[ "$input" == *'{'* ]]; then
            local fence; fence="$(_artifact_pick_fence "$input")"
            printf '%s\n%s\n%s' "$fence" "$input" "$fence"
            return 0
        fi
        if [[ -n "$_prose" ]]; then
            printf '# Plan: (no JSON returned)'
            _artifact_emit_llm_comment "$_prose"
            return 0
        fi
        local fence; fence="$(_artifact_pick_fence "$input")"
        printf '%s\n%s\n%s' "$fence" "$input" "$fence"
        return 0
    fi

    # JSON slice exists but may still be malformed (slicer is brace-balanced,
    # not jq-validated). Fall back to fenced raw on parse failure — and if
    # there is surrounding prose, surface it in a comment block.
    if ! printf '%s' "$_json" | jq empty >/dev/null 2>&1; then
        local fence; fence="$(_artifact_pick_fence "$_json")"
        printf '%s\n%s\n%s' "$fence" "$_json" "$fence"
        _artifact_emit_llm_comment "$_prose"
        return 0
    fi

    # Happy path: render the structured plan from the JSON slice. Prose is
    # emitted AFTER the plan so the rendered artifact stays at the top of the
    # banner (eye-target priority).
    input="$_json"

    local title goal notes
    title="$(printf '%s' "$input" | jq -r '.title // empty' 2>/dev/null)"
    goal="$(printf '%s' "$input" | jq -r '.goal // empty' 2>/dev/null)"
    notes="$(printf '%s' "$input" | jq -r '.notes // empty' 2>/dev/null)"

    local heading_title
    if [[ -n "$title" ]]; then
        heading_title="$(_artifact_md_escape_inline "$title")"
    else
        heading_title='(untitled)'
    fi
    printf '# Plan: %s\n' "$heading_title"

    if [[ -n "$goal" ]]; then
        printf '\n**Goal:** %s\n' "$(_artifact_md_escape_inline "$goal")"
    fi

    local steps_len
    steps_len="$(printf '%s' "$input" | jq '.steps | if type=="array" then length else 0 end' 2>/dev/null || printf '0')"
    if [[ "$steps_len" -gt 0 ]] 2>/dev/null; then
        printf '\n## Steps\n'
        local i=0
        while [[ $i -lt $steps_len ]]; do
            local desc files_json files_count est
            desc="$(printf '%s' "$input" | jq -r ".steps[$i].description // empty" 2>/dev/null)"
            est="$(printf '%s' "$input" | jq -r ".steps[$i].estimated_lines // empty" 2>/dev/null)"
            files_json="$(printf '%s' "$input" | jq -c ".steps[$i].files // []" 2>/dev/null)"
            files_count="$(printf '%s' "$files_json" | jq 'if type=="array" then length else 0 end' 2>/dev/null || printf '0')"

            local num=$((i + 1))
            if [[ -n "$desc" ]]; then
                printf '%d. %s\n' "$num" "$(_artifact_md_escape_inline "$desc")"
            else
                printf '%d. (no description)\n' "$num"
            fi
            if [[ "$files_count" -gt 0 ]] 2>/dev/null; then
                local files_line=""
                local j=0
                while [[ $j -lt $files_count ]]; do
                    local f
                    f="$(printf '%s' "$files_json" | jq -r ".[$j]" 2>/dev/null)"
                    f="$(_artifact_md_escape_inline "$f")"
                    if [[ -z "$files_line" ]]; then
                        files_line="\`$f\`"
                    else
                        files_line="${files_line}, \`$f\`"
                    fi
                    j=$((j + 1))
                done
                printf '   - Files: %s\n' "$files_line"
            fi
            if [[ -n "$est" && "$est" != "null" ]]; then
                printf '   - Estimated lines: %s\n' "$(_artifact_md_escape_inline "$est")"
            fi
            i=$((i + 1))
        done
    fi

    if [[ -n "$notes" ]]; then
        printf '\n## Notes\n%s\n' "$(_artifact_md_escape_block "$notes")"
    fi

    # #510: append surrounding prose as a ── llm comment ── block (no-op when
    # _prose is empty so the pure-JSON happy path is byte-identical).
    _artifact_emit_llm_comment "$_prose"
}

# ═══════════════════════════════════════════════════════════════════════════
# Built-in renderer: render_diff_md
# Input: a unified diff. Splits per-file on `^diff --git a/<a> b/<b>`. Emits a
# `## <path>` heading per file; renames → `## a/x → a/y`; deletes append
# ` (deleted)`; new files append ` (new)`. Binary diffs render as the
# `_binary changes_` placeholder. Body is wrapped in a ```diff fence and
# escalates to a 4-backtick fence if the body contains ``` anywhere (e.g.
# diffing a markdown file with code fences). Empty input → `_no changes_`.
#
# The awk pass emits ASCII " -> " for rename arrows for awk-variant
# portability; a sed pass rewrites to a unicode " → " in the final output.
# ═══════════════════════════════════════════════════════════════════════════
render_diff_md() {
    local input="$1"
    if [[ -z "${input//[[:space:]]/}" ]]; then
        printf '_no changes_'
        return 0
    fi
    if ! printf '%s' "$input" | grep -q '^diff --git '; then
        local fence; fence="$(_artifact_pick_fence "$input")"
        printf '%s diff\n%s\n%s' "$fence" "$input" "$fence"
        return 0
    fi
    _artifact_diff_awk "$input" | sed -e 's/ -> / → /g' | _artifact_strip_trailing_blank
}

_artifact_strip_trailing_blank() {
    awk 'BEGIN{prev=""; have=0}
         { if (have) print prev; prev=$0; have=1 }
         END { if (have && prev != "") print prev }'
}

_artifact_diff_awk() {
    local input="$1"
    printf '%s' "$input" | awk '
        BEGIN { block = ""; have = 0 }
        function flush_block(   n, lines, first, rest, p, hdr_a, hdr_b,
                                is_new, is_del, is_bin, is_rename,
                                fence, k, end) {
            if (!have) return
            n = split(block, lines, "\n")
            first = lines[1]
            hdr_a = ""; hdr_b = ""
            rest = substr(first, length("diff --git a/") + 1)
            p = index(rest, " b/")
            if (p > 0) {
                hdr_a = substr(rest, 1, p - 1)
                hdr_b = substr(rest, p + 3)
            }
            is_new = 0; is_del = 0; is_bin = 0; is_rename = 0
            for (k = 1; k <= n; k++) {
                if (lines[k] ~ /^new file mode /)      is_new = 1
                if (lines[k] ~ /^deleted file mode /)  is_del = 1
                if (lines[k] ~ /^Binary files /)       is_bin = 1
                if (lines[k] ~ /^GIT binary patch/)    is_bin = 1
                if (lines[k] ~ /^rename from /)        is_rename = 1
                if (lines[k] ~ /^rename to /)          is_rename = 1
            }
            if (is_rename && hdr_a != hdr_b) {
                printf("## a/%s -> a/%s\n", hdr_a, hdr_b)
            } else if (is_del) {
                printf("## a/%s (deleted)\n", hdr_a)
            } else if (is_new) {
                printf("## a/%s (new)\n", hdr_b)
            } else {
                printf("## a/%s\n", hdr_b)
            }
            if (is_bin) {
                print "_binary changes_"
                printf("\n")
                return
            }
            # Pick triple- or quad-backtick fence. Escalate when body contains
            # ``` anywhere (covers `+```code```` lines and full-fence content).
            fence = "```"
            for (k = 1; k <= n; k++) {
                if (lines[k] ~ /```/) { fence = "````"; break }
            }
            printf("%sdiff\n", fence)
            end = n
            while (end > 1 && lines[end] == "") end--
            for (k = 1; k <= end; k++) print lines[k]
            printf("%s\n\n", fence)
        }
        /^diff --git / {
            flush_block()
            block = $0
            have = 1
            next
        }
        {
            if (have) block = block "\n" $0
        }
        END { flush_block() }
    '
}

# ═══════════════════════════════════════════════════════════════════════════
# Built-in renderer: render_review_md
# Input: review.json (verdict, confidence, issues[], summary).
# ═══════════════════════════════════════════════════════════════════════════
render_review_md() {
    local input="$1"
    if [[ -z "$input" ]]; then
        printf '_empty review_'
        return 0
    fi

    # #510 split — see render_plan_md for the rationale.
    local _prose _json
    _artifact_split_prose_json "$input" _prose _json

    if [[ -z "$_json" ]]; then
        # See render_plan_md for the malformed-JSON vs prose-only rationale.
        if [[ "$input" == *'{'* ]]; then
            local fence; fence="$(_artifact_pick_fence "$input")"
            printf '%s\n%s\n%s' "$fence" "$input" "$fence"
            return 0
        fi
        if [[ -n "$_prose" ]]; then
            printf '# Review: (no JSON returned)'
            _artifact_emit_llm_comment "$_prose"
            return 0
        fi
        local fence; fence="$(_artifact_pick_fence "$input")"
        printf '%s\n%s\n%s' "$fence" "$input" "$fence"
        return 0
    fi

    if ! printf '%s' "$_json" | jq empty >/dev/null 2>&1; then
        local fence; fence="$(_artifact_pick_fence "$_json")"
        printf '%s\n%s\n%s' "$fence" "$_json" "$fence"
        _artifact_emit_llm_comment "$_prose"
        return 0
    fi

    input="$_json"

    local verdict confidence summary
    verdict="$(printf '%s' "$input" | jq -r '.verdict // empty' 2>/dev/null)"
    confidence="$(printf '%s' "$input" | jq -r '.confidence // empty' 2>/dev/null)"
    summary="$(printf '%s' "$input" | jq -r '.summary // empty' 2>/dev/null)"

    printf '# Review\n'
    if [[ -n "$verdict" ]]; then
        printf '\n**Verdict:** %s\n' "$(_artifact_md_escape_inline "$verdict")"
    fi
    if [[ -n "$confidence" ]]; then
        printf '**Confidence:** %s\n' "$(_artifact_md_escape_inline "$confidence")"
    fi

    local issues_len
    issues_len="$(printf '%s' "$input" | jq '.issues | if type=="array" then length else 0 end' 2>/dev/null || printf '0')"
    if [[ "$issues_len" -gt 0 ]] 2>/dev/null; then
        printf '\n## Issues\n'
        local i=0
        while [[ $i -lt $issues_len ]]; do
            local issue
            issue="$(printf '%s' "$input" | jq -r ".issues[$i] // empty" 2>/dev/null)"
            if [[ -n "$issue" ]]; then
                printf -- '- %s\n' "$(_artifact_md_escape_inline "$issue")"
            fi
            i=$((i + 1))
        done
    fi

    if [[ -n "$summary" ]]; then
        printf '\n## Summary\n%s\n' "$(_artifact_md_escape_block "$summary")"
    fi

    # #510: append surrounding prose as a ── llm comment ── block (no-op when
    # _prose is empty so the pure-JSON happy path is byte-identical).
    _artifact_emit_llm_comment "$_prose"
}

# ═══════════════════════════════════════════════════════════════════════════
# Built-in renderer: render_test_assessment_md (#567)
# Input: test-assessment.json. Fields: verdict (pass|fail|error|inconclusive),
#        summary, diagnosis, required_changes[], agrees_with_build_complete,
#        branch_numstat, failure_summary_md, iter. Renders heading + verdict,
#        emits the LLM-authored `failure_summary_md` verbatim as the body, and
#        bullets `required_changes`. Surrounding prose surfaces as a
#        ── llm comment ── trailing block (parity with render_plan_md).
# ═══════════════════════════════════════════════════════════════════════════
render_test_assessment_md() {
    local input="$1"
    if [[ -z "$input" ]]; then
        printf '_empty test assessment_'
        return 0
    fi

    local _prose _json
    _artifact_split_prose_json "$input" _prose _json

    if [[ -z "$_json" ]]; then
        if [[ "$input" == *'{'* ]]; then
            local fence; fence="$(_artifact_pick_fence "$input")"
            printf '%s\n%s\n%s' "$fence" "$input" "$fence"
            return 0
        fi
        if [[ -n "$_prose" ]]; then
            printf '# Test Assessment: (no JSON returned)'
            _artifact_emit_llm_comment "$_prose"
            return 0
        fi
        local fence; fence="$(_artifact_pick_fence "$input")"
        printf '%s\n%s\n%s' "$fence" "$input" "$fence"
        return 0
    fi

    if ! printf '%s' "$_json" | jq empty >/dev/null 2>&1; then
        local fence; fence="$(_artifact_pick_fence "$_json")"
        printf '%s\n%s\n%s' "$fence" "$_json" "$fence"
        _artifact_emit_llm_comment "$_prose"
        return 0
    fi

    input="$_json"

    local verdict summary diagnosis numstat agrees failure_md iter
    verdict="$(printf '%s' "$input" | jq -r '.verdict // empty' 2>/dev/null)"
    summary="$(printf '%s' "$input" | jq -r '.summary // empty' 2>/dev/null)"
    diagnosis="$(printf '%s' "$input" | jq -r '.diagnosis // empty' 2>/dev/null)"
    numstat="$(printf '%s' "$input" | jq -r '.branch_numstat // empty' 2>/dev/null)"
    agrees="$(printf '%s' "$input" | jq -r '.agrees_with_build_complete // empty' 2>/dev/null)"
    failure_md="$(printf '%s' "$input" | jq -r '.failure_summary_md // empty' 2>/dev/null)"
    iter="$(printf '%s' "$input" | jq -r '.iter // empty' 2>/dev/null)"

    local heading_verdict
    if [[ -n "$verdict" ]]; then
        heading_verdict="$(_artifact_md_escape_inline "$verdict")"
    else
        heading_verdict='(no verdict)'
    fi
    printf '# Test Assessment: %s\n' "$heading_verdict"

    if [[ -n "$iter" && "$iter" != "null" ]]; then
        printf '\n**Iter:** %s\n' "$(_artifact_md_escape_inline "$iter")"
    fi
    if [[ -n "$agrees" && "$agrees" != "null" ]]; then
        printf '**Agrees with build complete:** %s\n' "$(_artifact_md_escape_inline "$agrees")"
    fi
    if [[ -n "$numstat" ]]; then
        printf '**Branch numstat:** %s\n' "$(_artifact_md_escape_inline "$numstat")"
    fi

    if [[ -n "$summary" ]]; then
        printf '\n## Summary\n%s\n' "$(_artifact_md_escape_block "$summary")"
    fi
    if [[ -n "$diagnosis" ]]; then
        printf '\n## Diagnosis\n%s\n' "$(_artifact_md_escape_block "$diagnosis")"
    fi

    local rc_len
    rc_len="$(printf '%s' "$input" | jq '.required_changes | if type=="array" then length else 0 end' 2>/dev/null || printf '0')"
    if [[ "$rc_len" -gt 0 ]] 2>/dev/null; then
        printf '\n## Required Changes\n'
        local i=0
        while [[ $i -lt $rc_len ]]; do
            local item
            item="$(printf '%s' "$input" | jq -r ".required_changes[$i] // empty" 2>/dev/null)"
            if [[ -n "$item" ]]; then
                printf -- '- %s\n' "$(_artifact_md_escape_inline "$item")"
            fi
            i=$((i + 1))
        done
    fi

    if [[ -n "$failure_md" ]]; then
        printf '\n## Failure Summary\n%s\n' "$(_artifact_md_escape_block "$failure_md")"
    fi

    _artifact_emit_llm_comment "$_prose"
}

# ─── render_impact_md (#768) ─────────────────────────────────────────────────
# Renders the impact stage's JSON envelope to a one-line summary header
# (Impact: verdict=<v>, missing=<n>) followed by the structured
# `impact_feedback_md` field as raw markdown. Empty feedback (verdict=complete
# with no gaps) renders the header only. Prose preamble (contract violations
# from haiku at T1, see #767) is preserved as an LLM comment for forensics.
render_impact_md() {
    local input="$1"
    if [[ -z "$input" ]]; then
        printf '_empty impact_'
        return 0
    fi

    local _prose _json
    _artifact_split_prose_json "$input" _prose _json

    if [[ -z "$_json" ]]; then
        if [[ "$input" == *'{'* ]]; then
            local fence; fence="$(_artifact_pick_fence "$input")"
            printf '%s\n%s\n%s' "$fence" "$input" "$fence"
            return 0
        fi
        if [[ -n "$_prose" ]]; then
            printf '# Impact: (no JSON returned)'
            _artifact_emit_llm_comment "$_prose"
            return 0
        fi
        local fence; fence="$(_artifact_pick_fence "$input")"
        printf '%s\n%s\n%s' "$fence" "$input" "$fence"
        return 0
    fi

    if ! printf '%s' "$_json" | jq empty >/dev/null 2>&1; then
        local fence; fence="$(_artifact_pick_fence "$_json")"
        printf '%s\n%s\n%s' "$fence" "$_json" "$fence"
        _artifact_emit_llm_comment "$_prose"
        return 0
    fi

    input="$_json"

    local verdict missing_count feedback_md
    verdict="$(printf '%s' "$input" | jq -r '.verdict // empty' 2>/dev/null)"
    missing_count="$(printf '%s' "$input" | jq -r '.missing | if type=="array" then length else 0 end' 2>/dev/null || printf '0')"
    feedback_md="$(printf '%s' "$input" | jq -r '.impact_feedback_md // empty' 2>/dev/null)"

    printf 'Impact: verdict=%s, missing=%s\n' \
        "$(_artifact_md_escape_inline "${verdict:-unknown}")" \
        "$(_artifact_md_escape_inline "${missing_count:-0}")"

    if [[ -n "$feedback_md" ]]; then
        printf '\n%s\n' "$(_artifact_md_escape_block "$feedback_md")"
    fi

    _artifact_emit_llm_comment "$_prose"
}

# ═══════════════════════════════════════════════════════════════════════════
# Built-in renderer: render_review_report_md (#972 / ADR-038)
# Input: review-report.json. Fields: merge_readiness (ready|advisory|
#        needs_attention), summary, lenses[] ({name, score, findings[]}),
#        findings[] (flat de-duped: {file, category, severity, line, lenses[],
#        messages[]}). Renders the readiness header + summary, a per-lens
#        findings section, and the de-duped merge-readiness findings.
# NOTE: the per-lens bullet list builds an ARRAY before join() — the un-bracketed
#       stream form silently blanked the section (PR #1004 bug, commit 7995000).
# ═══════════════════════════════════════════════════════════════════════════
render_review_report_md() {
    local input="$1"
    if [[ -z "$input" ]]; then
        printf '_empty review report_'
        return 0
    fi
    if ! printf '%s' "$input" | jq empty >/dev/null 2>&1; then
        local fence; fence="$(_artifact_pick_fence "$input")"
        printf '%s\n%s\n%s' "$fence" "$input" "$fence"
        return 0
    fi

    local readiness summary escalation_note
    readiness="$(printf '%s' "$input" | jq -r '.merge_readiness // "advisory"' 2>/dev/null)"
    summary="$(printf '%s' "$input" | jq -r '.summary // empty' 2>/dev/null)"
    escalation_note="$(printf '%s' "$input" | jq -r '.escalation_note // empty' 2>/dev/null)"

    printf '## Review Report\n'
    printf '\n**Merge Readiness:** %s\n' "$(_artifact_md_escape_inline "${readiness:-advisory}")"
    if [[ -n "$summary" ]]; then
        printf '\n%s\n' "$(_artifact_md_escape_block "$summary")"
    fi
    if [[ -n "$escalation_note" && "$escalation_note" != "null" ]]; then
        printf '\n> **Advisory:** %s\n' "$(_artifact_md_escape_inline "$escalation_note")"
    fi

    # esc mirrors _artifact_md_escape_inline in jq: strip ANSI/CSI, collapse
    # CR/LF to a space, escape backticks — LLM-controlled fields (.file/.message)
    # must not break the markdown layout or inject formatting (Copilot #1028).
    local _jq_esc='def esc: tostring
        | gsub("\u001b\\[[0-9;?]*[A-Za-z~]"; "")
        | gsub("\u001b."; "")
        | gsub("[\r\n]"; " ")
        | gsub("`"; "\\`");'

    printf '\n### Lens Findings\n'
    # Bracketed array → join (NOT a bare stream piped into join — that silently
    # blanks the section, the PR #1004 regression this guards against).
    printf '%s' "$input" | jq -r "$_jq_esc"'
        .lenses[] |
        "\n#### \(.name|esc) (score: \(.score)/10)\n" +
        ( if ((.findings // []) | length) > 0
          then ( [ .findings[] |
                   "- [\(.severity|esc)] \(.file|esc)" +
                   (if .line then ":\(.line)" else "" end) +
                   " — \(.message|esc)" ] | join("\n") )
          else "No findings." end )' 2>/dev/null || true

    local flat_len
    flat_len="$(printf '%s' "$input" | jq -r '.findings | if type=="array" then length else 0 end' 2>/dev/null || printf '0')"
    if [[ "$flat_len" -gt 0 ]] 2>/dev/null; then
        printf '\n\n### Merge-Readiness Findings (de-duped)\n'
        printf '%s' "$input" | jq -r "$_jq_esc"'
            [ .findings[] |
              "- [\(.severity|esc)] \(.file|esc)" +
              (if .line then ":\(.line)" else "" end) +
              " — \((.messages | map(esc) | join("; ")))" +
              " _(lenses: \((.lenses | map(esc) | join(", "))))_" ] | join("\n")' 2>/dev/null || true
        printf '\n'
    fi
}

# ─── Register built-ins (idempotent) ────────────────────────────────────────
register_artifact_renderer "plan"            "render_plan_md"            >/dev/null 2>&1 || true
register_artifact_renderer "diff"            "render_diff_md"            >/dev/null 2>&1 || true
register_artifact_renderer "review"          "render_review_md"          >/dev/null 2>&1 || true
register_artifact_renderer "test_assessment" "render_test_assessment_md" >/dev/null 2>&1 || true
register_artifact_renderer "impact"          "render_impact_md"          >/dev/null 2>&1 || true
register_artifact_renderer "review_report"   "render_review_report_md"   >/dev/null 2>&1 || true
