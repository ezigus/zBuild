#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright discovery — Cross-Pipeline Real-Time Learning                ║
# ║  Enables knowledge sharing between concurrent pipelines via discovery     ║
# ║  channel: broadcast, query, inject, clean, status                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="3.6.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Dependency check ─────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: sw-discovery.sh requires 'jq'. Install with: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
fi

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── Discovery Storage ──────────────────────────────────────────────────────
DISCOVERIES_FILE="${HOME}/.shipwright/discoveries.jsonl"
DISCOVERIES_DIR="${HOME}/.shipwright/discoveries"
DISCOVERY_TTL_SECS=$((24 * 60 * 60))  # 24 hours default

# ─── Remote Discovery Server (optional) ─────────────────────────────────────
# Set via env var or daemon-config.json: "discovery_server_url"
DISCOVERY_SERVER_URL="${DISCOVERY_SERVER_URL:-}"
if [[ -z "$DISCOVERY_SERVER_URL" ]]; then
    if declare -f _load_daemon_config >/dev/null 2>&1; then
        DISCOVERY_SERVER_URL=$(_load_daemon_config | jq -r '.discovery_server_url // ""' 2>/dev/null || true)
    elif [[ -f ".claude/daemon-config.json" ]]; then
        DISCOVERY_SERVER_URL=$(jq -r '.discovery_server_url // ""' ".claude/daemon-config.json" 2>/dev/null || true)
    fi
fi

ensure_discoveries_dir() {
    mkdir -p "$DISCOVERIES_DIR"
}

get_seen_file() {
    local pipeline_id="$1"
    echo "${DISCOVERIES_DIR}/seen-${pipeline_id}.json"
}

# ─── Discovery Functions ───────────────────────────────────────────────────

# broadcast: write a new discovery event
broadcast_discovery() {
    local category="$1"
    local file_patterns="$2"
    local discovery_text="$3"
    local resolution="${4:-}"

    ensure_discoveries_dir

    local pipeline_id="${SHIPWRIGHT_PIPELINE_ID:-unknown}"

    # Use jq to build compact JSON (single line)
    local entry
    entry=$(jq -cn \
        --arg ts "$(now_iso)" \
        --argjson ts_epoch "$(now_epoch)" \
        --arg pipeline_id "$pipeline_id" \
        --arg category "$category" \
        --arg file_patterns "$file_patterns" \
        --arg discovery "$discovery_text" \
        --arg resolution "$resolution" \
        '{ts: $ts, ts_epoch: $ts_epoch, pipeline_id: $pipeline_id, category: $category, file_patterns: $file_patterns, discovery: $discovery, resolution: $resolution}')

    echo "$entry" >> "$DISCOVERIES_FILE"
    type rotate_jsonl >/dev/null 2>&1 && rotate_jsonl "$DISCOVERIES_FILE" 5000

    # Bridge: index discovery in ruflo for cross-pipeline semantic search.
    # Skip when REPO_HASH is unavailable — "unknown" namespace mixes discoveries
    # from unrelated repos and degrades cross-pipeline semantic search quality.
    if declare -f ruflo_store >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1 && \
       ruflo_available; then
        local _disc_ns_hash
        if _disc_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null); then
            local _disc_key="pipeline-discovery-$(date +%s)-$$"
            local _disc_content
            _disc_content=$(printf '%s' "$entry" | jq -sR . 2>/dev/null || true)
            if [[ -n "$_disc_content" ]]; then
                ruflo_store "$_disc_key" "$_disc_content" \
                    "pipeline-discovery-${_disc_ns_hash}" \
                    "discovery,cross-pipeline" 2>/dev/null || true
            fi
        fi
    fi

    # Fire-and-forget POST to remote discovery server if configured
    if [[ -n "${DISCOVERY_SERVER_URL:-}" ]]; then
        curl -sS -X POST "${DISCOVERY_SERVER_URL}/api/discoveries" \
            -H "Content-Type: application/json" \
            -d "$entry" \
            --max-time 5 >/dev/null 2>&1 &
    fi

    success "Broadcast discovery: ${category} (${file_patterns})"
}

