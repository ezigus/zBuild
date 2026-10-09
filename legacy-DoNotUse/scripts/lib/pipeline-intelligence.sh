# pipeline-intelligence.sh — Skip/adaptive/audits/DoD/security/compound_quality for sw-pipeline.sh
# Source from sw-pipeline.sh. Requires pipeline-quality-checks, state, ARTIFACTS_DIR, PIPELINE_CONFIG.
[[ -n "${_PIPELINE_INTELLIGENCE_LOADED:-}" ]] && return 0
_PIPELINE_INTELLIGENCE_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NO_GITHUB="${NO_GITHUB:-false}"

# Source compat.sh first — pipeline-quality-checks.sh depends on file_mtime() and date_to_epoch()
if [[ -f "${SCRIPT_DIR}/lib/compat.sh" ]]; then
    source "${SCRIPT_DIR}/lib/compat.sh"
fi

# Source pipeline-quality-checks for SHA helpers (pipeline_artifact_is_current, _pipeline_head_sha)
if [[ -f "${SCRIPT_DIR}/lib/pipeline-quality-checks.sh" ]]; then
    source "${SCRIPT_DIR}/lib/pipeline-quality-checks.sh"
fi

# Source compound audit cascade library (fail-open)
if [[ -f "${SCRIPT_DIR}/lib/compound-audit.sh" ]]; then
    _COMPOUND_AUDIT_LOADED=""
    source "${SCRIPT_DIR}/lib/compound-audit.sh"
fi

# Source config reader (defensive — host script may have loaded it already)
if [[ -f "${SCRIPT_DIR}/lib/config.sh" ]]; then
    source "${SCRIPT_DIR}/lib/config.sh"
fi

