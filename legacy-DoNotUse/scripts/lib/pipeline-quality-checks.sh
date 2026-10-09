# pipeline-quality-checks.sh — Quality checks (security, bundle, perf, api, coverage, adversarial, dod, bash compat, etc.) for sw-pipeline.sh
# Source from sw-pipeline.sh. Requires pipeline-quality.sh, ARTIFACTS_DIR, SCRIPT_DIR.
[[ -n "${_PIPELINE_QUALITY_CHECKS_LOADED:-}" ]] && return 0
_PIPELINE_QUALITY_CHECKS_LOADED=1
_PIPELINE_QUALITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_PIPELINE_QUALITY_DIR}/ai-provider.sh" ]] && source "${_PIPELINE_QUALITY_DIR}/ai-provider.sh"

_pipeline_quality_ai_provider() {
    ai_provider_resolve "${SHIPWRIGHT_AI_PROVIDER:-}" 2>/dev/null || echo "claude"
}

_pipeline_quality_ai_ready() {
    local provider
    provider="$(_pipeline_quality_ai_provider)"
    ai_provider_check_ready "$provider" 2>/dev/null
}

_pipeline_quality_ai_text() {
    local prompt="$1" tier="${2:-haiku}" max_turns="${3:-6}"
    local provider out_file err_file ai_json
    provider="$(_pipeline_quality_ai_provider)"
    out_file=$(mktemp "${TMPDIR:-/tmp}/sw-quality-ai.XXXXXX")
    err_file=$(mktemp "${TMPDIR:-/tmp}/sw-quality-ai-err.XXXXXX")
    ai_json=$(ai_run_json "$provider" "$prompt" "$tier" "$max_turns" "$out_file" "$err_file" 2>/dev/null || true)
    rm -f "$out_file" "$err_file"
    echo "$ai_json" | jq -r '.result_text // ""' 2>/dev/null || echo ""
}

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
TEST_CMD="${TEST_CMD:-}"

# Source compat.sh for file_mtime() and date_to_epoch() used by pipeline_artifact_is_fresh()
if [[ -f "${SCRIPT_DIR}/lib/compat.sh" ]]; then
    source "${SCRIPT_DIR}/lib/compat.sh"
fi

# Returns 0 (fresh) if an artifact file was written during the current pipeline run.
# Freshness is anchored to PIPELINE_RUN_EPOCH (set by initialize_state / resume_state).
#
# Primary check: JSON timestamp field (authoritative — unaffected by filesystem clock skew).
#   - Field present and artifact_epoch >= PIPELINE_RUN_EPOCH → fresh (return 0)
#   - Field present and artifact_epoch <  PIPELINE_RUN_EPOCH → stale (return 1, no fallback)
# Fallback: file mtime (used when the JSON field is absent).
# Pass-through: when PIPELINE_RUN_EPOCH is 0 or unset, always returns 0 (backward compat).
#
# Usage: pipeline_artifact_is_fresh <file> [json_timestamp_field]
pipeline_artifact_is_fresh() {
    local file="$1" ts_field="${2:-}"
    local epoch="${PIPELINE_RUN_EPOCH:-0}"

    # Backward compat: no epoch reference → treat as fresh (pass-through)
    [[ "$epoch" == "0" || -z "$epoch" ]] && return 0
    [[ ! -f "$file" ]] && return 1

    # Primary: JSON timestamp field
    if [[ -n "$ts_field" ]]; then
        local ts artifact_epoch
        ts=$(jq -r --arg f "$ts_field" '.[$f] // empty' "$file" 2>/dev/null || true)
        if [[ -n "$ts" ]]; then
            artifact_epoch=$(date_to_epoch "$ts" 2>/dev/null || echo "0")
            if [[ "$artifact_epoch" =~ ^[0-9]+$ && "$artifact_epoch" -ge "$epoch" ]]; then
                return 0
            fi
            # Timestamp present but stale — authoritative, do not fall through to mtime
            return 1
        fi
    fi

    # Fallback: file mtime (artifact has no JSON timestamp field)
    local mtime
    mtime=$(file_mtime "$file")
    [[ "$mtime" =~ ^[0-9]+$ && "$mtime" -ge "$epoch" ]] && return 0
    return 1
}

# Returns HEAD short SHA (8 chars), or "" on failure/detached HEAD/shallow clone.
# Never exits with non-zero. Pure function, no side effects.
_pipeline_head_sha() {
    git rev-parse --short HEAD 2>/dev/null || true
}