# ─── Cross-Machine Discovery Sharing ───────────────────────────────────────

# Push local discoveries to shipwright-discoveries orphan branch for cross-machine sharing.
# Mirrors the ruflo-memory/shipwright-data orphan pattern. Fail-open.
sw_discovery_ci_push() {
    # Discoveries are now persisted via the pipeline's shipwright-data persist step.
    return 0
}

_sw_discovery_do_push() {
    local work_dir="$1"
    local repo_url
    repo_url=$(git remote get-url origin 2>/dev/null) || return 1
    (
        cd "$work_dir" || return 1
        git init -q -b shipwright-discoveries 2>/dev/null || git init -q
        git remote add origin "$repo_url" 2>/dev/null || true
        # Pull remote state if branch exists, merge with local discoveries
        local remote_jsonl=""
        if git fetch origin shipwright-discoveries --depth=1 2>/dev/null; then
            remote_jsonl="$(git show "origin/shipwright-discoveries:discoveries.jsonl" 2>/dev/null || true)"
        fi
        # Merge: dedup by ts_epoch+pipeline_id, sort by ts_epoch, cap at 2000 entries
        {
            [[ -n "$remote_jsonl" ]] && printf '%s\n' "$remote_jsonl"
            cat "$DISCOVERIES_FILE" 2>/dev/null || true
        } | jq -s 'unique_by("\(.ts_epoch)-\(.pipeline_id // "")") | sort_by(.ts_epoch)' 2>/dev/null \
            | jq -c '.[]' 2>/dev/null \
            | tail -2000 > discoveries.jsonl || true
        git checkout --orphan shipwright-discoveries 2>/dev/null || true
        git rm -rf --cached . 2>/dev/null || true
        git add discoveries.jsonl
        git -c user.name="shipwright" -c user.email="shipwright@local" \
            commit -m "discovery: append from $(hostname 2>/dev/null || echo machine)" >/dev/null 2>&1 || return 0
        git push -f origin shipwright-discoveries 2>/dev/null
    )
}

