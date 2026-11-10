#!/usr/bin/env bash
# plugins/agent/build/lib/commit.sh — commit helpers for the build stage.
# Sourced by plugin.sh after shared libs (event-bus.sh, etc.) are loaded.

[[ -n "${_ZBUILD_BUILD_COMMIT_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_COMMIT_LOADED=1
# #2460: a reply is read in whole units; loaded here too, for a caller that
# sources this file alone.
declare -F zb_reply_join_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/reply-units.sh" 2>/dev/null || true

# _build_clean_msg_line <line> (#1329)
# Sanitize one commit-message line — strip control chars, trim whitespace,
# truncate to 72 chars.
_build_clean_msg_line() {
    printf '%s' "${1:-}" \
        | LC_ALL=C tr -d '\000-\037\177' \
        | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | cut -c1-72
}

# _build_parse_commit_summary <response> <plan_title> [iter_summaries] [iter_count]
# Compose the per-build git commit message. (#1329)
# When multi-iter AND >=2 distinct summaries: subject = plan_title, body =
# bullets. Otherwise: single-line from last COMMIT_SUMMARY / plan_title /
# synthetic default.
_build_parse_commit_summary() {
    local response="${1:-}"
    local plan_title="${2:-}"
    local iter_summaries="${3:-}"
    local iter_count="${4:-1}"
    [[ "$iter_count" =~ ^[0-9]+$ ]] || iter_count=1

    local -a summaries=()
    local line s is_dup
    if [[ -n "$iter_summaries" ]]; then
        while IFS= read -r line; do
            line="$(_build_clean_msg_line "$line")"
            [[ -z "$line" ]] && continue
            is_dup=0
            if [[ ${#summaries[@]} -gt 0 ]]; then
                for s in "${summaries[@]}"; do
                    [[ "$s" == "$line" ]] && { is_dup=1; break; }
                done
            fi
            [[ "$is_dup" -eq 0 ]] && summaries+=("$line")
        done <<< "$iter_summaries"
    else
        # #2460: a marker whose text is on the next line is read whole.
        declare -F zb_reply_join_v >/dev/null 2>&1 && zb_reply_join_v response "$response"
        line="$(printf '%s\n' "$response" \
            | tail -n 50 \
            | grep -E '^COMMIT_SUMMARY:[[:space:]]*(.+)$' \
            | tail -n 1 \
            | sed -E 's/^COMMIT_SUMMARY:[[:space:]]*//' \
            || true)"
        line="$(_build_clean_msg_line "$line")"
        [[ -n "$line" ]] && summaries+=("$line")
    fi

    local subject=""
    if [[ ${#summaries[@]} -gt 1 && "$iter_count" -gt 1 ]]; then
        subject="$(_build_clean_msg_line "$plan_title")"
        [[ -z "$subject" ]] && subject="${summaries[0]}"
    elif [[ ${#summaries[@]} -gt 0 ]]; then
        subject="${summaries[0]}"
    fi
    [[ -z "$subject" ]] && subject="$(_build_clean_msg_line "$plan_title")"
    [[ -z "$subject" ]] && subject="zbuild: build iter ${ZBUILD_CYCLE_ITER:-1}"

    if [[ ${#summaries[@]} -gt 1 && "$iter_count" -gt 1 ]]; then
        local body
        body="$(printf 'Build spanned %d inner iterations:' "$iter_count")"
        for s in "${summaries[@]}"; do
            body+=$'\n'"- $s"
        done
        printf '%s\n\n%s\n' "$subject" "$body"
    else
        printf '%s' "$subject"
    fi
}

# _build_commit_iteration — post-loop commit logic (#608).
# Args: $1=repo_root $2=unused $3=scope_violation $4=build_verdict
#   $5=response_text $6=plan_title $7=iter $8=iter_summaries $9=iter_count
# #2508 (ADR-030 §8): build has no file list. What it commits is every file it
# changed — the harvest marked the new ones intent-to-add, and left out the
# untracked files that were there before the run — except anything in the
# test folders, which it may not change (those were already put back).
_build_commit_iteration() {
    local repo_root="$1"
    local scope_violation="$3"
    local build_verdict="$4"
    local response_text="$5"
    local plan_title="$6"
    local iter="${7:-1}"
    local iter_summaries="${8:-}"
    local iter_count="${9:-1}"

    # A test-folder change does not skip the commit (#2185): it was already put
    # back, so what lands is the rest of build's work.
    : "$scope_violation" "$build_verdict"

    local -a add_args=() _gl=()
    local f _globs
    zb_test_path_globs_v _globs "$repo_root"
    read -ra _gl <<< "$_globs"
    while IFS= read -r -d '' f; do
        [[ -n "$f" ]] || continue
        [[ ${#_gl[@]} -gt 0 ]] && _zb_test_globs_match "$f" "${_gl[@]}" && continue
        add_args+=("$f")
    done < <(git -C "$repo_root" diff --name-only -z HEAD 2>/dev/null)

    git -C "$repo_root" reset -q 2>/dev/null || true

    if [[ ${#add_args[@]} -eq 0 ]]; then
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=empty_diff" "iter=$iter"
        return 0
    fi

    git -C "$repo_root" add -A -- "${add_args[@]}" 2>/dev/null || {
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=empty_diff" "iter=$iter"
        return 0
    }

    if git -C "$repo_root" diff --cached --quiet 2>/dev/null; then
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=empty_diff" "iter=$iter"
        return 0
    fi

    local commit_msg
    commit_msg="$(_build_parse_commit_summary "$response_text" "$plan_title" "$iter_summaries" "$iter_count")"

    if ! git -C "$repo_root" commit \
        --author "zbuild-pipeline <pipeline@local>" \
        --no-verify --quiet \
        -m "$commit_msg" 2>/dev/null; then
        warn "_build_commit_iteration: git commit failed in $repo_root"
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=commit_failed" "iter=$iter"
        return 0
    fi

    local sha
    sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo '')"
    emit_event "build.commit.created" "plugin=build" \
        "sha=$sha" "msg=$commit_msg" "iter=$iter"
    return 0
}
