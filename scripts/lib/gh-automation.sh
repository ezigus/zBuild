#!/usr/bin/env bash
# Shared helpers for GitHub-automation scripts. Used by deferred-tracker
# and manifest-sync. Scoped per #540 review: extract only genuinely shared
# logic (idempotency-log row check + append); single-caller helpers stay
# in their owning script.

[[ -n "${_ZBUILD_GHA_LOADED:-}" ]] && return 0
_ZBUILD_GHA_LOADED=1

_ZBUILD_GHA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
source "$_ZBUILD_GHA_DIR/helpers.sh"

# Returns 0 if PR number is present in a `| #N |`-style markdown log.
gha_is_already_scanned() {
    local pr_num="$1"
    local log_path="$2"
    [[ -f "$log_path" ]] || return 1
    grep -qE "^\| #${pr_num} \|" "$log_path"
}

# Appends a row to a markdown idempotency log if not already present.
# Bootstraps the file via the provided header callback when missing.
# Args:
#   $1 — log path
#   $2 — header callback name (function taking $log_path as arg, writes header)
#   $3 — column-3 value (date or status; positional)
#   $4… — entries in "pr_num|title" format
gha_append_scanned_log() {
    local log_path="$1"
    local header_fn="$2"
    local col3_value="$3"
    shift 3
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$log_path" ]]; then
        mkdir -p "$(dirname "$log_path")"
        "$header_fn" "$log_path" "$now"
    else
        zbuild_sed_inplace "s|^_Last updated:.*|_Last updated: ${now}_|" "$log_path"
    fi
    local entry pr_num title
    for entry in "$@"; do
        IFS='|' read -r pr_num title <<< "$entry"
        [[ -z "$pr_num" ]] && continue
        if grep -qE "^\| #${pr_num} \|" "$log_path"; then
            continue
        fi
        printf '| #%s | %s | %s |\n' "$pr_num" "$title" "$col3_value" >> "$log_path"
    done
}

# Jaccard token-similarity for issue-dedup scans (#558 / ADR-020 v2).
# Returns 0.00–1.00 on stdout via printf '%.2f'. Bash 3.2 + POSIX awk.
gha_compute_similarity() {
    local text_a="${1:-}"
    local text_b="${2:-}"
    local score
    score="$(printf '%s\n__ZBUILD_SEP__\n%s\n' "$text_a" "$text_b" | awk '
        BEGIN {
            split("the and that this with from when what where will should " \
                  "would could into also just more some like such these those " \
                  "after before while about then than have been they their " \
                  "there which", sw, " ")
            for (i in sw) stop[sw[i]] = 1
            side = "A"
        }
        /^__ZBUILD_SEP__$/ { side = "B"; next }
        {
            line = tolower($0)
            n = split(line, toks, /[^[:alnum:]]+/)
            for (i = 1; i <= n; i++) {
                t = toks[i]
                if (length(t) < 4) continue
                if (t in stop) continue
                if (side == "A") setA[t] = 1
                else             setB[t] = 1
            }
        }
        END {
            inter = 0; union = 0
            for (t in setA) { union++; if (t in setB) inter++ }
            for (t in setB) if (!(t in setA)) union++
            if (union == 0) { printf "0.00"; exit }
            printf "%.4f", inter / union
        }
    ')" || score="0.00"
    [[ -z "$score" ]] && score="0.00"
    printf '%.2f\n' "$score"
}

# True (rc=0) when $score >= $threshold; both are %.2f decimal strings.
# Avoids bash integer-compare on decimals.
gha_score_meets_threshold() {
    local score="$1"
    local threshold="$2"
    awk -v s="$score" -v t="$threshold" 'BEGIN{exit !(s>=t)}'
}