# query: find relevant discoveries for given file patterns
# Uses path overlap + semantic similarity (Jaccard on keywords, domain expansion)
query_discoveries() {
    local file_patterns="$1"
    local limit="${2:-10}"

    ensure_discoveries_dir

    # Merge remote discoveries if server configured (best-effort)
    if [[ -n "${DISCOVERY_SERVER_URL:-}" ]]; then
        local remote_results
        remote_results=$(curl -sS "${DISCOVERY_SERVER_URL}/api/discoveries?patterns=${file_patterns}" \
            --max-time 5 2>/dev/null || true)
        if [[ -n "$remote_results" ]] && echo "$remote_results" | jq -e '.' >/dev/null 2>&1; then
            echo "$remote_results" | jq -cr '.[]' >> "$DISCOVERIES_FILE" 2>/dev/null || true
        fi
    fi

    [[ ! -f "$DISCOVERIES_FILE" ]] && {
        info "No discoveries yet"
        return 0
    }

    local count=0
    local found=false
    local query_context
    query_context=$(_expand_domain_keywords "$file_patterns")

    # Collect candidates (path or semantic match)
    local candidates
    candidates=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local disc_patterns discovery_desc
        disc_patterns=$(echo "$line" | jq -r '.file_patterns // ""' 2>/dev/null || echo "")
        discovery_desc=$(echo "$line" | jq -r '.discovery // ""' 2>/dev/null || echo "")

        local matched=false
        if patterns_overlap "$file_patterns" "$disc_patterns"; then
            matched=true
        else
            # Semantic match: discovery about "authentication" matches "session verification"
            local desc_similarity
            desc_similarity=$(_discovery_semantic_match "$query_context" "$discovery_desc")
            if [[ "${desc_similarity:-0}" -gt 30 ]]; then
                matched=true
            fi
        fi

        if [[ "$matched" == "true" ]]; then
            candidates+=("$line")
        fi
    done < "$DISCOVERIES_FILE"

    # Use Claude to rank candidates by relevance when there are many
    if [[ "${INTELLIGENCE_ENABLED:-auto}" != "false" ]] && command -v claude &>/dev/null 2>&1 && [[ ${#candidates[@]} -gt 5 ]]; then
        local ranked_json=""
        local candidate_summaries=""
        local idx=0
        for line in "${candidates[@]+"${candidates[@]}"}"; do
            local disc cat_name
            disc=$(echo "$line" | jq -r '.discovery // ""' 2>/dev/null || echo "")
            cat_name=$(echo "$line" | jq -r '.category // ""' 2>/dev/null || echo "")
            candidate_summaries="${candidate_summaries}${idx}: [${cat_name}] ${disc}"$'\n'
            idx=$((idx + 1))
        done

        local rank_prompt
        rank_prompt="Given these discoveries and the query context '${query_context}', return a JSON array of indices sorted by relevance (most relevant first). Only return the JSON array, no explanation.

Discoveries:
${candidate_summaries}"

        local _claude_timeout
        _claude_timeout=30
        local _timeout_cmd=""
        if command -v gtimeout >/dev/null 2>&1; then _timeout_cmd="gtimeout $_claude_timeout"
        elif command -v timeout >/dev/null 2>&1; then _timeout_cmd="timeout $_claude_timeout"
        fi

        ranked_json=$($_timeout_cmd claude -p "$rank_prompt" 2>/dev/null || true)

        # Extract array from response (handle markdown fences)
        local indices_str=""
        if [[ -n "$ranked_json" ]]; then
            indices_str=$(echo "$ranked_json" | sed -n 's/.*\(\[[ 0-9,]*\]\).*/\1/p' | head -1)
        fi

        if [[ -n "$indices_str" ]] && echo "$indices_str" | jq -e 'type == "array"' >/dev/null 2>&1; then
            local reordered=()
            local seen=""
            while IFS= read -r rank_idx; do
                [[ -z "$rank_idx" ]] && continue
                if [[ "$rank_idx" -ge 0 && "$rank_idx" -lt "${#candidates[@]}" ]]; then
                    # Avoid duplicates
                    case " $seen " in *" $rank_idx "*) continue ;; esac
                    seen="$seen $rank_idx"
                    reordered+=("${candidates[$rank_idx]}")
                fi
            done < <(echo "$indices_str" | jq -r '.[]' 2>/dev/null)
            # Append any candidates not in the ranking
            idx=0
            for line in "${candidates[@]+"${candidates[@]}"}"; do
                case " $seen " in *" $idx "*) ;; *) reordered+=("$line") ;; esac
                idx=$((idx + 1))
            done
            candidates=("${reordered[@]+"${reordered[@]}"}")
        fi
    fi

    # Output up to limit
    local line
    for line in "${candidates[@]+"${candidates[@]}"}"; do
        if [[ "$found" == "false" ]]; then
            success "Found relevant discoveries:"
            found=true
        fi

        local category discovery disc_patterns
        category=$(echo "$line" | jq -r '.category' 2>/dev/null || echo "?")
        discovery=$(echo "$line" | jq -r '.discovery' 2>/dev/null || echo "?")
        disc_patterns=$(echo "$line" | jq -r '.file_patterns // ""' 2>/dev/null || echo "")

        echo -e "  ${DIM}→${RESET} [${category}] ${discovery} [${disc_patterns}]"

        count=$((count + 1))
        [[ "$count" -ge "$limit" ]] && break
    done

    if [[ "$found" == "false" ]]; then
        info "No relevant discoveries found for patterns: ${file_patterns}"
    fi
}