pipeline_should_skip_stage() {
    local stage_id="$1"
    local reason=""

    # Never skip intake or build — they're always required
    case "$stage_id" in
        intake|build|test|pr|merge) return 1 ;;
    esac

    # ── Signal 1: Triage score (from intelligence analysis) ──
    local triage_score="${INTELLIGENCE_COMPLEXITY:-0}"
    # Convert: high triage score (simple issue) means skip more stages
    # INTELLIGENCE_COMPLEXITY is 1-10 (1=simple, 10=complex)
    # Score >= 70 in daemon means simple → complexity 1-3
    local complexity="${INTELLIGENCE_COMPLEXITY:-5}"

    # ── Signal 2: Issue labels ──
    local labels="${ISSUE_LABELS:-}"

    # Documentation issues: skip test, review, compound_quality
    if echo ",$labels," | grep -qiE ',documentation,|,docs,|,typo,'; then
        case "$stage_id" in
            test|review|compound_quality)
                reason="label:documentation"
                ;;
        esac
    fi

    # Hotfix issues: skip plan, design, compound_quality
    if echo ",$labels," | grep -qiE ',hotfix,|,urgent,|,p0,'; then
        case "$stage_id" in
            plan|design|compound_quality)
                reason="label:hotfix"
                ;;
        esac
    fi

    # ── Signal 3: Intelligence complexity ──
    if [[ -z "$reason" && "$complexity" -gt 0 ]]; then
        # Complexity 1-2: very simple → skip design, compound_quality, review
        if [[ "$complexity" -le 2 ]]; then
            case "$stage_id" in
                design|compound_quality|review)
                    reason="complexity:${complexity}/10"
                    ;;
            esac
        # Complexity 1-3: simple → skip design
        elif [[ "$complexity" -le 3 ]]; then
            case "$stage_id" in
                design)
                    reason="complexity:${complexity}/10"
                    ;;
            esac
        fi
    fi

    # ── Signal 4: Diff size (after build) ──
    if [[ -z "$reason" && "$stage_id" == "compound_quality" ]]; then
        local diff_lines=0
        local _skip_stat
        _skip_stat=$(git diff "${BASE_BRANCH:-main}...HEAD" --stat 2>/dev/null | tail -1) || true
        if [[ -n "${_skip_stat:-}" ]]; then
            local _s_ins _s_del
            _s_ins=$(echo "$_skip_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+') || true
            _s_del=$(echo "$_skip_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+') || true
            diff_lines=$(( ${_s_ins:-0} + ${_s_del:-0} ))
        fi
        diff_lines="${diff_lines:-0}"
        if [[ "$diff_lines" -gt 0 && "$diff_lines" -lt 20 ]]; then
            reason="diff_size:${diff_lines}_lines"
        fi
    fi

    # ── Signal 5: Mid-pipeline reassessment override ──
    if [[ -z "$reason" && -f "$ARTIFACTS_DIR/reassessment.json" ]]; then
        local skip_stages
        skip_stages=$(jq -r '.skip_stages // [] | .[]' "$ARTIFACTS_DIR/reassessment.json" 2>/dev/null || true)
        if echo "$skip_stages" | grep -qx "$stage_id" 2>/dev/null; then
            reason="reassessment:simpler_than_expected"
        fi
    fi

    if [[ -n "$reason" ]]; then
        emit_event "intelligence.stage_skipped" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "reason=$reason" \
            "complexity=${complexity}" \
            "labels=${labels}"
        echo "$reason"
        return 0
    fi

    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Smart Finding Classification & Routing
# Parses compound quality findings and classifies each as:
#   architecture, security, correctness, style
# Returns JSON with classified findings and routing recommendations.
# ──────────────────────────────────────────────────────────────────────────────
classify_quality_findings() {
    local findings_dir="${1:-$ARTIFACTS_DIR}"
    local result_file="$findings_dir/classified-findings.json"

    # Build combined content for semantic classification
    local content=""
    if [[ -f "$findings_dir/adversarial-review.md" ]]; then
        content="${content}
--- adversarial-review.md ---
$(head -500 "$findings_dir/adversarial-review.md" 2>/dev/null)"
    fi
    if [[ -f "$findings_dir/negative-review.md" ]]; then
        content="${content}
--- negative-review.md ---
$(head -300 "$findings_dir/negative-review.md" 2>/dev/null)"
    fi
    if [[ -f "$findings_dir/security-audit.log" ]]; then
        content="${content}
--- security-audit.log ---
$(cat "$findings_dir/security-audit.log" 2>/dev/null)"
    fi
    if [[ -f "$findings_dir/compound-architecture-validation.json" ]]; then
        content="${content}
--- compound-architecture-validation.json ---
$(jq -r '.[] | "\(.severity): \(.message // .description // .)"' "$findings_dir/compound-architecture-validation.json" 2>/dev/null | head -50)"
    fi

    # Try semantic classification first when Claude is available
    local route=""
    if command -v claude &>/dev/null && [[ "${INTELLIGENCE_ENABLED:-false}" != "false" ]] && [[ -n "$content" ]]; then
        local prompt="Classify these code review findings into exactly ONE primary category. Return ONLY a single word: security, architecture, correctness, performance, testing, documentation, style.

Findings:
$content"
        local category
        category=$(echo "$prompt" | timeout 30 claude -p --model sonnet 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [[ "$category" =~ ^(security|architecture|correctness|performance|testing|documentation|style)$ ]]; then
            route="$category"
        fi
    fi

    # Initialize counters
    local arch_count=0 security_count=0 correctness_count=0 performance_count=0 testing_count=0 style_count=0

    # Start building JSON array
    local findings_json="[]"

    # ── Parse adversarial review ──
    if [[ -f "$findings_dir/adversarial-review.md" ]]; then
        local adv_content
        adv_content=$(cat "$findings_dir/adversarial-review.md" 2>/dev/null || true)

        # Architecture findings: dependency violations, layer breaches, circular refs
        local arch_findings
        arch_findings=$(echo "$adv_content" | grep -ciE 'architect|layer.*violation|circular.*depend|coupling|abstraction|design.*flaw|separation.*concern' 2>/dev/null || true)
        arch_count=$((arch_count + ${arch_findings:-0}))

        # Security findings
        local sec_findings
        sec_findings=$(echo "$adv_content" | grep -ciE 'security|vulnerab|injection|XSS|CSRF|auth.*bypass|privilege|sanitiz|escap' 2>/dev/null || true)
        security_count=$((security_count + ${sec_findings:-0}))

        # Correctness findings: bugs, logic errors, edge cases
        local corr_findings
        corr_findings=$(echo "$adv_content" | grep -ciE '\*\*\[?(Critical|Bug|Error|critical|high)\]?\*\*|race.*condition|null.*pointer|off.*by.*one|edge.*case|undefined.*behav' 2>/dev/null || true)
        correctness_count=$((correctness_count + ${corr_findings:-0}))

        # Performance findings
        local perf_findings
        perf_findings=$(echo "$adv_content" | grep -ciE 'latency|slow|memory leak|O\(n|N\+1|cache miss|performance|bottleneck|throughput' 2>/dev/null || true)
        performance_count=$((performance_count + ${perf_findings:-0}))

        # Testing findings
        local test_findings
        test_findings=$(echo "$adv_content" | grep -ciE 'untested|missing test|no coverage|flaky|test gap|test missing|coverage gap' 2>/dev/null || true)
        testing_count=$((testing_count + ${test_findings:-0}))

        # Style findings
        local style_findings
        style_findings=$(echo "$adv_content" | grep -ciE 'naming|convention|format|style|readabil|inconsisten|whitespace|comment' 2>/dev/null || true)
        style_count=$((style_count + ${style_findings:-0}))
    fi

    # ── Parse architecture validation ──
    if [[ -f "$findings_dir/compound-architecture-validation.json" ]]; then
        local arch_json_count
        arch_json_count=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' "$findings_dir/compound-architecture-validation.json" 2>/dev/null || echo "0")
        arch_count=$((arch_count + ${arch_json_count:-0}))
    fi

    # ── Parse security audit ──
    if [[ -f "$findings_dir/security-audit.log" ]]; then
        local sec_audit
        sec_audit=$(grep -ciE 'critical|high' "$findings_dir/security-audit.log" 2>/dev/null || true)
        security_count=$((security_count + ${sec_audit:-0}))
    fi

    # ── Parse negative review ──
    if [[ -f "$findings_dir/negative-review.md" ]]; then
        local neg_corr
        neg_corr=$(grep -ciE '\[Critical\]|\[High\]' "$findings_dir/negative-review.md" 2>/dev/null || true)
        correctness_count=$((correctness_count + ${neg_corr:-0}))
    fi

    # ── Scope check: highest priority — overrides semantic classification ──
    # If scope-violations.txt exists and has content, route to scope revert regardless of other findings.
    local _scope_viol_file="${findings_dir}/issue-${ISSUE_NUMBER:-0}/logs/scope-violations.txt"
    if [[ -f "$_scope_viol_file" ]] && [[ -s "$_scope_viol_file" ]]; then
        route="scope"
    fi

    # ── Determine routing ──
    # Use semantic classification when available; else fall back to grep-derived priority
    local needs_backtrack=false
    local priority_findings=""

    if [[ -z "$route" ]]; then
        # Fallback: grep-based priority order: security > architecture > correctness > performance > testing > style
        route="correctness"

        if [[ "$security_count" -gt 0 ]]; then
            route="security"
            priority_findings="security:${security_count}"
        fi

        if [[ "$arch_count" -gt 0 ]]; then
            if [[ "$route" == "correctness" ]]; then
                route="architecture"
                needs_backtrack=true
            fi
            priority_findings="${priority_findings:+${priority_findings},}architecture:${arch_count}"
        fi

        if [[ "$correctness_count" -gt 0 ]]; then
            priority_findings="${priority_findings:+${priority_findings},}correctness:${correctness_count}"
        fi

        if [[ "$performance_count" -gt 0 ]]; then
            if [[ "$route" == "correctness" && "$correctness_count" -eq 0 ]]; then
                route="performance"
            fi
            priority_findings="${priority_findings:+${priority_findings},}performance:${performance_count}"
        fi

        if [[ "$testing_count" -gt 0 ]]; then
            if [[ "$route" == "correctness" && "$correctness_count" -eq 0 && "$performance_count" -eq 0 ]]; then
                route="testing"
            fi
            priority_findings="${priority_findings:+${priority_findings},}testing:${testing_count}"
        fi
    else
        # Semantic route: build priority_findings from counts, set needs_backtrack for architecture
        [[ "$route" == "architecture" ]] && needs_backtrack=true
        [[ "$arch_count" -gt 0 ]] && priority_findings="architecture:${arch_count}"
        [[ "$security_count" -gt 0 ]] && priority_findings="${priority_findings:+${priority_findings},}security:${security_count}"
        [[ "$correctness_count" -gt 0 ]] && priority_findings="${priority_findings:+${priority_findings},}correctness:${correctness_count}"
        [[ "$performance_count" -gt 0 ]] && priority_findings="${priority_findings:+${priority_findings},}performance:${performance_count}"
        [[ "$testing_count" -gt 0 ]] && priority_findings="${priority_findings:+${priority_findings},}testing:${testing_count}"
        [[ -z "$priority_findings" ]] && priority_findings="${route}:1"
    fi

    # Style findings don't affect routing or count toward failure threshold
    local total_blocking=$((arch_count + security_count + correctness_count + performance_count + testing_count))

    # Write classified findings
    local tmp_findings _cf_sha
    tmp_findings="$(mktemp)"
    _cf_sha=$(_pipeline_head_sha 2>/dev/null || true)
    jq -n \
        --argjson arch "$arch_count" \
        --argjson security "$security_count" \
        --argjson correctness "$correctness_count" \
        --argjson performance "$performance_count" \
        --argjson testing "$testing_count" \
        --argjson style "$style_count" \
        --argjson total_blocking "$total_blocking" \
        --arg route "$route" \
        --argjson needs_backtrack "$needs_backtrack" \
        --arg priority "$priority_findings" \
        --arg sha "${_cf_sha}" \
        '{
            architecture: $arch,
            security: $security,
            correctness: $correctness,
            performance: $performance,
            testing: $testing,
            style: $style,
            total_blocking: $total_blocking,
            route: $route,
            needs_backtrack: $needs_backtrack,
            priority_findings: $priority,
            created_at_commit: $sha
        }' > "$tmp_findings" 2>/dev/null && mv "$tmp_findings" "$result_file" || rm -f "$tmp_findings"

    emit_event "intelligence.findings_classified" \
        "issue=${ISSUE_NUMBER:-0}" \
        "architecture=$arch_count" \
        "security=$security_count" \
        "correctness=$correctness_count" \
        "performance=$performance_count" \
        "testing=$testing_count" \
        "style=$style_count" \
        "route=$route" \
        "needs_backtrack=$needs_backtrack"

    echo "$route"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Adaptive Cycle Limits
# Replaces default max_cycles with convergence-driven limits.
# Takes the base limit, returns an adjusted limit based on:
#   - Learned iteration model
#   - Convergence/divergence signals
#   - Budget constraints
#   - Hard ceiling (2x template max)
# ──────────────────────────────────────────────────────────────────────────────
pipeline_adaptive_cycles() {
    local base_limit="$1"
    local context="${2:-compound_quality}"  # compound_quality or build_test
    local current_issue_count="${3:-0}"
    local prev_issue_count="${4:--1}"

    local adjusted="$base_limit"
    local hard_ceiling=$((base_limit * 2))

    # ── Learned iteration model ──
    local model_file="${HOME}/.shipwright/optimization/iteration-model.json"
    if [[ -f "$model_file" ]]; then
        local learned
        learned=$(jq -r --arg ctx "$context" '.[$ctx].recommended_cycles // 0' "$model_file" 2>/dev/null || echo "0")
        if [[ "$learned" -gt 0 && "$learned" -le "$hard_ceiling" ]]; then
            adjusted="$learned"
        fi
    fi

    # ── Convergence acceleration ──
    # If issue count drops >50% per cycle, extend limit by 1 (we're making progress)
    if [[ "$prev_issue_count" -gt 0 && "$current_issue_count" -ge 0 ]]; then
        local half_prev=$((prev_issue_count / 2))
        if [[ "$current_issue_count" -le "$half_prev" && "$current_issue_count" -gt 0 ]]; then
            # Rapid convergence — extend by 1
            local new_limit=$((adjusted + 1))
            if [[ "$new_limit" -le "$hard_ceiling" ]]; then
                adjusted="$new_limit"
                emit_event "intelligence.convergence_acceleration" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "context=$context" \
                    "prev_issues=$prev_issue_count" \
                    "current_issues=$current_issue_count" \
                    "new_limit=$adjusted"
            fi
        fi

        # ── Divergence detection ──
        # If issue count increases, reduce remaining cycles
        if [[ "$current_issue_count" -gt "$prev_issue_count" ]]; then
            local reduced=$((adjusted - 1))
            if [[ "$reduced" -ge 1 ]]; then
                adjusted="$reduced"
                emit_event "intelligence.divergence_detected" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "context=$context" \
                    "prev_issues=$prev_issue_count" \
                    "current_issues=$current_issue_count" \
                    "new_limit=$adjusted"
            fi
        fi
    fi

    # ── Budget gate ──
    if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
        local budget_rc=0
        bash "$SCRIPT_DIR/sw-cost.sh" check-budget 2>/dev/null || budget_rc=$?
        if [[ "$budget_rc" -eq 2 ]]; then
            # Budget exhausted — cap at current cycle
            adjusted=0
            emit_event "intelligence.budget_cap" \
                "issue=${ISSUE_NUMBER:-0}" \
                "context=$context"
        fi
    fi

    # ── Enforce hard ceiling ──
    if [[ "$adjusted" -gt "$hard_ceiling" ]]; then
        adjusted="$hard_ceiling"
    fi

    echo "$adjusted"
}


# ──────────────────────────────────────────────────────────────────────────────
# 6. Definition of Done Verification
# Configurable structural test-pairing for `pipeline_verify_dod`.
# Replaces the fixed pattern loop with config-driven search via lists from
# `pipeline.dod` in defaults.json (test_dir_names, test_filename_patterns,
# search_strategies, source_roots, prefix_flat_template). Each list can be
# overridden through the precedence chain in `lib/config.sh`.
# ──────────────────────────────────────────────────────────────────────────────

# Lowercase a string (bash 3.2 safe — no ${var,,})
_dod_to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Capitalize the first letter of a string (bash 3.2 safe — no ${var^})
_dod_capitalize() {
    local s="$1"
    [[ -z "$s" ]] && return 0
    local first rest
    first=$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')
    rest="${s:1}"
    printf '%s%s' "$first" "$rest"
}

# Convert kebab/snake-case to PascalCase: cost-share → CostShare
_dod_to_pascal() {
    local s="$1"
    [[ -z "$s" ]] && return 0
    local out=""
    local token rest
    while [[ -n "$s" ]]; do
        case "$s" in
            *[-_.]*)
                token="${s%%[-_.]*}"
                rest="${s#"$token"}"
                rest="${rest:1}"
                ;;
            *)
                token="$s"
                rest=""
                ;;
        esac
        out="${out}$(_dod_capitalize "$token")"
        s="$rest"
    done
    printf '%s' "$out"
}

# Compute lib_subpath for prefix_flat template.
# For files under scripts/, returns the dir segments under scripts/ joined with '-'.
# Examples:
#   scripts/lib/cost/share.sh        → lib-cost
#   scripts/lib/pipeline-intel.sh    → lib
#   scripts/sw-foo.sh                → (empty)
_dod_lib_subpath() {
    local rel_dir="$1"
    [[ -z "$rel_dir" || "$rel_dir" == "." ]] && return 0
    case "$rel_dir" in
        scripts)
            printf ''
            return 0
            ;;
        scripts/*)
            local under="${rel_dir#scripts/}"
            printf '%s' "$under" | tr '/' '-'
            return 0
            ;;
        *)
            # Not under scripts/: join entire rel_dir with '-'
            printf '%s' "$rel_dir" | tr '/' '-'
            return 0
            ;;
    esac
}

# Strip the longest source-root prefix from a relative dir; returns the remainder.
_dod_strip_source_root() {
    local rel_dir="$1"
    local roots_csv="$2"
    local best_rest="$rel_dir"
    local best_root=""
    local best_len=-1
    local IFS_OLD="$IFS"
    IFS=','
    local roots
    # shellcheck disable=SC2206
    roots=( $roots_csv )
    IFS="$IFS_OLD"
    local root r
    for root in "${roots[@]}"; do
        r="${root%/}"
        if [[ -z "$r" ]]; then
            if [[ 0 -gt $best_len ]]; then
                best_len=0
                best_root=""
                best_rest="$rel_dir"
            fi
            continue
        fi
        if [[ "$rel_dir" == "$r" ]]; then
            if [[ ${#r} -gt $best_len ]]; then
                best_len=${#r}
                best_root="$r"
                best_rest=""
            fi
        elif [[ "$rel_dir" == "$r"/* ]]; then
            if [[ ${#r} -gt $best_len ]]; then
                best_len=${#r}
                best_root="$r"
                best_rest="${rel_dir#"$r"/}"
            fi
        fi
    done
    # Output: root|rest (best root and rest after strip)
    printf '%s|%s' "$best_root" "$best_rest"
}

# Render a pattern with placeholders: {stem} {ext} {stem_pascal} {test_dir} {lib_subpath} {rel_dir}
_dod_render_pattern() {
    local pattern="$1" stem="$2" ext="$3" stem_pascal="$4" test_dir="$5" lib_subpath="$6" rel_dir="$7"
    local out="$pattern"
    out="${out//\{stem\}/$stem}"
    out="${out//\{ext\}/$ext}"
    out="${out//\{stem_pascal\}/$stem_pascal}"
    out="${out//\{test_dir\}/$test_dir}"
    out="${out//\{lib_subpath\}/$lib_subpath}"
    out="${out//\{rel_dir\}/$rel_dir}"
    # Collapse double dashes left by empty placeholders (e.g. empty lib_subpath)
    while [[ "$out" == *--* ]]; do
        out="${out//--/-}"
    done
    # Strip stray "-" adjacent to "/" introduced by empty placeholders
    out="${out//\/-/\/}"
    out="${out//-\//\/}"
    printf '%s' "$out"
}

# Return case variants for a test_dir name (lowercase original + Capitalized + UPPERCASE).
_dod_test_dir_variants() {
    local dir="$1"
    local lower cap
    lower=$(_dod_to_lower "$dir")
    cap=$(_dod_capitalize "$lower")
    printf '%s\n' "$lower"
    [[ "$cap" != "$lower" ]] && printf '%s\n' "$cap"
}

# Normalize a candidate path: collapse `//`, strip leading `./`
_dod_normalize_path() {
    local p="$1"
    while [[ "$p" == *//* ]]; do
        p="${p//\/\//\/}"
    done
    p="${p#./}"
    printf '%s' "$p"
}

# Emit candidate test paths (one per line) for a source file under the
# configured strategies / test_dir_names / test_filename_patterns.
_dod_candidate_paths() {
    local src_file="$1"
    local test_dirs_csv="$2"
    local patterns_csv="$3"
    local strategies_csv="$4"
    local roots_csv="$5"
    local prefix_template="$6"

    local base_name dir_name ext stem stem_pascal
    base_name=$(basename "$src_file")
    dir_name=$(dirname "$src_file")
    [[ "$dir_name" == "." ]] && dir_name=""
    ext="${base_name##*.}"
    stem="${base_name%.*}"
    stem_pascal=$(_dod_to_pascal "$stem")

    # Split source root
    local root_split src_root rel_dir
    root_split=$(_dod_strip_source_root "$dir_name" "$roots_csv")
    src_root="${root_split%%|*}"
    rel_dir="${root_split#*|}"

    local lib_subpath
    lib_subpath=$(_dod_lib_subpath "$dir_name")

    local IFS_OLD="$IFS"
    IFS=','
    local strategies test_dirs patterns
    # shellcheck disable=SC2206
    strategies=( $strategies_csv )
    # shellcheck disable=SC2206
    test_dirs=( $test_dirs_csv )
    # shellcheck disable=SC2206
    patterns=( $patterns_csv )
    IFS="$IFS_OLD"

    local strategy td td_variant pattern rendered candidate

    for strategy in "${strategies[@]}"; do
        case "$strategy" in
            colocated)
                # Same directory as the source file, optionally inside a test_dir subdir
                for pattern in "${patterns[@]}"; do
                    rendered=$(_dod_render_pattern "$pattern" "$stem" "$ext" "$stem_pascal" "" "$lib_subpath" "$rel_dir")
                    if [[ -n "$dir_name" ]]; then
                        candidate="$dir_name/$rendered"
                    else
                        candidate="$rendered"
                    fi
                    _dod_normalize_path "$candidate"; echo
                done
                for td in "${test_dirs[@]}"; do
                    while IFS= read -r td_variant; do
                        [[ -z "$td_variant" ]] && continue
                        for pattern in "${patterns[@]}"; do
                            rendered=$(_dod_render_pattern "$pattern" "$stem" "$ext" "$stem_pascal" "$td_variant" "$lib_subpath" "$rel_dir")
                            if [[ -n "$dir_name" ]]; then
                                candidate="$dir_name/$td_variant/$rendered"
                            else
                                candidate="$td_variant/$rendered"
                            fi
                            _dod_normalize_path "$candidate"; echo
                        done
                    done < <(_dod_test_dir_variants "$td")
                done
                ;;
            mirror)
                # Replace source_root with a test_dir while keeping rel_dir
                for td in "${test_dirs[@]}"; do
                    while IFS= read -r td_variant; do
                        [[ -z "$td_variant" ]] && continue
                        for pattern in "${patterns[@]}"; do
                            rendered=$(_dod_render_pattern "$pattern" "$stem" "$ext" "$stem_pascal" "$td_variant" "$lib_subpath" "$rel_dir")
                            if [[ -n "$rel_dir" ]]; then
                                candidate="$td_variant/$rel_dir/$rendered"
                            else
                                candidate="$td_variant/$rendered"
                            fi
                            _dod_normalize_path "$candidate"; echo
                        done
                    done < <(_dod_test_dir_variants "$td")
                done
                ;;
            flat)
                # test_dir at repo root, file directly under it
                for td in "${test_dirs[@]}"; do
                    while IFS= read -r td_variant; do
                        [[ -z "$td_variant" ]] && continue
                        for pattern in "${patterns[@]}"; do
                            rendered=$(_dod_render_pattern "$pattern" "$stem" "$ext" "$stem_pascal" "$td_variant" "$lib_subpath" "$rel_dir")
                            candidate="$td_variant/$rendered"
                            _dod_normalize_path "$candidate"; echo
                        done
                    done < <(_dod_test_dir_variants "$td")
                done
                ;;
            prefix_flat)
                if [[ -n "$prefix_template" ]]; then
                    rendered=$(_dod_render_pattern "$prefix_template" "$stem" "$ext" "$stem_pascal" "" "$lib_subpath" "$rel_dir")
                    _dod_normalize_path "$rendered"; echo
                fi
                ;;
        esac
    done
    # Suppress unused-var warnings under shellcheck
    : "$src_root"
}

# Locate a test file paired with $src_file. Echoes the first existing candidate
# and returns 0; returns 1 if no candidate exists on disk.
_dod_find_test_for() {
    local src_file="$1"
    local test_dirs_csv patterns_csv strategies_csv roots_csv prefix_template

    test_dirs_csv=$(_config_get_list "pipeline.dod.test_dir_names" "test,tests,__tests__,spec,specs")
    patterns_csv=$(_config_get_list "pipeline.dod.test_filename_patterns" \
        "{stem}.test.{ext},{stem}.spec.{ext},{stem}_test.{ext},{stem}-test.{ext},{stem}_spec.{ext},test_{stem}.{ext},{stem_pascal}Test.{ext},{stem_pascal}Tests.{ext}")
    strategies_csv=$(_config_get_list "pipeline.dod.search_strategies" "colocated,mirror,flat,prefix_flat")
    roots_csv=$(_config_get_list "pipeline.dod.source_roots" "src/,lib/,app/,scripts/,pkg/,")
    prefix_template=$(_config_get "pipeline.dod.prefix_flat_template" "scripts/sw-{lib_subpath}-{stem}-test.sh")

    local candidate
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(_dod_candidate_paths "$src_file" "$test_dirs_csv" "$patterns_csv" "$strategies_csv" "$roots_csv" "$prefix_template")
    return 1
}

pipeline_verify_dod() {
    local artifacts_dir="${1:-$ARTIFACTS_DIR}"
    local checks_total=0 checks_passed=0
    local results=""

    # 1. Test coverage: verify changed source files have test counterparts
    local changed_files
    changed_files=$(git diff --name-only "${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)
    local missing_tests=""
    local files_checked=0

    if [[ -n "$changed_files" ]]; then
        while IFS= read -r src_file; do
            [[ -z "$src_file" ]] && continue
            # Only check source code files
            case "$src_file" in
                *.ts|*.js|*.tsx|*.jsx|*.py|*.go|*.rs|*.sh)
                    # Skip test files themselves and config files
                    case "$src_file" in
                        *test*|*spec*|*__tests__*|*.config.*|*.d.ts) continue ;;
                    esac
                    files_checked=$((files_checked + 1))
                    checks_total=$((checks_total + 1))
                    # Config-driven structural search — see _dod_find_test_for above
                    if _dod_find_test_for "$src_file" >/dev/null 2>&1; then
                        checks_passed=$((checks_passed + 1))
                    else
                        missing_tests="${missing_tests}${src_file}\n"
                    fi
                    ;;
            esac
        done <<EOF
$changed_files
EOF
    fi

    # 2. Test-added verification: if significant logic added, ensure tests were also added
    local logic_lines=0 test_lines=0
    if [[ -n "$changed_files" ]]; then
        local full_diff
        full_diff=$(git diff "${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)
        if [[ -n "$full_diff" ]]; then
            # Count added lines matching source patterns (rough heuristic)
            logic_lines=$(echo "$full_diff" | grep -cE '^\+.*(function |class |if |for |while |return |export )' 2>/dev/null || true)
            logic_lines="${logic_lines:-0}"
            # Count added lines in test files
            test_lines=$(echo "$full_diff" | grep -cE '^\+.*(it\(|test\(|describe\(|expect\(|assert|def test_|func Test)' 2>/dev/null || true)
            test_lines="${test_lines:-0}"
        fi
    fi
    checks_total=$((checks_total + 1))
    local test_ratio_passed=true
    if [[ "$logic_lines" -gt 20 && "$test_lines" -eq 0 ]]; then
        test_ratio_passed=false
        warn "DoD verification: ${logic_lines} logic lines added but no test lines detected"
    else
        checks_passed=$((checks_passed + 1))
    fi

    # 3. Behavioral verification: check DoD audit artifacts for evidence
    local dod_audit_file="$artifacts_dir/dod-audit.md"
    local dod_verified=0 dod_total_items=0
    if [[ -f "$dod_audit_file" ]]; then
        # Count items marked as passing
        dod_total_items=$(grep -cE '^\s*-\s*\[x\]' "$dod_audit_file" 2>/dev/null || true)
        dod_total_items="${dod_total_items:-0}"
        local dod_failing
        dod_failing=$(grep -cE '^\s*-\s*\[\s\]' "$dod_audit_file" 2>/dev/null || true)
        dod_failing="${dod_failing:-0}"
        dod_verified=$dod_total_items
        checks_total=$((checks_total + dod_total_items + ${dod_failing:-0}))
        checks_passed=$((checks_passed + dod_total_items))
    fi

    # Compute pass rate
    local pass_rate=100
    if [[ "$checks_total" -gt 0 ]]; then
        pass_rate=$(( (checks_passed * 100) / checks_total ))
    fi

    # Write results
    local tmp_result
    tmp_result=$(mktemp)
    jq -n \
        --argjson checks_total "$checks_total" \
        --argjson checks_passed "$checks_passed" \
        --argjson pass_rate "$pass_rate" \
        --argjson files_checked "$files_checked" \
        --arg missing_tests "$(echo -e "$missing_tests" | head -20)" \
        --argjson logic_lines "$logic_lines" \
        --argjson test_lines "$test_lines" \
        --argjson test_ratio_passed "$test_ratio_passed" \
        --argjson dod_verified "$dod_verified" \
        '{
            checks_total: $checks_total,
            checks_passed: $checks_passed,
            pass_rate: $pass_rate,
            files_checked: $files_checked,
            missing_tests: ($missing_tests | split("\n") | map(select(. != ""))),
            logic_lines: $logic_lines,
            test_lines: $test_lines,
            test_ratio_passed: $test_ratio_passed,
            dod_verified: $dod_verified
        }' > "$tmp_result" 2>/dev/null
    mv "$tmp_result" "$artifacts_dir/dod-verification.json" || rm -f "$tmp_result"

    emit_event "pipeline.dod_verification" \
        "issue=${ISSUE_NUMBER:-0}" \
        "checks_total=$checks_total" \
        "checks_passed=$checks_passed" \
        "pass_rate=$pass_rate"

    # Fail if pass rate < 70%
    if [[ "$pass_rate" -lt 70 ]]; then
        warn "DoD verification: ${pass_rate}% pass rate (${checks_passed}/${checks_total} checks)"
        return 1
    fi

    success "DoD verification: ${pass_rate}% pass rate (${checks_passed}/${checks_total} checks)"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# @audit-suppress directive parser.
#
# Grammar:
#   @audit-suppress <id> -- <reason>
#   - <id>:    [A-Za-z0-9_]{8,}  (convention: audit_<unix-ms-timestamp>)
#   - <reason>: free text to EOL, surfaced in suppression sidecar.
#
# Scope: matches when the directive appears on the same line as a flagged
# pattern OR up to 3 lines above. This is intentionally narrow — it prevents
# whole-file suppression-by-accident and forces the directive to sit next to
# what it's justifying.
#
# Echoes "<id>|<reason>" on hit (one line). Empty on miss.
# ──────────────────────────────────────────────────────────────────────────────
_audit_suppress_check() {
    local _file="$1"
    local _line="$2"
    [[ -z "$_file" || ! -f "$_file" || -z "$_line" ]] && return 0
    local _start=$(( _line > 3 ? _line - 3 : 1 ))
    local _excerpt
    _excerpt=$(sed -n "${_start},${_line}p" "$_file" 2>/dev/null || true)
    [[ -z "$_excerpt" ]] && return 0
    local _hit
    _hit=$(echo "$_excerpt" | grep -oE '@audit-suppress[[:space:]]+[A-Za-z0-9_]{8,}[[:space:]]+--[[:space:]]+.+$' | tail -1 || true)
    [[ -z "$_hit" ]] && return 0
    local _id _reason
    _id=$(echo "$_hit" | sed -E 's/^@audit-suppress[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+--[[:space:]]+.*$/\1/')
    _reason=$(echo "$_hit" | sed -E 's/^@audit-suppress[[:space:]]+[A-Za-z0-9_]+[[:space:]]+--[[:space:]]+(.*)$/\1/')
    echo "${_id}|${_reason}"
}

# Append a suppression record to the sidecar audit log. Best-effort (not deduplicated).
_audit_suppress_record() {
    local _file="$1"
    local _line="$2"
    local _pattern="$3"
    local _id="$4"
    local _reason="$5"
    local _sup_dir="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
    local _sup_file="${_sup_dir}/compound-quality-suppressions.json"
    mkdir -p "$_sup_dir" 2>/dev/null || true
    local _existing
    if [[ -f "$_sup_file" ]]; then
        _existing=$(cat "$_sup_file" 2>/dev/null || echo "[]")
    else
        _existing="[]"
    fi
    # Validate existing is JSON array; reset if corrupt.
    echo "$_existing" | jq -e 'type == "array"' >/dev/null 2>&1 || _existing="[]"
    local _tmp
    _tmp=$(mktemp "${TMPDIR:-/tmp}/audit-suppress.XXXXXX")
    echo "$_existing" | jq \
        --arg f "$_file" \
        --arg l "$_line" \
        --arg p "$_pattern" \
        --arg id "$_id" \
        --arg r "$_reason" \
        '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"suppressed_by":{"id":$id,"reason":$r}}]' \
        > "$_tmp" 2>/dev/null && mv "$_tmp" "$_sup_file" || rm -f "$_tmp"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Source Code Security Scan
# Grep-based vulnerability pattern matching on changed files.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_security_source_scan() {
    local base_branch="${1:-${BASE_BRANCH:-main}}"
    local findings="[]"
    local finding_count=0

    local changed_files
    changed_files=$(git diff --name-only "${base_branch}...HEAD" -- 2>/dev/null || true)
    [[ -z "$changed_files" ]] && { echo "[]"; return 0; }

    local tmp_findings
    tmp_findings=$(mktemp)
    echo "[]" > "$tmp_findings"

    while IFS= read -r file; do
        [[ -z "$file" || ! -f "$file" ]] && continue
        # Bug #395 Fix 3: exclude scanner infrastructure and test fixtures.
        # pipeline-intelligence.sh grep patterns match themselves when scanned;
        # test files contain intentional vulnerable heredocs as fixtures.
        # Use basename-only match to avoid false positives from temp dir names.
        local _basename
        _basename="${file##*/}"
        if [[ "$_basename" == "pipeline-intelligence.sh" || "$_basename" == *-test.sh || \
              "$_basename" == *fixture* ]]; then
            continue
        fi
        # Only scan code files
        case "$file" in
            *.ts|*.js|*.tsx|*.jsx|*.py|*.go|*.rs|*.java|*.rb|*.php|*.sh) ;;
            *) continue ;;
        esac

        # SQL injection patterns
        local sql_matches
        sql_matches=$(grep -nE '(query|execute|sql)\s*\(?\s*[`"'"'"']\s*.*\$\{|\.query\s*\(\s*[`"'"'"'].*\+' "$file" 2>/dev/null || true)
        if [[ -n "$sql_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "sql_injection" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential SQL injection via string concatenation"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<SQLEOF
$sql_matches
SQLEOF
        fi

        # XSS patterns
        local xss_matches
        xss_matches=$(grep -nE 'innerHTML\s*=|document\.write\s*\(|dangerouslySetInnerHTML' "$file" 2>/dev/null || true)
        if [[ -n "$xss_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "xss" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","confidence":"medium","description":"Potential XSS via unsafe DOM manipulation"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<XSSEOF
$xss_matches
XSSEOF
        fi

        # Command injection patterns
        local cmd_matches
        cmd_matches=$(grep -nE 'eval\s*\(|child_process|os\.system\s*\(|subprocess\.(call|run|Popen)\s*\(' "$file" 2>/dev/null || true)
        if [[ -n "$cmd_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                # @audit-suppress directive check — if the matched line carries
                # (or is preceded within 3 lines by) a structured suppression
                # directive, record it in the audit sidecar and skip the
                # blocking finding. This turns the previously-implicit
                # "trust the SAST confidence tier" defense into an explicit
                # contract that survives refactors and is enforceable by tests.
                local _suppress_hit
                _suppress_hit=$(_audit_suppress_check "$file" "$line_num")
                if [[ -n "$_suppress_hit" ]]; then
                    local _sup_id="${_suppress_hit%%|*}"
                    local _sup_reason="${_suppress_hit#*|}"
                    _audit_suppress_record "$file" "$line_num" "command_injection" "$_sup_id" "$_sup_reason"
                    continue
                fi
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                # Determine confidence: low for pure import/require declarations (nothing
                # executable), high when injection markers are present, medium otherwise.
                # Two-step check: (1) line starts with an import form, AND (2) has no
                # inline execution markers (semicolons, shell=True, direct calls).
                # This correctly downgrades `import { execFileSync } from 'child_process'`
                # (ES6 named import — no execution) while keeping
                # `import subprocess; subprocess.run(x, shell=True)` at high.
                local confidence="medium"
                local match_text="${match#*:}"
                local _is_import_decl=false
                if echo "$match_text" | grep -qE \
                    "^[[:space:]]*(import[[:space:]({\"\']|from[[:space:]]+[A-Za-z_]|const[[:space:]]+|var[[:space:]]+|let[[:space:]]+)"; then
                    if ! echo "$match_text" | grep -qE \
                        "[;]|\.(exec|run|spawn|system|call|Popen)[[:space:]]*\(|eval[[:space:]]*\(|shell[[:space:]]*=[[:space:]]*[Tt]rue"; then
                        _is_import_decl=true
                    fi
                fi
                if [[ "$_is_import_decl" == "true" ]]; then
                    confidence="low"
                elif echo "$match_text" | grep -qE '\$\{|`|shell[[:space:]]*=[[:space:]]*[Tt]rue|exec[[:space:]]*\('; then
                    confidence="high"
                fi
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "command_injection" --arg c "$confidence" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","confidence":$c,"description":"Potential command injection via unsafe execution"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<CMDEOF
$cmd_matches
CMDEOF
        fi

        # Hardcoded secrets patterns
        local secret_matches
        secret_matches=$(grep -nEi '(password|api_key|secret|token)\s*=\s*['"'"'"][A-Za-z0-9+/=]{8,}['"'"'"]' "$file" 2>/dev/null || true)
        if [[ -n "$secret_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "hardcoded_secret" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","confidence":"medium","description":"Potential hardcoded secret or credential"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<SECEOF
$secret_matches
SECEOF
        fi

        # Insecure crypto patterns
        local crypto_matches
        crypto_matches=$(grep -nE '(md5|MD5|sha1|SHA1)\s*\(' "$file" 2>/dev/null || true)
        if [[ -n "$crypto_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "insecure_crypto" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"major","description":"Weak cryptographic function (consider SHA-256+)"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<CRYEOF
$crypto_matches
CRYEOF
        fi
    done <<FILESEOF
$changed_files
FILESEOF

    # Write to artifacts and output
    findings=$(cat "$tmp_findings")
    rm -f "$tmp_findings"

    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        local tmp_scan
        tmp_scan=$(mktemp)
        echo "$findings" > "$tmp_scan"
        mv "$tmp_scan" "$ARTIFACTS_DIR/security-source-scan.json" || rm -f "$tmp_scan"
        # Bug #395 Fix 2: generate security-source-scan.log so _extract_blocking_items
        # and _write_quality_feedback can surface findings in the rebuild prompt.
        # Uses a separate file from security-audit.log (written by quality_check_security
        # for npm audit) to avoid collision. Format: SEVERITY: file:line — message.
        # "major" is normalized to "HIGH" so grep -iE 'critical|high' catches all severity 2+.
        jq -r '.[] | (if .severity == "major" then "HIGH" else (.severity | ascii_upcase) end) as $sev |
            "\($sev): \(.file // "unknown"):\(.line // "?") \u2014 \(.message // .description // "finding") [original: \(.severity)]"' \
            "$ARTIFACTS_DIR/security-source-scan.json" \
            > "$ARTIFACTS_DIR/security-source-scan.log" 2>/dev/null || true
    fi

    emit_event "pipeline.security_source_scan" \
        "issue=${ISSUE_NUMBER:-0}" \
        "findings=$finding_count"

    echo "$finding_count"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Quality Score Recording
# Writes quality scores to JSONL for learning.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_record_quality_score() {
    local quality_score="${1:-0}"
    local critical="${2:-0}"
    local major="${3:-0}"
    local minor="${4:-0}"
    local dod_pass_rate="${5:-0}"
    local audits_run="${6:-}"

    local scores_dir="${HOME}/.shipwright/optimization"
    local scores_file="${scores_dir}/quality-scores.jsonl"
    mkdir -p "$scores_dir"

    local repo_name
    repo_name=$(basename "${PROJECT_ROOT:-.}") || true

    local tmp_score
    tmp_score=$(mktemp)
    jq -n \
        --arg repo "$repo_name" \
        --arg issue "${ISSUE_NUMBER:-0}" \
        --arg ts "$(now_iso)" \
        --argjson score "$quality_score" \
        --argjson critical "$critical" \
        --argjson major "$major" \
        --argjson minor "$minor" \
        --argjson dod "$dod_pass_rate" \
        --arg template "${PIPELINE_NAME:-standard}" \
        --arg audits "$audits_run" \
        '{
            repo: $repo,
            issue: ($issue | tonumber),
            timestamp: $ts,
            quality_score: $score,
            findings: {critical: $critical, major: $major, minor: $minor},
            dod_pass_rate: $dod,
            template: $template,
            audits_run: ($audits | split(",") | map(select(. != "")))
        }' > "$tmp_score" 2>/dev/null

    cat "$tmp_score" >> "$scores_file"
    rm -f "$tmp_score"

    # Rotate quality scores file to prevent unbounded growth
    type rotate_jsonl >/dev/null 2>&1 && rotate_jsonl "$scores_file" 5000

    emit_event "pipeline.quality_score_recorded" \
        "issue=${ISSUE_NUMBER:-0}" \
        "quality_score=$quality_score" \
        "critical=$critical" \
        "major=$major" \
        "minor=$minor"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Mid-Pipeline Complexity Re-evaluation
# After build+test completes, compares actual effort to initial estimate.
# Updates skip recommendations and model routing for remaining stages.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_reassess_complexity() {
    local initial_complexity="${INTELLIGENCE_COMPLEXITY:-5}"
    local reassessment_file="$ARTIFACTS_DIR/reassessment.json"

    # ── Gather actual metrics ──
    local files_changed=0 lines_changed=0 first_try_pass=false self_heal_cycles=0

    files_changed=$(git diff "${BASE_BRANCH:-main}...HEAD" --name-only 2>/dev/null | wc -l | tr -d ' ') || files_changed=0
    files_changed="${files_changed:-0}"

    # Count lines changed (insertions + deletions) without pipefail issues
    lines_changed=0
    local _diff_stat
    _diff_stat=$(git diff "${BASE_BRANCH:-main}...HEAD" --stat 2>/dev/null | tail -1) || true
    if [[ -n "${_diff_stat:-}" ]]; then
        local _ins _del
        _ins=$(echo "$_diff_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+') || true
        _del=$(echo "$_diff_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+') || true
        lines_changed=$(( ${_ins:-0} + ${_del:-0} ))
    fi

    self_heal_cycles="${SELF_HEAL_COUNT:-0}"
    if [[ "$self_heal_cycles" -eq 0 ]]; then
        first_try_pass=true
    fi

    # ── Compare to expectations ──
    local actual_complexity="$initial_complexity"
    local assessment="as_expected"
    local skip_stages="[]"

    # Simpler than expected: small diff, tests passed first try
    if [[ "$lines_changed" -lt 50 && "$first_try_pass" == "true" && "$files_changed" -lt 5 ]]; then
        actual_complexity=$((initial_complexity > 2 ? initial_complexity - 2 : 1))
        assessment="simpler_than_expected"
        # Mark compound_quality as skippable, simplify review
        skip_stages='["compound_quality"]'
    # Much simpler
    elif [[ "$lines_changed" -lt 20 && "$first_try_pass" == "true" && "$files_changed" -lt 3 ]]; then
        actual_complexity=1
        assessment="much_simpler"
        skip_stages='["compound_quality","review"]'
    # Harder than expected: large diff, multiple self-heal cycles
    elif [[ "$lines_changed" -gt 500 || "$self_heal_cycles" -gt 2 ]]; then
        actual_complexity=$((initial_complexity < 9 ? initial_complexity + 2 : 10))
        assessment="harder_than_expected"
        # Ensure compound_quality runs, possibly upgrade model
        skip_stages='[]'
    # Much harder
    elif [[ "$lines_changed" -gt 1000 || "$self_heal_cycles" -gt 4 ]]; then
        actual_complexity=10
        assessment="much_harder"
        skip_stages='[]'
    fi

    # ── Write reassessment ──
    local tmp_reassess
    tmp_reassess="$(mktemp)"
    jq -n \
        --argjson initial "$initial_complexity" \
        --argjson actual "$actual_complexity" \
        --arg assessment "$assessment" \
        --argjson files_changed "$files_changed" \
        --argjson lines_changed "$lines_changed" \
        --argjson self_heal_cycles "$self_heal_cycles" \
        --argjson first_try "$first_try_pass" \
        --argjson skip_stages "$skip_stages" \
        '{
            initial_complexity: $initial,
            actual_complexity: $actual,
            assessment: $assessment,
            files_changed: $files_changed,
            lines_changed: $lines_changed,
            self_heal_cycles: $self_heal_cycles,
            first_try_pass: $first_try,
            skip_stages: $skip_stages
        }' > "$tmp_reassess" 2>/dev/null && mv "$tmp_reassess" "$reassessment_file" || rm -f "$tmp_reassess"

    # Update global complexity for downstream stages
    PIPELINE_ADAPTIVE_COMPLEXITY="$actual_complexity"

    emit_event "intelligence.reassessment" \
        "issue=${ISSUE_NUMBER:-0}" \
        "initial=$initial_complexity" \
        "actual=$actual_complexity" \
        "assessment=$assessment" \
        "files=$files_changed" \
        "lines=$lines_changed" \
        "self_heals=$self_heal_cycles"

    # ── Store for learning ──
    local learning_file="${HOME}/.shipwright/optimization/complexity-actuals.jsonl"
    mkdir -p "${HOME}/.shipwright/optimization" 2>/dev/null || true
    echo "{\"issue\":\"${ISSUE_NUMBER:-0}\",\"initial\":$initial_complexity,\"actual\":$actual_complexity,\"files\":$files_changed,\"lines\":$lines_changed,\"ts\":\"$(now_iso)\"}" \
        >> "$learning_file" 2>/dev/null || true

    echo "$assessment"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Backtracking Support
# When compound_quality detects architecture-level problems, backtracks to
# the design stage instead of just feeding findings to the build loop.
# Limited to 1 backtrack per pipeline run to prevent infinite loops.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_backtrack_to_stage() {
    local target_stage="$1"
    local reason="${2:-architecture_violation}"

    # Prevent infinite backtracking
    if [[ "$PIPELINE_BACKTRACK_COUNT" -ge "$PIPELINE_MAX_BACKTRACKS" ]]; then
        warn "Max backtracks ($PIPELINE_MAX_BACKTRACKS) reached — cannot backtrack to $target_stage"
        emit_event "intelligence.backtrack_blocked" \
            "issue=${ISSUE_NUMBER:-0}" \
            "target=$target_stage" \
            "reason=max_backtracks_reached" \
            "count=$PIPELINE_BACKTRACK_COUNT"
        return 1
    fi

    PIPELINE_BACKTRACK_COUNT=$((PIPELINE_BACKTRACK_COUNT + 1))

    info "Backtracking to ${BOLD}${target_stage}${RESET} stage (reason: ${reason})"

    emit_event "intelligence.backtrack" \
        "issue=${ISSUE_NUMBER:-0}" \
        "target=$target_stage" \
        "reason=$reason"

    # Gather architecture context from findings
    local arch_context=""
    if [[ -f "$ARTIFACTS_DIR/compound-architecture-validation.json" ]]; then
        arch_context=$(jq -r '[.[] | select(.severity == "critical" or .severity == "high") | .message // .description // ""] | join("\n")' \
            "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || true)
    fi
    if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
        local arch_lines
        arch_lines=$(grep -iE 'architect|layer.*violation|circular.*depend|coupling|design.*flaw' \
            "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
        if [[ -n "$arch_lines" ]]; then
            arch_context="${arch_context}
${arch_lines}"
        fi
    fi

    # Reset stages from target onward
    set_stage_status "$target_stage" "pending"
    set_stage_status "build" "pending"
    set_stage_status "test" "pending"

    # Augment goal with architecture context for re-run
    local original_goal="$GOAL"
    trap '{ GOAL="$original_goal"; trap - RETURN; }' RETURN
    if [[ -n "$arch_context" ]]; then
        GOAL="$GOAL

IMPORTANT — Architecture violations were detected during quality review. Redesign to fix:
$arch_context

Update the design to address these violations, then rebuild."
    fi

    # Re-run design stage
    info "Re-running ${BOLD}${target_stage}${RESET} with architecture context..."
    if "stage_${target_stage}" 2>/dev/null; then
        mark_stage_complete "$target_stage"
        success "Backtrack: ${target_stage} re-run complete"
    else
        GOAL="$original_goal"
        error "Backtrack: ${target_stage} re-run failed"
        return 1
    fi

    # Re-run build+test
    info "Re-running build→test after backtracked ${target_stage}..."
    if self_healing_build_test; then
        success "Backtrack: build→test passed after ${target_stage} redesign"
        GOAL="$original_goal"
        return 0
    else
        GOAL="$original_goal"
        error "Backtrack: build→test failed after ${target_stage} redesign"
        return 1
    fi
}

# _dedup_add_item <line> <source-label> <fps-file> <items-file>
# Adds <line> to <items-file> tagged with [source: <source-label>] unless its
# fingerprint (file:line when present, first 80 chars otherwise) is already in
# <fps-file>. Uses exact-line matching (-xF) to prevent foo:10 shadowing foo:100.
_dedup_add_item() {
    local line="$1" source="$2" fps_file="$3" items_file="$4"
    [[ -z "$line" ]] && return 0
    local fp
    fp=$(printf '%s' "$line" | grep -oE '[a-zA-Z0-9_./-]+:[0-9]+' | head -1 || true)
    [[ -z "$fp" ]] && fp=$(printf '%s' "$line" | cut -c1-80)
    if ! grep -qxF "$fp" "$fps_file" 2>/dev/null; then
        printf '%s\n' "$fp" >> "$fps_file"
        printf '%s [source: %s]\n' "$line" "$source" >> "$items_file"
    fi
}

# _extract_blocking_items
# Collects critical/high-severity findings from available artifact sources into a
# numbered list. Sources: adversarial-review.json (with .md fallback),
# security-audit.log, negative-review.md [Critical] lines, dod-audit.md
# unchecked items, classified-findings.json needs_backtrack flag, and
# compound-audit-findings.json critical/high findings.
# Deduplicates by file:line fingerprint (best-effort, exact-line match).
# Outputs to stdout; empty output means no blocking items found.
#
# Expected finding format for .md artifacts (for reliable parsing):
#   **[Critical]** file:line — description
#   **[High]** file:line — description
#   **[Bug]** file:line — description
# JSON artifacts (adversarial-review.json) are preferred when available.
_extract_blocking_items() {
    local tmp_items tmp_fps
    tmp_items="$(mktemp "${TMPDIR:-/tmp}/sw-blocking.XXXXXX")"
    tmp_fps="$(mktemp "${TMPDIR:-/tmp}/sw-blocking-fps.XXXXXX")"
    # Ensure cleanup on any exit path, including set -e failures and signals.
    trap 'rm -f "$tmp_items" "$tmp_fps"' RETURN

    # ── 1. adversarial-review.json (intelligence path) ──
    if [[ -f "$ARTIFACTS_DIR/adversarial-review.json" ]] && pipeline_artifact_is_current "$ARTIFACTS_DIR/adversarial-review.json"; then
        local adv_lines
        adv_lines=$(jq -r '.[] | select(.severity == "critical" or .severity == "high") | "\(.location // "") — \(.description // .concern // "")"' \
            "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || true)
        if [[ -n "$adv_lines" ]]; then
            while IFS= read -r line; do
                _dedup_add_item "$line" "adversarial" "$tmp_fps" "$tmp_items"
            done <<< "$adv_lines"
        fi
    elif [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]] && pipeline_artifact_is_current "$ARTIFACTS_DIR/adversarial-review.md"; then
        # Fallback: parse .md for **[Critical]** / **[High]** / **[Bug]** lines (non-JSON path)
        while IFS= read -r line; do
            _dedup_add_item "$line" "adversarial" "$tmp_fps" "$tmp_items"
        done < <(grep -iE '\*\*\[?(Critical|High|Bug)\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
    fi

    # ── 2. security-audit.log / security-source-scan.log — critical/high lines ──
    # Parsed separately from adversarial-review so security findings are never
    # demoted even when the adversarial JSON path is active.
    # security-audit.log: written by quality_check_security (npm audit).
    # security-source-scan.log: written by pipeline_security_source_scan (source grep).
    if [[ -f "$ARTIFACTS_DIR/security-audit.log" ]] && pipeline_artifact_is_current "$ARTIFACTS_DIR/security-audit.log"; then
        while IFS= read -r line; do
            _dedup_add_item "$line" "security" "$tmp_fps" "$tmp_items"
        done < <(grep -iE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null || true)
    fi
    if [[ -f "$ARTIFACTS_DIR/security-source-scan.log" ]] && pipeline_artifact_is_current "$ARTIFACTS_DIR/security-source-scan.log"; then
        # Prefer the JSON artifact (confidence-tagged) when available; fall back to
        # plain-text log which lacks confidence and is treated as medium confidence.
        if [[ -f "$ARTIFACTS_DIR/security-source-scan.json" ]] && \
           jq -e . "$ARTIFACTS_DIR/security-source-scan.json" >/dev/null 2>&1; then
            # Route by confidence: high/medium → blocking, low → advisory only.
            # (.confidence == null): conservative fallback for findings written before
            # confidence tagging was introduced — treat as medium (blocking). Intentional.
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                _dedup_add_item "$line" "security-source" "$tmp_fps" "$tmp_items"
            done < <(jq -r '.[] | select(.confidence == "high" or .confidence == "medium" or (.confidence == null)) | select(.severity == "critical" or .severity == "high" or .severity == "major") | "\(.file // "unknown"):\(.line // "?") \u2014 \(.description // "finding")"' \
                "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null | grep -v '^null' || true)
            # Low-confidence findings → advisory sidecar, NOT blocking
            jq -r '.[] | select(.confidence == "low") | "ADVISORY: \(.file // "unknown"):\(.line // "?") \u2014 \(.description // "finding") [low confidence \u2014 verify before acting]"' \
                "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null \
                >> "${ARTIFACTS_DIR}/security-advisories.log" 2>/dev/null || true
        else
            # JSON unavailable or invalid — inject a synthetic BLOCKING item so the
            # security gate stays closed. A scanner crash or build race must never
            # cause the gate to disappear silently (fail-OPEN). Operators will see
            # this finding and must re-run the pipeline to generate a valid scan.
            local _synthetic_fp="SCANNER_ARTIFACT_MISSING:security-source-scan.json"
            if ! grep -qxF "$_synthetic_fp" "$tmp_fps" 2>/dev/null; then
                printf '%s\n' "$_synthetic_fp" >> "$tmp_fps"
                printf '%s [source: %s]\n' \
                    "SCANNER_ARTIFACT_MISSING: security-source-scan.json unavailable — re-run pipeline to generate fresh scan results" \
                    "security-source (synthetic)" >> "$tmp_items"
            fi
            # Also warn and write to advisory sidecar for diagnostics.
            warn "security-source-scan: JSON artifact missing/invalid — injecting synthetic BLOCKING item (gate closed)"
            if [[ -f "$ARTIFACTS_DIR/security-source-scan.log" ]]; then
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    echo "ADVISORY (no-json-fallback): $line" \
                        >> "${ARTIFACTS_DIR}/security-advisories.log" 2>/dev/null || true
                done < <(grep -iE 'critical|high' "$ARTIFACTS_DIR/security-source-scan.log" 2>/dev/null || true)
            fi
        fi
    fi

    # ── 3. negative-review.md — [Critical] lines only ──
    # Findings were generated against a previous code snapshot; the inline label
    # tells the model to verify against current source before acting.
    if [[ -f "$ARTIFACTS_DIR/negative-review.md" ]] && pipeline_artifact_is_current "$ARTIFACTS_DIR/negative-review.md"; then
        while IFS= read -r line; do
            _dedup_add_item "$line" "negative — verify against current code" "$tmp_fps" "$tmp_items"
        done < <(grep -E '\[Critical\]' "$ARTIFACTS_DIR/negative-review.md" 2>/dev/null || true)
    fi

    # ── 4. dod-audit.md — unchecked items ──
    if [[ -f "$ARTIFACTS_DIR/dod-audit.md" ]] && pipeline_artifact_is_current "$ARTIFACTS_DIR/dod-audit.md"; then
        while IFS= read -r line; do
            _dedup_add_item "$line" "dod" "$tmp_fps" "$tmp_items"
        done < <(grep -E '(❌|\[ \])' "$ARTIFACTS_DIR/dod-audit.md" 2>/dev/null || true)
    fi

    # ── 5. classified-findings.json — backtrack flag as header note ──
    local backtrack_note=""
    if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]] && pipeline_artifact_is_current "$ARTIFACTS_DIR/classified-findings.json"; then
        local needs_backtrack
        needs_backtrack=$(jq -r '.needs_backtrack // false' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "false")
        if [[ "$needs_backtrack" == "true" ]]; then
            backtrack_note="> ⚠ Backtrack flagged by classifier — structural issues may require revisiting design"
        fi
    fi

    # ── 6. compound-audit-findings.json — critical/high cascade findings ──
    # Cascade audit produces structured findings (file, line, description,
    # suggestion) that count toward gate severity but were previously not
    # injected into the rebuild GOAL. Surface them here so the build agent
    # gets the most actionable feedback the pipeline produces.
    # gsub flattens embedded newlines so one finding == one line == one
    # dedup entry; without it, multi-line .description/.suggestion would
    # split into orphaned continuation lines that lose their file:line fp.
    if [[ -f "$ARTIFACTS_DIR/compound-audit-findings.json" ]] && \
       pipeline_artifact_is_current "$ARTIFACTS_DIR/compound-audit-findings.json" && \
       jq -e . "$ARTIFACTS_DIR/compound-audit-findings.json" >/dev/null 2>&1; then
        local cascade_lines
        cascade_lines=$(jq -r '
          def flat: gsub("[\r\n]+"; " ");
          .[]
          | select(.severity == "critical" or .severity == "high")
          | "\(.file // "unknown"):\(.line // "?") \u2014 \((.description // "finding") | flat)"
            + (if (.suggestion // "") != "" then " (suggestion: \((.suggestion) | flat))" else "" end)
        ' "$ARTIFACTS_DIR/compound-audit-findings.json" 2>/dev/null || true)
        if [[ -n "$cascade_lines" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                _dedup_add_item "$line" "compound-audit" "$tmp_fps" "$tmp_items"
            done <<< "$cascade_lines"
        fi
    fi

    # ── Output: backtrack note (if any), then numbered items ──
    if [[ -n "$backtrack_note" ]]; then
        printf '%s\n\n' "$backtrack_note"
    fi
    if [[ -s "$tmp_items" ]]; then
        local n=0
        while IFS= read -r item; do
            n=$((n + 1))
            printf '%d. %s\n' "$n" "$item"
        done < "$tmp_items"
    fi
    # tmp_items and tmp_fps cleaned up by the RETURN trap above.
}

# _compound_should_plateau <current_count> <prev_count> <cycle>
# Pure predicate: returns "plateau" when issue-count stagnation is detected,
# "skip" otherwise. Extracted so plateau logic is unit-testable independently
# of the compound_quality loop.
# Plateau conditions (all must be true):
#   - prev_count >= 0  (at least one real prior cycle, not the sentinel -1)
#   - current_count == prev_count  (no change)
#   - cycle > 1        (never fire on the very first cycle)
_compound_should_plateau() {
    local current_count="$1" prev_count="$2" cycle="$3"
    if [[ "$prev_count" -ge 0 \
       && "$current_count" -eq "$prev_count" \
       && "$cycle" -gt 1 ]]; then
        echo "plateau"
    else
        echo "skip"
    fi
}

# _write_quality_feedback <route> <output_file> [blocking_items]
# Collects all quality findings into a single markdown file. Extracted from
# compound_rebuild_with_feedback() to allow direct testing without mocking
# the full build loop.
# Optional third argument: pre-computed blocking items string from
# _extract_blocking_items(). When provided, avoids a redundant call. When
# omitted (e.g. direct test invocation), blocking items are computed here.
# Use ${3+x} idiom to distinguish "not passed" from "passed but empty".
_write_quality_feedback() {
    local route="${1:-correctness}"
    local feedback_file="${2:-$ARTIFACTS_DIR/quality-feedback.md}"
    local blocking_items
    if [[ "${3+x}" == "x" ]]; then
        blocking_items="$3"
    else
        blocking_items=$(_extract_blocking_items)
    fi

    {
        echo "# Quality Feedback — Issues to Fix"
        echo ""

        # ── Blocking Issues (first-class, top of prompt) ──
        if [[ -n "$blocking_items" ]]; then
            echo "## Blocking Issues (must fix before merge)"
            echo ""
            printf '%s\n' "$blocking_items"
            echo ""
        fi

        # ── Review Findings (supporting context) ──
        # Always emitted at ## level so heading structure is consistent for
        # downstream consumers regardless of whether blocking items are present.
        echo "## Review Findings"
        echo ""

        # Security findings: split by confidence when JSON artifact is available.
        if [[ -f "$ARTIFACTS_DIR/security-source-scan.json" ]] && \
           jq -e 'length > 0' "$ARTIFACTS_DIR/security-source-scan.json" >/dev/null 2>&1; then
            # Blocking: high confidence + medium (medium treated as blocking — conservative)
            local _sec_blocking _sec_advisory
            _sec_blocking=$(jq -r \
                '.[] | select(.confidence == "high" or .confidence == "medium") | "  - \(.file // "unknown"):\(.line // "?") — \(.description // "finding") [confidence: \(.confidence)]"' \
                "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || true)
            _sec_advisory=$(jq -r \
                '.[] | select(.confidence == "low") | "  - \(.file // "unknown"):\(.line // "?") — \(.description // "finding") [low confidence — verify before acting]"' \
                "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || true)
            # Also include npm audit (always blocking)
            if [[ -f "$ARTIFACTS_DIR/security-audit.log" ]] && grep -qiE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null; then
                if [[ -z "$_sec_blocking" ]]; then
                    _sec_blocking=$(grep -iE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null || true)
                else
                    _sec_blocking="${_sec_blocking}"$'\n'"$(grep -iE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null || true)"
                fi
            fi
            if [[ -n "$_sec_blocking" ]]; then
                echo "### 🔴 BLOCKING: Security Findings (must fix before merge)"
                echo "$_sec_blocking"
                echo ""
                echo "These security issues MUST be resolved before merge."
                echo ""
            fi
            if [[ -n "$_sec_advisory" ]]; then
                echo "### ⚠️ ADVISORIES: Low-Confidence Security Findings (review, may be false positives)"
                echo "$_sec_advisory"
                echo ""
                echo "These are single-source, low-confidence findings. Investigate but do not treat as blocking."
                echo ""
            fi
        else
            # Fallback: raw log dump when JSON not available
            local _show_sec=false
            if [[ -f "$ARTIFACTS_DIR/security-audit.log" ]] && grep -qiE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null; then
                _show_sec=true
            fi
            if [[ -f "$ARTIFACTS_DIR/security-source-scan.log" ]] && grep -qiE 'critical|high' "$ARTIFACTS_DIR/security-source-scan.log" 2>/dev/null; then
                _show_sec=true
            fi
            if $_show_sec; then
                echo "### 🔴 PRIORITY: Security Findings (fix these first)"
                [[ -f "$ARTIFACTS_DIR/security-audit.log" ]] && cat "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null || true
                [[ -f "$ARTIFACTS_DIR/security-source-scan.log" ]] && cat "$ARTIFACTS_DIR/security-source-scan.log" 2>/dev/null || true
                echo ""
                echo "Security issues MUST be resolved before any other changes."
                echo ""
            fi
        fi

        # Adversarial review narrative
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
            echo "### Adversarial Review Findings"
            cat "$ARTIFACTS_DIR/adversarial-review.md"
            echo ""
        fi

        # Negative prompting narrative
        if [[ -f "$ARTIFACTS_DIR/negative-review.md" ]]; then
            echo "### Negative Prompting Concerns"
            echo "NOTE: These findings were generated against a PREVIOUS version of the code."
            echo "Re-read the actual current source files before making changes."
            echo "If a finding references code that has already been fixed, skip it."
            echo ""
            cat "$ARTIFACTS_DIR/negative-review.md"
            echo ""
        fi

        if [[ -f "$ARTIFACTS_DIR/dod-audit.md" ]]; then
            echo "### DoD Audit Failures"
            grep "❌" "$ARTIFACTS_DIR/dod-audit.md" 2>/dev/null || true
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/api-compat.log" ]] && grep -qi 'BREAKING' "$ARTIFACTS_DIR/api-compat.log" 2>/dev/null; then
            echo "### API Breaking Changes"
            cat "$ARTIFACTS_DIR/api-compat.log"
            echo ""
        fi

        # Style findings last (deprioritized, informational)
        if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]]; then
            local style_count
            style_count=$(jq -r '.style // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
            if [[ "$style_count" -gt 0 ]]; then
                echo "### Style Notes (non-blocking, address if time permits)"
                echo "${style_count} style suggestions found. These do not block the build."
                echo ""
            fi
        fi
    } > "$feedback_file"
}

compound_rebuild_with_feedback() {
    local cycle_num="${1:-?}"
    local feedback_file="$ARTIFACTS_DIR/quality-feedback.md"

    # ── Intelligence: classify findings and determine routing ──
    local route="correctness"
    route=$(classify_quality_findings 2>/dev/null) || route="correctness"

    # ── Build structured findings JSON alongside markdown ──
    local structured_findings="[]"
    local s_total_critical=0 s_total_major=0 s_total_minor=0

    if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]]; then
        s_total_critical=$(jq -r '.security // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
        s_total_major=$(jq -r '.correctness // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
        s_total_minor=$(jq -r '.style // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
    fi

    local tmp_qf
    tmp_qf="$(mktemp)"
    jq -n \
        --arg route "$route" \
        --argjson total_critical "$s_total_critical" \
        --argjson total_major "$s_total_major" \
        --argjson total_minor "$s_total_minor" \
        '{route: $route, total_critical: $total_critical, total_major: $total_major, total_minor: $total_minor}' \
        > "$tmp_qf" 2>/dev/null && mv "$tmp_qf" "$ARTIFACTS_DIR/quality-findings.json" || rm -f "$tmp_qf"

    # ── Architecture route: backtrack to design instead of rebuild ──
    if [[ "$route" == "architecture" ]]; then
        info "Architecture-level findings detected — attempting backtrack to design"
        if pipeline_backtrack_to_stage "design" "architecture_violation" 2>/dev/null; then
            return 0
        fi
        # Backtrack failed or already used — fall through to standard rebuild
        warn "Backtrack unavailable — falling through to standard rebuild"
    fi

    # Extract blocking items once — used by both the feedback file render and the
    # GOAL injection. Avoids double I/O and prevents any divergence between the two.
    local blocking_items
    blocking_items=$(_extract_blocking_items)

    # Redact out-of-scope path tokens from blocking_items before any prompt injection.
    # This is the load-bearing safety seam (d) — if a path is not in the prompt, the
    # agent cannot open/edit it by name. Pass-through when scope_allowlist is empty
    # (warn-mode default — zero behaviour change for repos without a scope fence).
    local _scope_allowlist=""
    _scope_allowlist=$(_extract_scope_from_design 2>/dev/null || true)
    if [ -n "$_scope_allowlist" ]; then
        blocking_items=$(_redact_paths_outside_scope "$blocking_items" "$_scope_allowlist" \
            "compound_rebuild_blocking" "${COMPOUND_QUALITY_CYCLE:-0}" 2>/dev/null || printf '%s' "$blocking_items")
    fi

    # Collect all findings (prioritized by classification)
    _write_quality_feedback "$route" "$feedback_file" "$blocking_items"

    # Validate feedback file has actual content
    if [[ ! -s "$feedback_file" ]]; then
        warn "No quality feedback collected — skipping rebuild"
        return 1
    fi

    set_outer_stage "compound_quality"
    OUTER_STAGE_START_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
    write_state 2>/dev/null || true
    log_stage "compound_quality" "rebuild cycle ${cycle_num} starting"
    # Note: format deliberately avoids the 'complete (' pattern so it is not treated as a stage completion signal.

    # Augment GOAL with quality feedback (route-specific instructions).
    # Save original_goal and install a RETURN trap so it is always restored even
    # if self_healing_build_test exits unexpectedly under set -e.
    local original_goal="$GOAL"
    local _saved_current_stage="${CURRENT_STAGE:-}"
    local _saved_pipeline_status="${PIPELINE_STATUS:-}"
    # Capture any outer RETURN trap (e.g. stage_compound_quality log-flush trap) so we
    # can restore it after clearing our own, rather than dropping it with `trap - RETURN`.
    local _outer_return_trap
    _outer_return_trap=$(trap -p RETURN 2>/dev/null || true)
    trap '{
        # Preserve PIPELINE_STUCK_CYCLING if the inner cycle set it (retry-cap hit);
        # restoring status unconditionally would mask the stuck indicator.
        if [[ "${PIPELINE_STUCK_CYCLING:-false}" != "true" ]]; then
            PIPELINE_STATUS="$_saved_pipeline_status"
        fi
        GOAL="$original_goal"
        CURRENT_STAGE="$_saved_current_stage"
        OUTER_STAGE_START_COMMIT=""
        clear_outer_stage
        log_stage "compound_quality" "rebuild cycle '"${cycle_num}"' finished"
        trap - RETURN
        # Restore outer trap (e.g. stage_compound_quality log-flush trap)
        [[ -n "$_outer_return_trap" ]] && eval "$_outer_return_trap" 2>/dev/null || true
    }' RETURN
    local feedback_content
    feedback_content=$(cat "$feedback_file")

    # Redact out-of-scope paths from feedback_content (second exposure — _write_quality_feedback
    # re-includes blocking items under its own "## Blocking Issues" header).
    if [ -n "$_scope_allowlist" ]; then
        feedback_content=$(_redact_paths_outside_scope "$feedback_content" "$_scope_allowlist" \
            "compound_rebuild_feedback" "${COMPOUND_QUALITY_CYCLE:-0}" 2>/dev/null || printf '%s' "$feedback_content")
    fi

    local route_instruction=""
    case "$route" in
        security)
            route_instruction="SECURITY PRIORITY: Fix all security vulnerabilities FIRST, then address other issues. Security issues are BLOCKING."
            ;;
        performance)
            route_instruction="PERFORMANCE PRIORITY: Address performance regressions and optimizations. Check for N+1 queries, memory leaks, and algorithmic complexity."
            ;;
        testing)
            route_instruction="TESTING PRIORITY: Add missing test coverage and fix flaky tests before addressing other issues."
            ;;
        correctness)
            route_instruction="Fix every issue listed above while keeping all existing functionality working."
            ;;
        architecture)
            route_instruction="ARCHITECTURE: Fix structural issues. Check dependency direction, layer boundaries, and separation of concerns."
            ;;
        scope)
            route_instruction="SCOPE VIOLATION: Out-of-scope edits found. Revert these files to their main-branch state entirely — do not 'fix' them, just remove your changes. If a file mixes on-scope and off-scope changes, revert ONLY the off-scope hunks. If the change is genuinely required as new scope, STOP and emit: <<<LOOP:SCOPE_ESCALATION:reason>>>. Do NOT introduce new refactoring."
            ;;
        *)
            route_instruction="Fix every issue listed above while keeping all existing functionality working."
            ;;
    esac

    if [[ -n "$blocking_items" ]]; then
        GOAL="$GOAL

BLOCKING ISSUES — fix all of these before merge:
$blocking_items

Full review context:
$feedback_content

${route_instruction}"
    else
        GOAL="$GOAL

IMPORTANT — Compound quality review found issues (route: ${route}). Fix ALL of these:
$feedback_content

${route_instruction}"
    fi

    # Re-run self-healing build→test with findings injected into GOAL.
    # The build loop's own scope guard and DoD enforcement govern the cycle —
    # no iteration cap, no targeted-file list (both regressed scope enforcement).
    info "Rebuilding with quality feedback (route: ${route})..."
    local _rebuild_rc=0
    self_healing_build_test || _rebuild_rc=$?
    GOAL="$original_goal"
    return "$_rebuild_rc"
}

# Removes negative-review-cycle*.md files from ARTIFACTS_DIR.
# Called at stage_compound_quality entry and all exit paths to prevent stale
# cycle files from accumulating across pipeline runs.
_cleanup_cycle_files() {
    rm -f "$ARTIFACTS_DIR"/negative-review-cycle*.md 2>/dev/null || true
}

# pipeline_run_ruflo_cq_hive — invoke ruflo adversarial quality hive (issue #418)
# Runs ruflo_execute_compound_quality once per stage to collect parallel
# adversarial findings (negative tests, DoD audit, E2E coverage) before the
# native cascade begins. Findings are written to artifact_file so the cascade
# audit agents and downstream consumers can ingest hive context.
#
# Usage: pipeline_run_ruflo_cq_hive <diff_content> <artifact_file>
# Returns 0 when hive completed and produced findings; 1 otherwise.
# Always fail-open — caller continues native checks regardless of return code.
#
# Env knobs:
#   RUFLO_CQ_ENABLED — set to "false" to opt out (default: enabled when ruflo
#                      is available). Native checks always run regardless.
pipeline_run_ruflo_cq_hive() {
    local diff_content="${1:-}"
    local artifact_file="${2:-}"
    [[ -n "$artifact_file" ]] || return 1

    # Opt-out gate: explicit false skips the hive without trying ruflo.
    if [[ "${RUFLO_CQ_ENABLED:-true}" == "false" ]]; then
        emit_event "ruflo.cq_skipped" "reason=disabled" 2>/dev/null || true
        return 1
    fi

    # Capability gate: adapter functions must be loaded and ruflo available.
    if ! declare -f ruflo_execute_compound_quality >/dev/null 2>&1 \
        || ! declare -f ruflo_available >/dev/null 2>&1 \
        || ! ruflo_available; then
        emit_event "ruflo.cq_skipped" "reason=unavailable" 2>/dev/null || true
        return 1
    fi

    # Empty diff means nothing to audit — skip without burning a hive.
    if [[ -z "$diff_content" ]]; then
        emit_event "ruflo.cq_skipped" "reason=empty_diff" 2>/dev/null || true
        return 1
    fi

    if ruflo_execute_compound_quality "$diff_content" "$artifact_file"; then
        info "Ruflo adversarial quality hive complete"
        emit_event "ruflo.cq_complete" "stage=compound_quality" 2>/dev/null || true
        return 0
    fi

    warn "Ruflo compound quality hive failed — continuing with native checks"
    emit_event "ruflo.cq_fallback" "reason=hive_failed" 2>/dev/null || true
    return 1
}


# ─── Error Classification ──────────────────────────────────────────────────