# Returns 0 if artifact's stamped SHA matches current HEAD (prefix match).
# Returns 0 (pass-through) when: no SHA found in artifact, HEAD unavailable, file missing.
# Returns 1 when: SHA found but doesn't match HEAD.
# Format detection by file extension:
#   .json  → reads .[0].created_at_commit via jq (per-finding stamp)
#   .md    → reads "created_at_commit: <sha>" from first 5 lines
#   .log   → reads "# created_at_commit: <sha>" from first 3 lines
pipeline_artifact_is_current() {
    local file="$1"
    local head_sha
    head_sha=$(_pipeline_head_sha)
    [[ -z "$head_sha" ]] && return 0   # HEAD unavailable — pass-through
    [[ ! -f "$file" ]] && return 0     # Missing file — pass-through

    local artifact_sha=""
    case "$file" in
        *.json)
            # Object format (e.g. classified-findings.json) uses .created_at_commit;
            # array format (e.g. adversarial-review.json) uses .[0].created_at_commit.
            artifact_sha=$(jq -r 'if type == "object" then .created_at_commit // empty elif type == "array" then .[0].created_at_commit // empty else empty end' "$file" 2>/dev/null || true)
            ;;
        *.md)
            artifact_sha=$(sed -n '1,5p' "$file" 2>/dev/null | grep -m1 '^created_at_commit: ' | sed 's/^created_at_commit: //' || true)
            ;;
        *.log)
            artifact_sha=$(sed -n '1,3p' "$file" 2>/dev/null | grep -m1 '^# created_at_commit: ' | sed 's/^# created_at_commit: //' || true)
            ;;
    esac

    [[ -z "$artifact_sha" ]] && return 0   # No SHA stamp — pass-through (backward compat)

    # Prefix match: short SHA lengths may vary (7 or 8 chars)
    local min_len=${#artifact_sha}
    [[ ${#head_sha} -lt $min_len ]] && min_len=${#head_sha}
    [[ "${artifact_sha:0:$min_len}" == "${head_sha:0:$min_len}" ]] && return 0
    return 1
}

# Returns the numeric exit code from the last pipeline test run, or returns 1 if unknown.
# When PIPELINE_RUN_EPOCH is set, stale sidecars (written by a previous pipeline run) are
# treated as missing so downstream callers fall back to their default/safe paths.
pipeline_test_status() {
    local _sf="${ARTIFACTS_DIR}/test-results.status.json"
    [[ -f "$_sf" ]] || return 1
    pipeline_artifact_is_fresh "$_sf" "finished_at" || return 1
    jq -r '.exit_code // empty' "$_sf" 2>/dev/null
}

# Returns 0 (true) if the last pipeline test run passed; 1 otherwise.
pipeline_test_passed() {
    local _ec
    _ec=$(pipeline_test_status 2>/dev/null) || return 1
    [[ "$_ec" == "0" ]]
}

quality_check_security() {
    info "Dependency CVE audit..."
    local audit_log="$ARTIFACTS_DIR/security-audit.log"
    local audit_exit=0
    local tool_found=false

    # Try npm audit
    if [[ -f "package.json" ]] && command -v npm >/dev/null 2>&1; then
        tool_found=true
        npm audit --production 2>&1 | tee "$audit_log" || audit_exit=$?
    # Try pip-audit
    elif [[ -f "requirements.txt" || -f "pyproject.toml" ]] && command -v pip-audit >/dev/null 2>&1; then
        tool_found=true
        pip-audit 2>&1 | tee "$audit_log" || audit_exit=$?
    # Try cargo audit
    elif [[ -f "Cargo.toml" ]] && command -v cargo-audit >/dev/null 2>&1; then
        tool_found=true
        cargo audit 2>&1 | tee "$audit_log" || audit_exit=$?
    fi

    if [[ "$tool_found" != "true" ]]; then
        info "No security audit tool found — skipping"
        echo "No audit tool available" > "$audit_log"
        return 0
    fi

    # Stamp artifact with current commit SHA (prepend header line)
    local _sec_sha
    _sec_sha=$(_pipeline_head_sha)
    if [[ -n "$_sec_sha" && -s "$audit_log" ]]; then
        local _sec_tmp
        _sec_tmp=$(mktemp "${TMPDIR:-/tmp}/sw-audit-stamp.XXXXXX")
        { printf '# created_at_commit: %s\n' "$_sec_sha"; cat "$audit_log"; } > "$_sec_tmp" && mv "$_sec_tmp" "$audit_log" || rm -f "$_sec_tmp"
    fi

    # Parse results for critical/high severity
    local critical_count high_count
    critical_count=$(grep -ciE 'critical' "$audit_log" 2>/dev/null || true)
    critical_count="${critical_count:-0}"
    high_count=$(grep -ciE 'high' "$audit_log" 2>/dev/null || true)
    high_count="${high_count:-0}"

    emit_event "quality.security" \
        "issue=${ISSUE_NUMBER:-0}" \
        "critical=$critical_count" \
        "high=$high_count"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Dependency CVE audit: ${critical_count} critical, ${high_count} high (scope: all dependencies)"
        return 1
    fi

    success "Dependency CVE audit: clean (scope: all dependencies)"
    return 0
}

quality_check_bundle_size() {
    info "Bundle size check..."
    local metrics_log="$ARTIFACTS_DIR/bundle-metrics.log"
    local bundle_size=0
    local bundle_dir=""

    # Find build output directory — check config files first, then common dirs
    # Parse tsconfig.json outDir
    if [[ -z "$bundle_dir" && -f "tsconfig.json" ]]; then
        local ts_out
        ts_out=$(jq -r '.compilerOptions.outDir // empty' tsconfig.json 2>/dev/null || true)
        [[ -n "$ts_out" && -d "$ts_out" ]] && bundle_dir="$ts_out"
    fi
    # Parse package.json build script for output hints
    if [[ -z "$bundle_dir" && -f "package.json" ]]; then
        local build_script
        build_script=$(jq -r '.scripts.build // ""' package.json 2>/dev/null || true)
        if [[ -n "$build_script" ]]; then
            # Check for common output flags: --outDir, -o, --out-dir
            local parsed_out
            parsed_out=$(echo "$build_script" | grep -oE '(--outDir|--out-dir|-o)\s+[^ ]+' 2>/dev/null | awk '{print $NF}' | head -1 || true)
            [[ -n "$parsed_out" && -d "$parsed_out" ]] && bundle_dir="$parsed_out"
        fi
    fi
    # Fallback: check common directories
    if [[ -z "$bundle_dir" ]]; then
        for dir in dist build out .next target; do
            if [[ -d "$dir" ]]; then
                bundle_dir="$dir"
                break
            fi
        done
    fi

    if [[ -z "$bundle_dir" ]]; then
        info "No build output directory found — skipping bundle check"
        echo "No build directory" > "$metrics_log"
        return 0
    fi

    bundle_size=$(du -sk "$bundle_dir" 2>/dev/null | cut -f1 || echo "0")
    local bundle_size_human
    bundle_size_human=$(du -sh "$bundle_dir" 2>/dev/null | cut -f1 || echo "unknown")

    echo "Bundle directory: $bundle_dir" > "$metrics_log"
    echo "Size: ${bundle_size}KB (${bundle_size_human})" >> "$metrics_log"

    emit_event "quality.bundle" \
        "issue=${ISSUE_NUMBER:-0}" \
        "size_kb=$bundle_size" \
        "directory=$bundle_dir"

    # Adaptive bundle size check: statistical deviation from historical mean
    local repo_hash_bundle
    repo_hash_bundle=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local bundle_baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_bundle}"
    local bundle_history_file="${bundle_baselines_dir}/bundle-history.json"

    local bundle_history="[]"
    if [[ -f "$bundle_history_file" ]]; then
        bundle_history=$(jq '.sizes // []' "$bundle_history_file" 2>/dev/null || echo "[]")
    fi

    local bundle_hist_count
    bundle_hist_count=$(echo "$bundle_history" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$bundle_hist_count" -ge 3 ]]; then
        # Statistical check: alert on growth > 2σ from historical mean
        local mean_size stddev_size
        mean_size=$(echo "$bundle_history" | jq 'add / length' 2>/dev/null || echo "0")
        stddev_size=$(echo "$bundle_history" | jq '
            (add / length) as $mean |
            (map(. - $mean | . * .) | add / length | sqrt)
        ' 2>/dev/null || echo "0")

        # Adaptive tolerance: small repos (<1MB mean) get wider tolerance (3σ), large repos get 2σ
        local sigma_mult
        sigma_mult=$(awk -v mean="$mean_size" 'BEGIN{ print (mean < 1024 ? 3 : 2) }')
        local adaptive_max
        adaptive_max=$(awk -v mean="$mean_size" -v sd="$stddev_size" -v mult="$sigma_mult" \
            'BEGIN{ t = mean + mult*sd; min_t = mean * 1.1; printf "%.0f", (t > min_t ? t : min_t) }')

        echo "History: ${bundle_hist_count} runs | Mean: ${mean_size}KB | StdDev: ${stddev_size}KB | Max: ${adaptive_max}KB (${sigma_mult}σ)" >> "$metrics_log"

        if [[ "$bundle_size" -gt "$adaptive_max" ]] 2>/dev/null; then
            local growth_pct
            growth_pct=$(awk -v cur="$bundle_size" -v mean="$mean_size" 'BEGIN{printf "%d", ((cur - mean) / mean) * 100}')
            warn "Bundle size ${growth_pct}% above average (${mean_size}KB → ${bundle_size}KB, ${sigma_mult}σ threshold: ${adaptive_max}KB)"
            return 1
        fi
    else
        # Fallback: legacy memory baseline (not enough history for statistical check)
        local bundle_growth_limit
        bundle_growth_limit=$(_config_get_int "quality.bundle_growth_legacy_pct" 20 2>/dev/null || echo 20)
        local baseline_size=""
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            baseline_size=$(bash "$SCRIPT_DIR/sw-memory.sh" get "bundle_size_kb" 2>/dev/null) || true
        fi
        if [[ -n "$baseline_size" && "$baseline_size" -gt 0 ]] 2>/dev/null; then
            local growth_pct
            growth_pct=$(awk -v cur="$bundle_size" -v base="$baseline_size" 'BEGIN{printf "%d", ((cur - base) / base) * 100}')
            echo "Baseline: ${baseline_size}KB | Growth: ${growth_pct}%" >> "$metrics_log"
            if [[ "$growth_pct" -gt "$bundle_growth_limit" ]]; then
                warn "Bundle size grew ${growth_pct}% (${baseline_size}KB → ${bundle_size}KB)"
                return 1
            fi
        fi
    fi

    # Append current size to rolling history (keep last 10)
    mkdir -p "$bundle_baselines_dir"
    local updated_bundle_hist
    updated_bundle_hist=$(echo "$bundle_history" | jq --arg sz "$bundle_size" '
        . + [($sz | tonumber)] | .[-10:]
    ' 2>/dev/null || echo "[$bundle_size]")
    local tmp_bundle_hist
    tmp_bundle_hist=$(mktemp "${bundle_baselines_dir}/bundle-history.json.XXXXXX")
    jq -n --argjson sizes "$updated_bundle_hist" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{sizes: $sizes, updated: $updated}' > "$tmp_bundle_hist" 2>/dev/null
    mv "$tmp_bundle_hist" "$bundle_history_file" 2>/dev/null || true

    # Intelligence: identify top dependency bloaters
    if type intelligence_search_memory >/dev/null 2>&1 && [[ -f "package.json" ]] && command -v jq >/dev/null 2>&1; then
        local dep_sizes=""
        local deps
        deps=$(jq -r '.dependencies // {} | keys[]' package.json 2>/dev/null || true)
        if [[ -n "$deps" ]]; then
            while IFS= read -r dep; do
                [[ -z "$dep" ]] && continue
                local dep_dir="node_modules/${dep}"
                if [[ -d "$dep_dir" ]]; then
                    local dep_size
                    dep_size=$(du -sk "$dep_dir" 2>/dev/null | cut -f1 || echo "0")
                    dep_sizes="${dep_sizes}${dep_size} ${dep}
"
                fi
            done <<< "$deps"
            if [[ -n "$dep_sizes" ]]; then
                local top_bloaters
                top_bloaters=$(echo "$dep_sizes" | sort -rn | head -3)
                if [[ -n "$top_bloaters" ]]; then
                    echo "" >> "$metrics_log"
                    echo "Top 3 dependency sizes:" >> "$metrics_log"
                    echo "$top_bloaters" | while IFS=' ' read -r sz nm; do
                        [[ -z "$nm" ]] && continue
                        echo "  ${nm}: ${sz}KB" >> "$metrics_log"
                    done
                    info "Top bloaters: $(echo "$top_bloaters" | head -1 | awk '{print $2 ": " $1 "KB"}')"
                fi
            fi
        fi
    fi

    info "Bundle size: ${bundle_size_human}${bundle_hist_count:+ (${bundle_hist_count} historical samples)}"
    return 0
}

quality_check_perf_regression() {
    info "Performance regression check..."
    local metrics_log="$ARTIFACTS_DIR/perf-metrics.log"
    local test_log="$ARTIFACTS_DIR/test-results.log"

    if [[ ! -f "$test_log" ]]; then
        info "No test results — skipping perf check"
        echo "No test results available" > "$metrics_log"
        return 0
    fi

    # Extract test suite duration — multi-framework patterns
    local duration_ms=""
    # Jest/Vitest: "Time: 12.34 s" or "Duration  12.34s"
    duration_ms=$(grep -oE 'Time:\s*[0-9.]+\s*s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'Duration\s+[0-9.]+\s*s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # pytest: "passed in 12.34s" or "====== 5 passed in 12.34 seconds ======"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'passed in [0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Go test: "ok  pkg  12.345s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE '^ok\s+\S+\s+[0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+s' | grep -oE '[0-9.]+' | tail -1 || true)
    # Cargo test: "test result: ok. ... finished in 12.34s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'finished in [0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Generic: "12.34 seconds" or "12.34s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE '[0-9.]+ ?s(econds?)?' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)

    # Claude fallback: parse test output when no pattern matches
    if [[ -z "$duration_ms" ]]; then
        local intel_enabled="false"
        local _dc_intel
        if declare -f _load_daemon_config >/dev/null 2>&1; then
            _dc_intel=$(_load_daemon_config)
        else
            _dc_intel=$(cat "${PROJECT_ROOT:-.}/.claude/daemon-config.json" 2>/dev/null || echo '{}')
        fi
        intel_enabled=$(echo "$_dc_intel" | jq -r '.intelligence.enabled // false' 2>/dev/null || echo "false")
        if [[ "$intel_enabled" == "true" ]] && _pipeline_quality_ai_ready; then
            local tail_output
            tail_output=$(tail -30 "$test_log" 2>/dev/null || true)
            if [[ -n "$tail_output" ]]; then
                duration_ms=$(_pipeline_quality_ai_text "Extract ONLY the total test suite duration in seconds from this output. Reply with ONLY a number (e.g. 12.34). If no duration found, reply NONE.

$tail_output" "haiku" "4" | grep -oE '^[0-9.]+$' | head -1 || true)
                [[ "$duration_ms" == "NONE" ]] && duration_ms=""
            fi
        fi
    fi

    # Validate: require at least one leading digit before any decimal point,
    # and require the value to be numerically > 0.
    # Rejects: ".", ".34", "0.", "...", "0", "0.0", "0.00", "00" — guards
    # against partial-float extraction by [0-9.]+ and the AI fallback (#398).
    # Uses printf+grep -qE and awk -v for Bash 3.2 compatibility.
    if [[ -n "$duration_ms" ]]; then
        if ! printf '%s\n' "$duration_ms" | grep -qE '^[0-9]+(\.[0-9]+)?$' || \
           ! awk -v d="$duration_ms" 'BEGIN { exit !(d > 0) }'; then
            duration_ms=""
        fi
    fi

    if [[ -z "$duration_ms" ]]; then
        info "Could not extract test duration — skipping perf check"
        echo "Duration not parseable" > "$metrics_log"
        return 0
    fi

    echo "Test duration: ${duration_ms}s" > "$metrics_log"

    emit_event "quality.perf" \
        "issue=${ISSUE_NUMBER:-0}" \
        "duration_s=$duration_ms"

    # Adaptive performance check: 2σ from rolling 10-run average
    local repo_hash_perf
    repo_hash_perf=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local perf_baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_perf}"
    local perf_history_file="${perf_baselines_dir}/perf-history.json"

    # Read historical durations (rolling window of last 10 runs)
    local history_json="[]"
    if [[ -f "$perf_history_file" ]]; then
        history_json=$(jq '.durations // []' "$perf_history_file" 2>/dev/null || echo "[]")
    fi

    local history_count
    history_count=$(echo "$history_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$history_count" -ge 3 ]]; then
        # Calculate mean and standard deviation from history
        local mean_dur stddev_dur
        mean_dur=$(echo "$history_json" | jq 'add / length' 2>/dev/null || echo "0")
        stddev_dur=$(echo "$history_json" | jq '
            (add / length) as $mean |
            (map(. - $mean | . * .) | add / length | sqrt)
        ' 2>/dev/null || echo "0")

        # Threshold: mean + 2σ (but at least 10% above mean)
        local adaptive_threshold
        adaptive_threshold=$(awk -v mean="$mean_dur" -v sd="$stddev_dur" \
            'BEGIN{ t = mean + 2*sd; min_t = mean * 1.1; printf "%.2f", (t > min_t ? t : min_t) }')

        echo "History: ${history_count} runs | Mean: ${mean_dur}s | StdDev: ${stddev_dur}s | Threshold: ${adaptive_threshold}s" >> "$metrics_log"

        if awk -v cur="$duration_ms" -v thresh="$adaptive_threshold" 'BEGIN{exit !(cur > thresh)}' 2>/dev/null; then
            local slowdown_pct
            slowdown_pct=$(awk -v cur="$duration_ms" -v mean="$mean_dur" 'BEGIN{printf "%d", ((cur - mean) / mean) * 100}')
            warn "Tests ${slowdown_pct}% slower than rolling average (${mean_dur}s → ${duration_ms}s, threshold: ${adaptive_threshold}s)"
            return 1
        fi
    else
        # Fallback: legacy memory baseline (not enough history for statistical check)
        local perf_regression_limit
        perf_regression_limit=$(_config_get_int "quality.perf_regression_legacy_pct" 30 2>/dev/null || echo 30)
        local baseline_dur=""
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            baseline_dur=$(bash "$SCRIPT_DIR/sw-memory.sh" get "test_duration_s" 2>/dev/null) || true
        fi
        if [[ -n "$baseline_dur" ]] && awk -v cur="$duration_ms" -v base="$baseline_dur" 'BEGIN{exit !(base > 0)}' 2>/dev/null; then
            local slowdown_pct
            slowdown_pct=$(awk -v cur="$duration_ms" -v base="$baseline_dur" 'BEGIN{printf "%d", ((cur - base) / base) * 100}')
            echo "Baseline: ${baseline_dur}s | Slowdown: ${slowdown_pct}%" >> "$metrics_log"
            if [[ "$slowdown_pct" -gt "$perf_regression_limit" ]]; then
                warn "Tests ${slowdown_pct}% slower (${baseline_dur}s → ${duration_ms}s)"
                return 1
            fi
        fi
    fi

    # Append current duration to rolling history (keep last 10)
    mkdir -p "$perf_baselines_dir"
    local updated_history
    updated_history=$(echo "$history_json" | jq --arg dur "$duration_ms" '
        . + [($dur | tonumber)] | .[-10:]
    ' 2>/dev/null || echo "[$duration_ms]")
    local tmp_perf_hist
    tmp_perf_hist=$(mktemp "${perf_baselines_dir}/perf-history.json.XXXXXX")
    jq -n --argjson durations "$updated_history" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{durations: $durations, updated: $updated}' > "$tmp_perf_hist" 2>/dev/null
    mv "$tmp_perf_hist" "$perf_history_file" 2>/dev/null || true

    info "Test duration: ${duration_ms}s${history_count:+ (${history_count} historical samples)}"
    return 0
}

quality_check_api_compat() {
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    info "API compatibility check..."
    local compat_log="$ARTIFACTS_DIR/api-compat.log"

    # Look for OpenAPI/Swagger specs — search beyond hardcoded paths
    local spec_file=""
    for candidate in openapi.json openapi.yaml swagger.json swagger.yaml api/openapi.json docs/openapi.yaml; do
        if [[ -f "$candidate" ]]; then
            spec_file="$candidate"
            break
        fi
    done
    # Broader search if nothing found at common paths
    if [[ -z "$spec_file" ]]; then
        spec_file=$(find . -maxdepth 4 \( -name "openapi*.json" -o -name "openapi*.yaml" -o -name "openapi*.yml" -o -name "swagger*.json" -o -name "swagger*.yaml" -o -name "swagger*.yml" \) -type f 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$spec_file" ]]; then
        info "No OpenAPI/Swagger spec found — skipping API compat check"
        echo "No API spec found" > "$compat_log"
        return 0
    fi

    # Check if spec was modified in this branch
    local spec_changed
    spec_changed=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" 2>/dev/null | grep -c "$(basename "$spec_file")" || true)
    spec_changed="${spec_changed:-0}"

    if [[ "$spec_changed" -eq 0 ]]; then
        info "API spec unchanged"
        echo "Spec unchanged" > "$compat_log"
        return 0
    fi

    # Diff the spec against base branch
    local old_spec new_spec
    old_spec=$(git show "${BASE_BRANCH}:${spec_file}" 2>/dev/null || true)
    new_spec=$(cat "$spec_file" 2>/dev/null || true)

    if [[ -z "$old_spec" ]]; then
        info "New API spec — no baseline to compare"
        echo "New spec, no baseline" > "$compat_log"
        return 0
    fi

    # Check for breaking changes: removed endpoints, changed methods
    local removed_endpoints=""
    if command -v jq >/dev/null 2>&1 && [[ "$spec_file" == *.json ]]; then
        local old_paths new_paths
        old_paths=$(echo "$old_spec" | jq -r '.paths | keys[]' 2>/dev/null | sort || true)
        new_paths=$(jq -r '.paths | keys[]' "$spec_file" 2>/dev/null | sort || true)
        removed_endpoints=$(comm -23 <(echo "$old_paths") <(echo "$new_paths") 2>/dev/null || true)
    fi

    # Enhanced schema diff: parameter changes, response schema, auth changes
    local param_changes="" schema_changes=""
    if command -v jq >/dev/null 2>&1 && [[ "$spec_file" == *.json ]]; then
        # Detect parameter changes on existing endpoints
        local common_paths
        common_paths=$(comm -12 <(echo "$old_spec" | jq -r '.paths | keys[]' 2>/dev/null | sort) <(jq -r '.paths | keys[]' "$spec_file" 2>/dev/null | sort) 2>/dev/null || true)
        if [[ -n "$common_paths" ]]; then
            while IFS= read -r path; do
                [[ -z "$path" ]] && continue
                local old_params new_params
                old_params=$(echo "$old_spec" | jq -r --arg p "$path" '.paths[$p] | to_entries[] | .value.parameters // [] | .[].name' 2>/dev/null | sort || true)
                new_params=$(jq -r --arg p "$path" '.paths[$p] | to_entries[] | .value.parameters // [] | .[].name' "$spec_file" 2>/dev/null | sort || true)
                local removed_params
                removed_params=$(comm -23 <(echo "$old_params") <(echo "$new_params") 2>/dev/null || true)
                [[ -n "$removed_params" ]] && param_changes="${param_changes}${path}: removed params: ${removed_params}
"
            done <<< "$common_paths"
        fi
    fi

    # Intelligence: semantic API diff for complex changes
    local semantic_diff=""
    if type intelligence_search_memory >/dev/null 2>&1 && _pipeline_quality_ai_ready; then
        local spec_git_diff
        spec_git_diff=$(git diff "origin/${BASE_BRANCH:-main}...HEAD" -- "$spec_file" 2>/dev/null | head -200 || true)
        if [[ -n "$spec_git_diff" ]]; then
            semantic_diff=$(_pipeline_quality_ai_text "Analyze this API spec diff for breaking changes. List: removed endpoints, changed parameters, altered response schemas, auth changes. Be concise.

${spec_git_diff}" "haiku" "4")
        fi
    fi

    {
        echo "Spec: $spec_file"
        echo "Changed: yes"
        if [[ -n "$removed_endpoints" ]]; then
            echo "BREAKING — Removed endpoints:"
            echo "$removed_endpoints"
        fi
        if [[ -n "$param_changes" ]]; then
            echo "BREAKING — Parameter changes:"
            echo "$param_changes"
        fi
        if [[ -n "$semantic_diff" ]]; then
            echo ""
            echo "Semantic analysis:"
            echo "$semantic_diff"
        fi
        if [[ -z "$removed_endpoints" && -z "$param_changes" ]]; then
            echo "No breaking changes detected"
        fi
    } > "$compat_log"

    if [[ -n "$removed_endpoints" || -n "$param_changes" ]]; then
        local issue_count=0
        [[ -n "$removed_endpoints" ]] && issue_count=$((issue_count + $(echo "$removed_endpoints" | wc -l | xargs)))
        [[ -n "$param_changes" ]] && issue_count=$((issue_count + $(echo "$param_changes" | grep -c '.' 2>/dev/null || true)))
        warn "API breaking changes: ${issue_count} issue(s) found"
        return 1
    fi

    success "API compatibility: no breaking changes"
    return 0
}

quality_check_coverage() {
    info "Coverage analysis..."
    local test_log="$ARTIFACTS_DIR/test-results.log"

    if [[ ! -f "$test_log" ]]; then
        info "No test results — skipping coverage check"
        return 0
    fi

    # Extract coverage percentage using shared parser
    local coverage=""
    coverage=$(parse_coverage_from_output "$test_log")

    # Claude fallback: parse test output when no pattern matches
    if [[ -z "$coverage" ]]; then
        local intel_enabled_cov="false"
        local _dc_intel_cov
        if declare -f _load_daemon_config >/dev/null 2>&1; then
            _dc_intel_cov=$(_load_daemon_config)
        else
            _dc_intel_cov=$(cat "${PROJECT_ROOT:-.}/.claude/daemon-config.json" 2>/dev/null || echo '{}')
        fi
        intel_enabled_cov=$(echo "$_dc_intel_cov" | jq -r '.intelligence.enabled // false' 2>/dev/null || echo "false")
        if [[ "$intel_enabled_cov" == "true" ]] && _pipeline_quality_ai_ready; then
            local tail_cov_output
            tail_cov_output=$(tail -40 "$test_log" 2>/dev/null || true)
            if [[ -n "$tail_cov_output" ]]; then
                coverage=$(_pipeline_quality_ai_text "Extract ONLY the overall code coverage percentage from this test output. Reply with ONLY a number (e.g. 85.5). If no coverage found, reply NONE.

$tail_cov_output" "haiku" "4" | grep -oE '^[0-9.]+$' | head -1 || true)
                [[ "$coverage" == "NONE" ]] && coverage=""
            fi
        fi
    fi

    if [[ -z "$coverage" ]]; then
        info "Could not extract coverage — skipping"
        return 0
    fi

    emit_event "quality.coverage" \
        "issue=${ISSUE_NUMBER:-0}" \
        "coverage=$coverage"

    # Check against pipeline config minimum
    local coverage_min
    coverage_min=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.coverage_min) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$coverage_min" || "$coverage_min" == "null" ]] && coverage_min=0

    # Adaptive baseline: read from baselines file, enforce no-regression (>= baseline - 2%)
    local repo_hash_cov
    repo_hash_cov=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_cov}"
    local coverage_baseline_file="${baselines_dir}/coverage.json"

    local baseline_coverage=""
    if [[ -f "$coverage_baseline_file" ]]; then
        baseline_coverage=$(jq -r '.baseline // empty' "$coverage_baseline_file" 2>/dev/null) || true
    fi
    # Fallback: try legacy memory baseline
    if [[ -z "$baseline_coverage" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        baseline_coverage=$(bash "$SCRIPT_DIR/sw-memory.sh" get "coverage_pct" 2>/dev/null) || true
    fi

    local dropped=false
    if [[ -n "$baseline_coverage" && "$baseline_coverage" != "0" ]] && awk -v cur="$coverage" -v base="$baseline_coverage" 'BEGIN{exit !(base > 0)}' 2>/dev/null; then
        # Adaptive: allow 2% regression tolerance from baseline
        local min_allowed
        min_allowed=$(awk -v base="$baseline_coverage" 'BEGIN{printf "%d", base - 2}')
        if awk -v cur="$coverage" -v min="$min_allowed" 'BEGIN{exit !(cur < min)}' 2>/dev/null; then
            warn "Coverage regression: ${baseline_coverage}% → ${coverage}% (adaptive min: ${min_allowed}%)"
            dropped=true
        fi
    fi

    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null && awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
        warn "Coverage ${coverage}% below minimum ${coverage_min}%"
        return 1
    fi

    if $dropped; then
        return 1
    fi

    # Update baseline on success (first run or improvement)
    if [[ -z "$baseline_coverage" ]] || awk -v cur="$coverage" -v base="$baseline_coverage" 'BEGIN{exit !(cur >= base)}' 2>/dev/null; then
        mkdir -p "$baselines_dir"
        local tmp_cov_baseline
        tmp_cov_baseline=$(mktemp "${baselines_dir}/coverage.json.XXXXXX")
        jq -n --arg baseline "$coverage" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{baseline: ($baseline | tonumber), updated: $updated}' > "$tmp_cov_baseline" 2>/dev/null
        mv "$tmp_cov_baseline" "$coverage_baseline_file" 2>/dev/null || true
    fi

    info "Coverage: ${coverage}%${baseline_coverage:+ (baseline: ${baseline_coverage}%)}"
    return 0
}

# ─── Compound Quality Checks ──────────────────────────────────────────────
# Adversarial review, negative prompting, E2E validation, and DoD audit.
# Feeds findings back into a self-healing rebuild loop for automatic fixes.

run_adversarial_review() {
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    local diff_content
    diff_content=$(git diff "origin/${BASE_BRANCH:-main}...HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null || true)

    if [[ -z "$diff_content" ]]; then
        info "No diff to review"
        return 0
    fi

    # Delegate to sw-adversarial.sh module when available (uses intelligence cache)
    if type adversarial_review >/dev/null 2>&1; then
        info "Using intelligence-backed adversarial review..."
        local json_result
        json_result=$(adversarial_review "$diff_content" "${GOAL:-}" 2>/dev/null || echo "[]")

        # Save raw JSON result
        echo "$json_result" > "$ARTIFACTS_DIR/adversarial-review.json"

        # Stamp each finding with current commit SHA (matches compound-audit.sh per-finding pattern)
        local _adv_json_sha
        _adv_json_sha=$(_pipeline_head_sha)
        if [[ -n "$_adv_json_sha" ]]; then
            local _adv_json_tmp
            _adv_json_tmp=$(mktemp "${TMPDIR:-/tmp}/sw-adv-stamp.XXXXXX")
            jq --arg c "$_adv_json_sha" '[.[] | . + {created_at_commit: $c}]' "$ARTIFACTS_DIR/adversarial-review.json" > "$_adv_json_tmp" 2>/dev/null && mv "$_adv_json_tmp" "$ARTIFACTS_DIR/adversarial-review.json" || rm -f "$_adv_json_tmp"
        fi

        # Convert JSON findings to markdown for compatibility with compound_rebuild_with_feedback
        local critical_count high_count
        critical_count=$(echo "$json_result" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo "0")
        high_count=$(echo "$json_result" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")
        local total_findings
        total_findings=$(echo "$json_result" | jq 'length' 2>/dev/null || echo "0")

        # Generate markdown report from JSON
        {
            echo "# Adversarial Review (Intelligence-backed)"
            echo ""
            echo "Total findings: ${total_findings} (${critical_count} critical, ${high_count} high)"
            echo ""
            echo "$json_result" | jq -r '.[] | "- **[\(.severity // "unknown")]** \(.location // "unknown") — \(.description // .concern // "no description")"' 2>/dev/null || true
        } > "$ARTIFACTS_DIR/adversarial-review.md"

        # Stamp markdown with current commit SHA
        local _adv_md_sha
        _adv_md_sha=$(_pipeline_head_sha)
        if [[ -n "$_adv_md_sha" ]]; then
            local _adv_md_tmp
            _adv_md_tmp=$(mktemp "${TMPDIR:-/tmp}/sw-adv-md-stamp.XXXXXX")
            { printf 'created_at_commit: %s\n' "$_adv_md_sha"; cat "$ARTIFACTS_DIR/adversarial-review.md"; } > "$_adv_md_tmp" && mv "$_adv_md_tmp" "$ARTIFACTS_DIR/adversarial-review.md" || rm -f "$_adv_md_tmp"
        fi

        emit_event "adversarial.delegated" \
            "issue=${ISSUE_NUMBER:-0}" \
            "findings=$total_findings" \
            "critical=$critical_count" \
            "high=$high_count"

        if [[ "$critical_count" -gt 0 ]]; then
            warn "Adversarial review: ${critical_count} critical, ${high_count} high"
            return 1
        elif [[ "$high_count" -gt 0 ]]; then
            warn "Adversarial review: ${high_count} high-severity issues"
            return 1
        fi

        success "Adversarial review: clean"
        return 0
    fi

    # Fallback: inline Claude call when module not loaded

    # Inject previous adversarial findings from memory
    local adv_memory=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        adv_memory=$(intelligence_search_memory "adversarial review security findings for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
    fi

    # Seam (b): redact out-of-scope paths from diff_content and adv_memory before
    # adversarial-review prompt construction. adv_memory cites paths from previous runs;
    # diff_content may reference helper files adjacent to changed files.
    local _pqc_scope_allowlist=""
    _pqc_scope_allowlist=$(_extract_scope_from_design 2>/dev/null || true)
    local _pqc_diff="$diff_content"
    local _pqc_mem="$adv_memory"
    if [ -n "$_pqc_scope_allowlist" ]; then
        _pqc_diff=$(_redact_paths_outside_scope "$diff_content" "$_pqc_scope_allowlist" \
            "adversarial_diff" "${COMPOUND_QUALITY_CYCLE:-0}" 2>/dev/null || printf '%s' "$diff_content")
        _pqc_mem=$(_redact_paths_outside_scope "$adv_memory" "$_pqc_scope_allowlist" \
            "adversarial_memory" "${COMPOUND_QUALITY_CYCLE:-0}" 2>/dev/null || printf '%s' "$adv_memory")
    fi

    local prompt="You are a hostile code reviewer. Your job is to find EVERY possible issue in this diff.
Look for:
- Bugs (logic errors, off-by-one, null/undefined access, race conditions)
- Security vulnerabilities (injection, XSS, CSRF, auth bypass, secrets in code)
- Edge cases that aren't handled
- Error handling gaps
- Performance issues (N+1 queries, memory leaks, blocking calls)
- API contract violations
- Data validation gaps

Be thorough and adversarial. List every issue with severity [Critical/Bug/Warning].
Format: **[Severity]** file:line — description
${_pqc_mem:+
## Known Security Issues from Previous Reviews
These security issues have been found in past reviews. Check if any recur:
${_pqc_mem}
}
Diff:
$_pqc_diff"

    local review_output
    review_output=$(_pipeline_quality_ai_text "$prompt" "haiku" "8")

    echo "$review_output" > "$ARTIFACTS_DIR/adversarial-review.md"

    # Stamp markdown with current commit SHA
    local _adv_inline_sha
    _adv_inline_sha=$(_pipeline_head_sha)
    if [[ -n "$_adv_inline_sha" ]]; then
        local _adv_inline_tmp
        _adv_inline_tmp=$(mktemp "${TMPDIR:-/tmp}/sw-adv-stamp.XXXXXX")
        { printf 'created_at_commit: %s\n' "$_adv_inline_sha"; cat "$ARTIFACTS_DIR/adversarial-review.md"; } > "$_adv_inline_tmp" && mv "$_adv_inline_tmp" "$ARTIFACTS_DIR/adversarial-review.md" || rm -f "$_adv_inline_tmp"
    fi

    # Count issues by severity
    local critical_count bug_count
    critical_count=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
    critical_count="${critical_count:-0}"
    bug_count=$(grep -ciE '\*\*\[?Bug\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
    bug_count="${bug_count:-0}"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Adversarial review: ${critical_count} critical, ${bug_count} bugs"
        return 1
    elif [[ "$bug_count" -gt 0 ]]; then
        warn "Adversarial review: ${bug_count} bugs found"
        return 1
    fi

    success "Adversarial review: clean"
    return 0
}

run_negative_prompting() {
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    local changed_files
    changed_files=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null | _filter_gitignored_paths || true)

    if [[ -z "$changed_files" ]]; then
        info "No changed files to analyze"
        return 0
    fi

    # Read contents of changed files and gather diffs
    local file_contents=""
    local diff_contents=""
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            file_contents+="
--- $file ---
$(head -200 "$file" 2>/dev/null || true)
"
            local file_diff
            file_diff=$(git diff "origin/${BASE_BRANCH:-main}...HEAD" -- "$file" 2>/dev/null || true)
            if [[ -n "$file_diff" ]]; then
                diff_contents+="
--- diff: $file ---
$file_diff
"
            fi
        fi
    done <<< "$changed_files"

    # Inject previous negative prompting findings from memory
    local neg_memory=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        neg_memory=$(intelligence_search_memory "negative prompting findings common concerns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
    fi

    local prompt="You are a pessimistic engineer who assumes everything will break.
You are provided BOTH the full file context AND the actual diff (lines added/removed in this PR).

IMPORTANT SCOPING RULES:
- Issues INTRODUCED BY THE DIFF (lines starting with '+' in the diff): categorize as [Critical], [Concern], or [Minor]. These can block the build.
- Issues found in the file context that are NOT related to the diff (pre-existing code): categorize as [Pre-existing]. Do NOT use [Critical], [Concern], or [Minor] for these. Describe them as recommendations for future issues. These must NOT block the build.

Review the diff and answer:
1. What could go wrong in production due to the changes in the diff?
2. What did the developer miss in the changes?
3. What's fragile in the new code and will break when requirements change?
4. What assumptions in the new code might not hold?
5. What happens under load/stress with the new code?
6. What happens with malicious input targeting the new code?
7. Are there any implicit dependencies introduced by the diff that could break?
${neg_memory:+
## Known Concerns from Previous Reviews
These issues have been found in past reviews of this codebase. Check if any apply to the current changes:
${neg_memory}
}
Be specific. Reference actual code. Use [Critical], [Concern], [Minor], or [Pre-existing] tags for every finding.

Files changed: $changed_files

## Full File Context (for reference)
$file_contents

## Actual Diff (what changed in this PR)
$diff_contents"

    local review_output
    review_output=$(_pipeline_quality_ai_text "$prompt" "haiku" "8")

    echo "$review_output" > "$ARTIFACTS_DIR/negative-review.md"

    # Stamp markdown with current commit SHA
    local _neg_sha
    _neg_sha=$(_pipeline_head_sha)
    if [[ -n "$_neg_sha" ]]; then
        local _neg_tmp
        _neg_tmp=$(mktemp "${TMPDIR:-/tmp}/sw-neg-stamp.XXXXXX")
        { printf 'created_at_commit: %s\n' "$_neg_sha"; cat "$ARTIFACTS_DIR/negative-review.md"; } > "$_neg_tmp" && mv "$_neg_tmp" "$ARTIFACTS_DIR/negative-review.md" || rm -f "$_neg_tmp"
    fi

    # Post pre-existing findings as a comment on the current GitHub issue (informational only)
    if [[ -n "${ISSUE_NUMBER:-}" ]]; then
        local preexisting_findings
        preexisting_findings=$(grep -E '\[Pre-existing\]' "$ARTIFACTS_DIR/negative-review.md" 2>/dev/null || true)
        if [[ -n "$preexisting_findings" ]]; then
            local comment_body
            comment_body="**Pre-existing issues found during negative prompting review**
These items were not introduced by this PR but were identified during review.
Consider filing separate issues for any that warrant attention:

$preexisting_findings"
            gh_comment_issue "$ISSUE_NUMBER" "$comment_body" 2>/dev/null || true
        fi
    fi

    local critical_count
    critical_count=$(grep -ciE '\[Critical\]' "$ARTIFACTS_DIR/negative-review.md" 2>/dev/null || true)
    critical_count="${critical_count:-0}"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Negative prompting: ${critical_count} critical concerns"
        return 1
    fi

    success "Negative prompting: no critical concerns"
    return 0
}

run_e2e_validation() {
    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi

    if [[ -z "$test_cmd" ]]; then
        warn "No test command configured — skipping E2E validation"
        return 0
    fi

    # Reuse test stage results if available and passing (sidecar-first, then grep fallback)
    local test_log="$ARTIFACTS_DIR/test-results.log"
    local _ec=""
    _ec=$(pipeline_test_status 2>/dev/null || true)
    if [[ "$_ec" == "0" ]]; then
        success "E2E validation passed (reusing test stage results)"
        cp "$test_log" "$ARTIFACTS_DIR/e2e-validation.log" 2>/dev/null || true
        return 0
    elif [[ -z "$_ec" ]]; then
        if [[ -f "$test_log" ]] && ! grep -qiE '(tests? failed|[1-9][0-9]* failure|[1-9][0-9]* failed|\bFAIL\b)' "$test_log" 2>/dev/null; then
            success "E2E validation passed (reusing test stage results)"
            cp "$test_log" "$ARTIFACTS_DIR/e2e-validation.log" 2>/dev/null || true
            return 0
        fi
    fi

    info "Running E2E validation: $test_cmd"
    local e2e_rc=0
    _timeout "${PIPELINE_TEST_TIMEOUT:-300}" bash -c "$test_cmd" 2>&1 | tee "$ARTIFACTS_DIR/e2e-validation.log" || e2e_rc=$?
    if [[ "$e2e_rc" -eq 0 ]]; then
        success "E2E validation passed"
        return 0
    else
        error "E2E validation failed"
        return 1
    fi
}

run_dod_audit() {
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    local dod_file="$PROJECT_ROOT/.claude/DEFINITION-OF-DONE.md"

    if [[ ! -f "$dod_file" ]]; then
        # Check for alternative locations
        for alt in "$PROJECT_ROOT/DEFINITION-OF-DONE.md" "$HOME/.shipwright/templates/definition-of-done.example.md"; do
            if [[ -f "$alt" ]]; then
                dod_file="$alt"
                break
            fi
        done
    fi

    if [[ ! -f "$dod_file" ]]; then
        info "No definition-of-done found — skipping DoD audit"
        return 0
    fi

    info "Auditing Definition of Done..."

    local total=0 passed=0 failed=0
    local audit_output="# DoD Audit Results\n\n"

    while IFS= read -r line; do
        # Skip [~] lines — these are manual items deferred in autonomous mode
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[~\] ]]; then
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[[:space:]]\] ]]; then
            total=$((total + 1))
            local item="${line#*] }"

            # Try to verify common items
            local item_passed=false
            case "$item" in
                *"tests pass"*|*"test pass"*)
                    local _dod_ec=""
                    _dod_ec=$(pipeline_test_status 2>/dev/null || true)
                    if [[ "$_dod_ec" == "0" ]]; then
                        item_passed=true
                    elif [[ -z "$_dod_ec" && -f "$ARTIFACTS_DIR/test-results.log" ]]; then
                        # Sidecar absent but log exists — use grep fallback (handles pre-sidecar artifacts)
                        if grep -qiE '(0 failures|0 failed|tests passed|all tests passed)' "$ARTIFACTS_DIR/test-results.log" 2>/dev/null && \
                           ! grep -qiE '([1-9][0-9]* (failures|failed)|FAILED|FAILURE)' "$ARTIFACTS_DIR/test-results.log" 2>/dev/null; then
                            item_passed=true
                        fi
                    elif [[ -z "$_dod_ec" ]]; then
                        # Sidecar absent AND log absent — default pass (matches convention for unverifiable items)
                        item_passed=true
                    fi
                    ;;
                *"lint"*|*"Lint"*)
                    if [[ -f "$ARTIFACTS_DIR/lint.log" ]] && ! grep -qi "error" "$ARTIFACTS_DIR/lint.log" 2>/dev/null; then
                        item_passed=true
                    fi
                    ;;
                *"console.log"*|*"print("*)
                    local debug_count
                    debug_count=$(git diff "origin/${BASE_BRANCH:-main}...HEAD" 2>/dev/null | grep -c "^+.*console\.log\|^+.*print(" 2>/dev/null || true)
                    debug_count="${debug_count:-0}"
                    if [[ "$debug_count" -eq 0 ]]; then
                        item_passed=true
                    fi
                    ;;
                *"coverage"*)
                    item_passed=true  # Trust test stage coverage check
                    ;;
                *)
                    item_passed=true  # Default pass for items we can't auto-verify
                    ;;
            esac

            if $item_passed; then
                passed=$((passed + 1))
                audit_output+="- [x] $item\n"
            else
                failed=$((failed + 1))
                audit_output+="- [ ] $item ❌\n"
            fi
        fi
    done < "$dod_file"

    echo -e "$audit_output\n\n**Score: ${passed}/${total} passed**" > "$ARTIFACTS_DIR/dod-audit.md"

    # Append skipped count if classification sidecar exists
    local _skipped_count=0
    if [[ -f "${ARTIFACTS_DIR}/dod-classification.json" ]]; then
        _skipped_count=$(jq -r '.skipped_manual // 0' "${ARTIFACTS_DIR}/dod-classification.json" 2>/dev/null || echo 0)
    fi
    if [[ "$_skipped_count" -gt 0 ]]; then
        echo -e "\n_${_skipped_count} item(s) skipped (require human verification)_" >> "$ARTIFACTS_DIR/dod-audit.md"
    fi

    # Stamp markdown with current commit SHA
    local _dod_sha
    _dod_sha=$(_pipeline_head_sha)
    if [[ -n "$_dod_sha" ]]; then
        local _dod_tmp
        _dod_tmp=$(mktemp "${TMPDIR:-/tmp}/sw-dod-stamp.XXXXXX")
        { printf 'created_at_commit: %s\n' "$_dod_sha"; cat "$ARTIFACTS_DIR/dod-audit.md"; } > "$_dod_tmp" && mv "$_dod_tmp" "$ARTIFACTS_DIR/dod-audit.md" || rm -f "$_dod_tmp"
    fi

    # If all items were skipped (all manual), pass with a warning.
    # Counts come from dod-classification.json (which knows the ORIGINAL DoD count
    # before [~] stripping). Counting from dod-audit.md would zero out for an
    # all-manual plan (since [~] items are dropped), defeating the guard.
    if [[ "$total" -eq 0 ]]; then
        local _skipped_c=0 _orig_total=0
        if [[ -f "${ARTIFACTS_DIR}/dod-classification.json" ]]; then
            _skipped_c=$(jq -r '.skipped_manual // 0' "${ARTIFACTS_DIR}/dod-classification.json" 2>/dev/null || echo 0)
            _orig_total=$(jq -r '.total // 0' "${ARTIFACTS_DIR}/dod-classification.json" 2>/dev/null || echo 0)
        fi
        if [[ "$_orig_total" -gt 0 && "$_skipped_c" -ge "$_orig_total" ]]; then
            error "DoD audit: all ${_orig_total} item(s) classified as manual — at least one item must be auto-verified"
            return 1
        fi
        if [[ "$_skipped_c" -gt 0 ]]; then
            warn "DoD audit: ${_skipped_c} items are manual — skipped in autonomous mode (passing)"
            return 0
        fi
        warn "DoD audit: no items found in dod.md"
        return 0
    fi
    if [[ "$failed" -gt 0 ]]; then
        warn "DoD audit: ${passed}/${total} passed, ${failed} failed"
        return 1
    fi

    success "DoD audit: ${passed}/${total} passed"
    return 0
}

# ─── Intelligent Pipeline Orchestration ──────────────────────────────────────
# AGI-like decision making: skip, classify, adapt, reassess, backtrack

# Global state for intelligence features
PIPELINE_BACKTRACK_COUNT="${PIPELINE_BACKTRACK_COUNT:-0}"
PIPELINE_MAX_BACKTRACKS=2
PIPELINE_ADAPTIVE_COMPLEXITY=""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Intelligent Stage Skipping
# Evaluates whether a stage should be skipped based on triage score, complexity,
# issue labels, and diff size. Called before each stage in run_pipeline().
# Returns 0 if the stage SHOULD be skipped, 1 if it should run.
# ──────────────────────────────────────────────────────────────────────────────

# Scans modified .sh files for common bash 3.2 incompatibilities
# Returns: count of violations found
# ──────────────────────────────────────────────────────────────────────────────
run_bash_compat_check() {
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    local violations=0
    local violation_details=""

    # Get modified .sh files relative to base branch
    local changed_files
    changed_files=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" -- '*.sh' 2>/dev/null || echo "")

    if [[ -z "$changed_files" ]]; then
        echo "0"
        return 0
    fi

    # Check each file for bash 3.2 incompatibilities
    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue

        # declare -A (associative arrays; declare -a is bash 3.2 compatible)
        local declare_a_count
        declare_a_count=$(grep -c 'declare[[:space:]]*-A' "$filepath" 2>/dev/null || true)
        if [[ "$declare_a_count" -gt 0 ]]; then
            violations=$((violations + declare_a_count))
            violation_details="${violation_details}${filepath}: declare -A (${declare_a_count} occurrences)
"
        fi

        # readarray or mapfile
        local readarray_count
        readarray_count=$(grep -c 'readarray\|mapfile' "$filepath" 2>/dev/null || true)
        if [[ "$readarray_count" -gt 0 ]]; then
            violations=$((violations + readarray_count))
            violation_details="${violation_details}${filepath}: readarray/mapfile (${readarray_count} occurrences)
"
        fi

        # ${var,,} or ${var^^} (case conversion)
        local case_conv_count
        case_conv_count=$(grep -c '\$\{[a-zA-Z_][a-zA-Z0-9_]*,,' "$filepath" 2>/dev/null || true)
        case_conv_count=$((case_conv_count + $(grep -c '\$\{[a-zA-Z_][a-zA-Z0-9_]*\^\^' "$filepath" 2>/dev/null || true)))
        if [[ "$case_conv_count" -gt 0 ]]; then
            violations=$((violations + case_conv_count))
            violation_details="${violation_details}${filepath}: case conversion \$\{var,,\} or \$\{var\^\^\} (${case_conv_count} occurrences)
"
        fi

        # |& (pipe stderr to stdout in-place)
        local pipe_ampersand_count
        pipe_ampersand_count=$(grep -c '|&' "$filepath" 2>/dev/null || true)
        if [[ "$pipe_ampersand_count" -gt 0 ]]; then
            violations=$((violations + pipe_ampersand_count))
            violation_details="${violation_details}${filepath}: |& operator (${pipe_ampersand_count} occurrences)
"
        fi

        # ;& or ;;& in case statements (advanced fallthrough)
        local advanced_case_count
        advanced_case_count=$(grep -c ';&\|;;&' "$filepath" 2>/dev/null || true)
        if [[ "$advanced_case_count" -gt 0 ]]; then
            violations=$((violations + advanced_case_count))
            violation_details="${violation_details}${filepath}: advanced case ;& or ;;& (${advanced_case_count} occurrences)
"
        fi

    done <<< "$changed_files"

    # Log details if violations found
    if [[ "$violations" -gt 0 ]]; then
        warn "Bash 3.2 compatibility check: ${violations} violation(s) found:"
        echo "$violation_details" | sed 's/^/  /'
    fi

    echo "$violations"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test Coverage Check
# Runs configured test command and extracts coverage percentage
# Returns: coverage percentage (0-100), or "skip" if no test command configured
# ──────────────────────────────────────────────────────────────────────────────
run_test_coverage_check() {
    local test_cmd="${TEST_CMD:-}"
    if [[ -z "$test_cmd" ]]; then
        echo "skip"
        return 0
    fi

    # Reuse coverage from test stage if available
    local cached_coverage="$ARTIFACTS_DIR/test-coverage.json"
    if [[ -f "$cached_coverage" ]]; then
        local cached_pct
        cached_pct=$(jq -r '.coverage_pct // empty' "$cached_coverage" 2>/dev/null) || true
        if [[ -n "$cached_pct" && "$cached_pct" =~ ^[0-9]+$ ]]; then
            success "Test coverage (from test stage): ${cached_pct}%"
            echo "$cached_pct"
            return 0
        fi
    fi

    # Redirect test output fully to log — swallowed from GHA step stdout but
    # preserved in ARTIFACTS_DIR for upload and post-mortem investigation.
    # All status messages go to stderr so they remain visible in the GHA log
    # even when the caller captures stdout via $(...).
    local coverage_log="$ARTIFACTS_DIR/coverage-run.log"
    local test_rc=0
    _timeout "${PIPELINE_TEST_TIMEOUT:-300}" bash -c "$test_cmd" > "$coverage_log" 2>&1 || test_rc=$?

    if [[ "$test_rc" -ne 0 ]]; then
        warn "Test command failed (exit code: $test_rc) — cannot extract coverage" >&2
        echo "0"
        return 0
    fi

    # Extract coverage percentage from various formats
    # Patterns: "XX% coverage", "Lines: XX%", "Stmts: XX%", "Coverage: XX%", "coverage XX%"
    local coverage_pct
    coverage_pct=$(grep -oE '[0-9]{1,3}%[[:space:]]*(coverage|lines|stmts|statements)' "$coverage_log" | grep -oE '^[0-9]{1,3}' | head -1 || true)

    if [[ -z "$coverage_pct" ]]; then
        coverage_pct=$(grep -oE 'coverage[:]?[[:space:]]*[0-9]{1,3}' "$coverage_log" | grep -oE '[0-9]{1,3}' | head -1 || true)
    fi

    if [[ -z "$coverage_pct" ]]; then
        warn "Could not extract coverage percentage from test output" >&2
        echo "0"
        return 0
    fi

    # Ensure it's a valid percentage (0-100)
    if [[ ! "$coverage_pct" =~ ^[0-9]{1,3}$ ]] || [[ "$coverage_pct" -gt 100 ]]; then
        coverage_pct=0
    fi

    success "Test coverage: ${coverage_pct}%" >&2
    echo "$coverage_pct"
}

# ──────────────────────────────────────────────────────────────────────────────
# Atomic Write Violations Check
# Scans modified files for anti-patterns: direct echo > file to state/config files
# Returns: count of violations found
# ──────────────────────────────────────────────────────────────────────────────
run_atomic_write_check() {
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    local violations=0
    local violation_details=""

    # Get modified files (not just .sh — includes state/config files)
    local changed_files
    changed_files=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" 2>/dev/null || echo "")

    if [[ -z "$changed_files" ]]; then
        echo "0"
        return 0
    fi

    # Check for direct writes to state/config files (patterns that should use tmp+mv)
    # Look for: echo "..." > state/config files
    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue

        # Only check state/config/artifacts files
        if [[ ! "$filepath" =~ (state|config|artifact|cache|db|json)$ ]]; then
            continue
        fi

        # Check for direct redirection writes (> file) in state/config paths
        local bad_writes
        bad_writes=$(git show "HEAD:$filepath" 2>/dev/null | grep -c 'echo.*>' 2>/dev/null || true)
        bad_writes="${bad_writes:-0}"

        if [[ "$bad_writes" -gt 0 ]]; then
            violations=$((violations + bad_writes))
            violation_details="${violation_details}${filepath}: ${bad_writes} direct write(s) (should use tmp+mv)
"
        fi
    done <<< "$changed_files"

    if [[ "$violations" -gt 0 ]]; then
        warn "Atomic write violations: ${violations} found (should use tmp file + mv pattern):"
        echo "$violation_details" | sed 's/^/  /'
    fi

    echo "$violations"
}

# ──────────────────────────────────────────────────────────────────────────────
# New Function Test Detection
# Detects new functions added in the diff but checks if corresponding tests exist
# Returns: count of untested new functions
# ──────────────────────────────────────────────────────────────────────────────
run_new_function_test_check() {
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    local untested_functions=0
    local details=""

    # Get diff
    local diff_content
    diff_content=$(git diff "origin/${BASE_BRANCH:-main}...HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null || true)

    if [[ -z "$diff_content" ]]; then
        echo "0"
        return 0
    fi

    # Extract newly added function definitions (lines starting with +functionname())
    local new_functions
    new_functions=$(echo "$diff_content" | grep -E '^\+[a-zA-Z_][a-zA-Z0-9_]*\(\)' | sed 's/^\+//' | sed 's/()//' || true)

    if [[ -z "$new_functions" ]]; then
        echo "0"
        return 0
    fi

    # For each new function, check if test files were modified
    local test_files_modified=0
    test_files_modified=$(echo "$diff_content" | grep -c '\-\-\-.*test\|\.test\.\|_test\.' || true)

    # Simple heuristic: if we have new functions but no test file modifications, warn
    if [[ "$test_files_modified" -eq 0 ]]; then
        local func_count
        func_count=$(_trim "$(echo "$new_functions" | wc -l)")
        untested_functions="$func_count"
        details="Added ${func_count} new function(s) but no test file modifications detected"
    fi

    if [[ "$untested_functions" -gt 0 ]]; then
        warn "New functions without tests: ${details}" >&2
    fi

    echo "$untested_functions"
}