# inject: return discoveries for current pipeline that haven't been seen
inject_discoveries() {
    local file_patterns="$1"
    local pipeline_id="${SHIPWRIGHT_PIPELINE_ID:-unknown}"

    ensure_discoveries_dir

    # Pull cross-machine discoveries from orphan branch (30-min TTL cache, repo-scoped)
    # Cache file includes a repo hash derived from origin URL to prevent cross-repo
    # contamination when running pipelines in multiple repos within the TTL window.
    local _repo_hash _orphan_cache _cache_age _now
    _repo_hash="$(git remote get-url origin 2>/dev/null | md5sum 2>/dev/null | cut -c1-8 \
        || git remote get-url origin 2>/dev/null | cksum 2>/dev/null | cut -d' ' -f1 \
        || echo "default")"
    _orphan_cache="${HOME}/.shipwright/.discoveries-shared-cache-${_repo_hash}.jsonl"
    _now=$(date +%s 2>/dev/null || echo 0)
    _cache_age=$(stat -f %m "$_orphan_cache" 2>/dev/null \
        || stat -c %Y "$_orphan_cache" 2>/dev/null \
        || echo 0)
    if [[ ! -f "$_orphan_cache" ]] || [[ $(( _now - _cache_age )) -gt 1800 ]]; then
        mkdir -p "${HOME}/.shipwright" 2>/dev/null || true
        if ! git show "origin/shipwright-data:discoveries.jsonl" > "$_orphan_cache" 2>/dev/null; then
            if git fetch origin shipwright-data --depth=1 2>/dev/null; then
                git show "origin/shipwright-data:discoveries.jsonl" > "$_orphan_cache" 2>/dev/null
            fi
        fi
        # Migration fallback: if shipwright-data has no discoveries yet, try the legacy
        # shipwright-discoveries branch until Phase 6 one-time migration runs.
        if [[ ! -s "$_orphan_cache" ]]; then
            if ! git show "origin/shipwright-discoveries:discoveries.jsonl" > "$_orphan_cache" 2>/dev/null; then
                if git fetch origin shipwright-discoveries --depth=1 2>/dev/null; then
                    git show "origin/shipwright-discoveries:discoveries.jsonl" > "$_orphan_cache" 2>/dev/null
                fi
            fi
            [[ -f "$_orphan_cache" ]] || : > "$_orphan_cache"
        fi
    fi

    # Build merged temp file from local + orphan cache (dedup by ts_epoch+pipeline_id)
    local _merged_file=""
    if [[ -f "$DISCOVERIES_FILE" ]] || [[ -s "$_orphan_cache" ]]; then
        _merged_file=$(mktemp "${TMPDIR:-/tmp}/sw-disc-merged.XXXXXX" 2>/dev/null) || _merged_file=""
        if [[ -n "$_merged_file" ]]; then
            if command -v jq >/dev/null 2>&1; then
                cat "$DISCOVERIES_FILE" "$_orphan_cache" 2>/dev/null \
                    | jq -s 'unique_by("\(.ts_epoch)-\(.pipeline_id // "")") | .[]' 2>/dev/null \
                    | jq -c '.' 2>/dev/null > "$_merged_file" || true
            else
                cat "$DISCOVERIES_FILE" "$_orphan_cache" 2>/dev/null > "$_merged_file" || true
            fi
        fi
    fi

    # Determine source file: merged (if available and non-empty), else local only, else nothing
    local _source_file=""
    if [[ -n "$_merged_file" ]] && [[ -s "$_merged_file" ]]; then
        _source_file="$_merged_file"
    elif [[ -f "$DISCOVERIES_FILE" ]]; then
        _source_file="$DISCOVERIES_FILE"
    fi

    if [[ -z "$_source_file" ]]; then
        [[ -n "$_merged_file" ]] && rm -f "$_merged_file" 2>/dev/null || true
        info "No discoveries available"
        return 0
    fi

    local seen_file
    seen_file=$(get_seen_file "$pipeline_id")
    local query_context
    query_context=$(_expand_domain_keywords "$file_patterns")

    # Find relevant discoveries not yet seen (path or semantic match)
    local new_count=0
    local injected_entries=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local ts_epoch
        ts_epoch=$(echo "$line" | jq -r '.ts_epoch' 2>/dev/null || echo "0")

        # Skip if already seen
        if [[ -f "$seen_file" ]]; then
            if jq -e ".seen | contains([${ts_epoch}])" "$seen_file" 2>/dev/null | grep -q "true"; then
                continue
            fi
        fi

        # Skip entries with empty resolutions — they have no actionable value
        local disc_resolution
        disc_resolution=$(echo "$line" | jq -r '.resolution // ""' 2>/dev/null || echo "")
        [[ -z "${disc_resolution// }" ]] && continue

        # Check if relevant: path overlap OR semantic similarity > 30
        local disc_patterns discovery_desc
        disc_patterns=$(echo "$line" | jq -r '.file_patterns // ""' 2>/dev/null || echo "")
        discovery_desc=$(echo "$line" | jq -r '.discovery // ""' 2>/dev/null || echo "")

        local matched=false
        if [[ -n "$disc_patterns" ]] && patterns_overlap "$file_patterns" "$disc_patterns"; then
            matched=true
        else
            local desc_similarity
            desc_similarity=$(_discovery_semantic_match "$query_context" "$discovery_desc")
            if [[ "${desc_similarity:-0}" -gt 30 ]]; then
                matched=true
            fi
        fi

        if [[ "$matched" == "true" ]]; then
            injected_entries+=("$line")
            new_count=$((new_count + 1))
        fi
    done < "$_source_file"

    # Cleanup merged temp file
    [[ -n "$_merged_file" ]] && rm -f "$_merged_file" 2>/dev/null || true

    if [[ "$new_count" -eq 0 ]]; then
        info "No new discoveries to inject"
        return 0
    fi

    # Update seen set
    local new_seen
    new_seen="{\"seen\":["

    local first=true

    # Add previously seen entries
    if [[ -f "$seen_file" ]]; then
        while IFS= read -r ts; do
            [[ -z "$ts" ]] && continue
            [[ "$first" == "false" ]] && new_seen="${new_seen},"
            new_seen="${new_seen}${ts}"
            first=false
        done < <(jq -r '.seen[]? // empty' "$seen_file" 2>/dev/null || true)
    fi

    # Add newly seen entries
    for entry in "${injected_entries[@]}"; do
        local ts_epoch
        ts_epoch=$(echo "$entry" | jq -r '.ts_epoch' 2>/dev/null || echo "0")
        [[ "$first" == "false" ]] && new_seen="${new_seen},"
        new_seen="${new_seen}${ts_epoch}"
        first=false
    done

    new_seen="${new_seen}]}"

    # Atomic write
    local tmp_seen
    tmp_seen=$(mktemp)
    echo "$new_seen" > "$tmp_seen"
    mv "$tmp_seen" "$seen_file"

    success "Injected ${new_count} new discoveries"

    # Output for injection into pipeline
    for entry in "${injected_entries[@]}"; do
        echo "$entry" | jq -r '"[\(.category)] \(.discovery) — Resolution: \(.resolution)"' 2>/dev/null || true
    done
}