# LLM tiebreaker for borderline Jaccard scores (#559 / ADR-020 v2).
# Returns "<score>|<marker>" where marker is _LLM_OK or a failure code.
# NEVER exits non-zero; NEVER returns empty score. Fail-open by contract.
#
# This helper calls `claude` CLI directly rather than route_to_model because:
# 1. Inputs are public GitHub issue text, not codebase content
# 2. This is automation tooling, not a pipeline stage
# 3. route_to_model requires RUN_ID / events.jsonl / redaction.applied
#    precondition that doesn't fit the workflow-script use case
# ADR-004's chokepoint applies to pipeline-stage LLM calls; ADR-020 v2
# documents this deviation.
gha_compute_similarity_llm() {
    local text_a="${1:-}"
    local text_b="${2:-}"
    local jaccard_score="${3:-0.00}"
    local enabled="${LLM_TIEBREAKER_ENABLED:-1}"
    local timeout_secs="${LLM_TIEBREAKER_TIMEOUT_SECS:-15}"
    local cache_dir="${LLM_TIEBREAKER_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/llm-similarity-cache}"
    # Per ADR-003: no hardcoded model names. Resolve T1 (cheapest tier) from
    # config/models.json if available; fall back to claude CLI's default.
    local model_id="${LLM_TIEBREAKER_MODEL:-}"
    if [[ -z "$model_id" ]]; then
        local models_file="${ZBUILD_MODELS_FILE:-${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/config/models.json}"
        if [[ -f "$models_file" ]]; then
            model_id="$(jq -r '.tiers.T1.candidates[0].id // empty' "$models_file" 2>/dev/null || echo "")"
        fi
    fi

    # Disabled by env → fail open
    if [[ "$enabled" != "1" ]]; then
        printf '%s|_LLM_UNAVAILABLE_DISABLED\n' "$jaccard_score"
        return 0
    fi

    # No claude CLI → fail open
    if ! command -v claude >/dev/null 2>&1; then
        printf '%s|_LLM_UNAVAILABLE_NO_CLI\n' "$jaccard_score"
        return 0
    fi

    # Missing credentials (claude reads ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN)
    if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        printf '%s|_LLM_UNAVAILABLE_NO_CREDS\n' "$jaccard_score"
        return 0
    fi

    # Cache check: SHA256(text_a + sep + text_b)
    mkdir -p "$cache_dir" 2>/dev/null || true
    local cache_key cache_file
    cache_key="$(printf '%s\n__SEP__\n%s' "$text_a" "$text_b" | shasum -a 256 2>/dev/null | awk '{print $1}')"
    if [[ -n "$cache_key" ]]; then
        cache_file="$cache_dir/$cache_key"
        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Build prompt
    local prompt
    prompt="$(cat <<EOF
You compare two GitHub issue descriptions to determine if they describe the same underlying work. Return ONLY a JSON object with a single key "score" between 0.00 (clearly different) and 1.00 (clearly the same). No prose.

Item A:
${text_a}

Item B:
${text_b}
EOF
)"

    # Invoke claude with timeout; capture rc explicitly
    local raw_response rc=0 timeout_cmd=""
    if command -v gtimeout >/dev/null 2>&1; then
        timeout_cmd="gtimeout"
    elif command -v timeout >/dev/null 2>&1; then
        timeout_cmd="timeout"
    fi

    local model_args=()
    [[ -n "$model_id" ]] && model_args=(--model "$model_id")
    if [[ -n "$timeout_cmd" ]]; then
        raw_response="$("$timeout_cmd" "$timeout_secs" claude "${model_args[@]}" --output-format json --print "$prompt" 2>/dev/null)" || rc=$?
    else
        raw_response="$(claude "${model_args[@]}" --output-format json --print "$prompt" 2>/dev/null)" || rc=$?
    fi

    # Timeout signal: 124 from coreutils timeout, 143 (128+15) from BSD
    if [[ "$rc" -eq 124 || "$rc" -eq 143 ]]; then
        printf '%s|_LLM_FAILED_TIMEOUT\n' "$jaccard_score"
        return 0
    fi
    if [[ "$rc" -ne 0 ]]; then
        printf '%s|_LLM_FAILED_NETWORK\n' "$jaccard_score"
        return 0
    fi
    if [[ -z "$raw_response" ]]; then
        printf '%s|_LLM_FAILED_EMPTY\n' "$jaccard_score"
        return 0
    fi

    # Extract .result from envelope, then first JSON object, then .score
    local inner_text llm_score
    inner_text="$(printf '%s' "$raw_response" | jq -r '.result // ""' 2>/dev/null)" || inner_text=""
    [[ -z "$inner_text" ]] && inner_text="$raw_response"  # fallback if not envelope
    llm_score="$(printf '%s' "$inner_text" | extract_first_json_object 2>/dev/null | jq -r '.score // empty' 2>/dev/null)" || llm_score=""

    # Strict decimal validation: awk's numeric coercion accepts "0foo"/"0.75 likely"
    # as 0/0.75 numerically. Reject anything that isn't a clean 0.NN or 1.00 string.
    # (Codex review #565 caught this — would silently turn malformed LLM output
    # into a trusted similarity score, violating fail-open contract.)
    if [[ -z "$llm_score" ]] || ! [[ "$llm_score" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
        printf '%s|_LLM_FAILED_PARSE\n' "$jaccard_score"
        return 0
    fi
    if ! awk -v s="$llm_score" 'BEGIN{exit !(s>=0 && s<=1)}'; then
        printf '%s|_LLM_FAILED_PARSE\n' "$jaccard_score"
        return 0
    fi

    local result
    result="$(printf '%.2f|_LLM_OK\n' "$llm_score")"
    [[ -n "$cache_key" ]] && printf '%s\n' "$result" > "$cache_file" 2>/dev/null || true
    printf '%s\n' "$result"
}

# Converts a similarity marker to operator-readable annotation text.
gha_llm_marker_to_annotation() {
    local marker="$1"
    case "$marker" in
        _LLM_OK) printf '' ;;
        _LLM_UNAVAILABLE_DISABLED) printf 'LLM verification disabled' ;;
        _LLM_UNAVAILABLE_NO_CLI) printf 'LLM verification unavailable: claude CLI not installed' ;;
        _LLM_UNAVAILABLE_NO_CREDS) printf 'LLM verification unavailable: credentials not configured' ;;
        _LLM_FAILED_TIMEOUT) printf 'LLM check timed out' ;;
        _LLM_FAILED_NETWORK) printf 'LLM network error' ;;
        _LLM_FAILED_EMPTY) printf 'LLM returned empty response' ;;
        _LLM_FAILED_PARSE) printf 'LLM returned unparseable response' ;;
        _LLM_FAILED_RATE_LIMIT) printf 'LLM rate limited' ;;
        *) printf 'LLM check failed: %s' "$marker" ;;
    esac
}