# ─── Semantic matching helpers ───────────────────────────────────────────────

# Domain keyword expansion for related concepts
_expand_domain_keywords() {
    local text="$1"
    local expanded="$text"

    # Domain synonym groups (iterate over fixed keys to avoid set -u issues)
    local dom
    for dom in auth api db ui test deploy error perf; do
        case "$dom" in
            auth)   [[ "$text" =~ [aA]uth ]] && expanded="$expanded authentication authorization login session token credential permission access" ;;
            api)    [[ "$text" =~ [aA]pi ]]  && expanded="$expanded endpoint route handler request response rest graphql" ;;
            db)     [[ "$text" =~ [dD]b ]]   && expanded="$expanded database query migration schema model table sql" ;;
            ui)     [[ "$text" =~ [uU]i ]]   && expanded="$expanded component view render template layout style css frontend" ;;
            test)   [[ "$text" =~ [tT]est ]] && expanded="$expanded testing assertion coverage mock stub fixture spec" ;;
            deploy) [[ "$text" =~ [dD]eploy ]] && expanded="$expanded deployment release publish ship ci cd pipeline" ;;
            error)  [[ "$text" =~ [eE]rror ]] && expanded="$expanded exception failure crash bug issue defect" ;;
            perf)   [[ "$text" =~ [pP]erf ]] && expanded="$expanded performance optimization speed latency throughput cache" ;;
        esac
    done

    echo "$expanded"
}

# Semantic similarity between discovery descriptions (Jaccard on keywords)
_discovery_semantic_match() {
    local query_desc="$1"
    local discovery_desc="$2"

    # Extract keywords from both descriptions
    local query_words discovery_words
    query_words=$(echo "$query_desc" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | grep -vE '^(the|a|an|is|are|was|were|in|on|at|to|for|of|and|or|but|not|with|this|that|from|by)$')
    discovery_words=$(echo "$discovery_desc" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | grep -vE '^(the|a|an|is|are|was|were|in|on|at|to|for|of|and|or|but|not|with|this|that|from|by)$')

    # Compute Jaccard similarity
    local intersection union
    intersection=$(comm -12 <(echo "$query_words") <(echo "$discovery_words") 2>/dev/null | wc -l | tr -d ' ')
    union=$(sort -u <(echo "$query_words") <(echo "$discovery_words") 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$union" -gt 0 ]]; then
        echo "$((intersection * 100 / union))"
    else
        echo "0"
    fi
}

# patterns_overlap: check if two comma-separated patterns overlap
patterns_overlap() {
    local patterns1="$1"
    local patterns2="$2"

    # Simple glob matching: check if any pattern from p1 matches any from p2
    # Use bash filename expansion or simple substring matching
    local p1 p2

    IFS=',' read -ra p1_arr <<< "$patterns1"
    IFS=',' read -ra p2_arr <<< "$patterns2"

    for p1 in "${p1_arr[@]}"; do
        p1="${p1// /}"  # trim spaces
        [[ -z "$p1" ]] && continue

        for p2 in "${p2_arr[@]}"; do
            p2="${p2// /}"  # trim spaces
            [[ -z "$p2" ]] && continue

            # Simple substring overlap check: if removing glob chars, do they share directory structure?
            local p1_base="${p1%/*}"  # get directory part
            local p2_base="${p2%/*}"

            # Check if patterns refer to same or overlapping directory trees
            if [[ "$p1_base" == "$p2_base" ]] || [[ "$p1_base" == "$p2"* ]] || [[ "$p2_base" == "$p1"* ]]; then
                return 0
            fi

            # Also check if exact patterns match
            if [[ "$p1" == "$p2" ]]; then
                return 0
            fi
        done
    done

    return 1
}

# clean: remove stale discoveries (older than TTL)
clean_discoveries() {
    local ttl="${1:-$DISCOVERY_TTL_SECS}"

    [[ ! -f "$DISCOVERIES_FILE" ]] && {
        info "No discoveries to clean"
        return 0
    }

    local now
    now=$(now_epoch)
    local cutoff=$((now - ttl))

    local tmp_file
    tmp_file=$(mktemp)
    local removed_count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local ts_epoch
        ts_epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null || echo "0")

        if [[ "$ts_epoch" -ge "$cutoff" ]]; then
            echo "$line" >> "$tmp_file"
        else
            removed_count=$((removed_count + 1))
        fi
    done < "$DISCOVERIES_FILE"

    # Atomic replace
    [[ -s "$tmp_file" ]] && mv "$tmp_file" "$DISCOVERIES_FILE" || rm -f "$tmp_file"

    if [[ "$removed_count" -gt 0 ]]; then
        success "Cleaned ${removed_count} stale discoveries (older than ${ttl}s)"
    else
        info "No stale discoveries to clean"
    fi
}

# status: show discovery channel stats
show_status() {
    info "Discovery Channel Status"
    echo ""

    local total=0
    local oldest=""
    local newest=""

    if [[ -f "$DISCOVERIES_FILE" ]]; then
        total=$(wc -l < "$DISCOVERIES_FILE")

        # Get oldest and newest timestamps
        oldest=$(jq -s 'min_by(.ts_epoch) | .ts' "$DISCOVERIES_FILE" 2>/dev/null || echo "N/A")
        newest=$(jq -s 'max_by(.ts_epoch) | .ts' "$DISCOVERIES_FILE" 2>/dev/null || echo "N/A")
    fi

    echo -e "  ${CYAN}Total discoveries:${RESET} ${total}"
    echo -e "  ${CYAN}Oldest:${RESET} ${oldest}"
    echo -e "  ${CYAN}Newest:${RESET} ${newest}"
    echo ""

    # Count by category
    if [[ -f "$DISCOVERIES_FILE" ]]; then
        echo -e "  ${CYAN}By category:${RESET}"
        jq -s 'group_by(.category) | map({category: .[0].category, count: length}) | .[]' \
            "$DISCOVERIES_FILE" 2>/dev/null | \
            jq -r '"    \(.category): \(.count)"' 2>/dev/null | sort || true
    fi

    echo ""
    echo -e "  ${CYAN}Storage:${RESET} ${DISCOVERIES_FILE}"
    [[ -f "$DISCOVERIES_FILE" ]] && echo -e "  ${CYAN}Size:${RESET} $(du -h "$DISCOVERIES_FILE" | cut -f1)"
}

# show_help: display usage
show_help() {
    echo -e "${CYAN}${BOLD}shipwright discovery${RESET} — Cross-Pipeline Real-Time Learning"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright discovery${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}broadcast${RESET} <category> <patterns> <text> [resolution]"
    echo -e "    Write a new discovery event to the shared channel"
    echo ""
    echo -e "  ${CYAN}query${RESET} <patterns> [limit]"
    echo -e "    Find discoveries relevant to file patterns"
    echo ""
    echo -e "  ${CYAN}inject${RESET} <patterns>"
    echo -e "    Inject new discoveries for this pipeline (tracks seen set)"
    echo ""
    echo -e "  ${CYAN}clean${RESET} [ttl-seconds]"
    echo -e "    Remove stale discoveries (default: 86400s = 24h)"
    echo ""
    echo -e "  ${CYAN}status${RESET}"
    echo -e "    Show discovery channel statistics and health"
    echo ""
    echo -e "  ${CYAN}help${RESET}"
    echo -e "    Show this help message"
    echo ""
    echo -e "${BOLD}ENVIRONMENT${RESET}"
    echo -e "  ${DIM}SHIPWRIGHT_PIPELINE_ID${RESET}      Current pipeline ID (auto-tracked in seen set)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright discovery broadcast \"auth-fix\" \"src/auth/*.ts\" \"JWT validation failure resolved\" \"Added claim verification\"${RESET}"
    echo -e "  ${DIM}shipwright discovery query \"src/**/*.js,src/**/*.ts\" 5${RESET}"
    echo -e "  ${DIM}shipwright discovery inject \"src/api/**\" 2>&1 | xargs -I {} echo \"Learning: {}\"${RESET}"
    echo -e "  ${DIM}shipwright discovery clean 172800${RESET}              # Remove discoveries older than 48h"
    echo -e "  ${DIM}shipwright discovery status${RESET}"
}

# ─── Main ────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        broadcast)
            [[ $# -lt 3 ]] && {
                error "broadcast requires: category, patterns, text [, resolution]"
                exit 1
            }
            broadcast_discovery "$1" "$2" "$3" "${4:-}"
            ;;
        query)
            [[ $# -lt 1 ]] && {
                error "query requires: patterns [limit]"
                exit 1
            }
            query_discoveries "$1" "${2:-10}"
            ;;
        inject)
            [[ $# -lt 1 ]] && {
                error "inject requires: patterns"
                exit 1
            }
            inject_discoveries "$1"
            ;;
        clean)
            clean_discoveries "${1:-$DISCOVERY_TTL_SECS}"
            ;;
        status)
            show_status
            ;;
        ci_push)
            sw_discovery_ci_push
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
