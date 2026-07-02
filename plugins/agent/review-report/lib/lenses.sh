#!/usr/bin/env bash
# plugins/agent/review-report/lib/lenses.sh — multi-lens fan-out + aggregation.
#
# ADR-038 (EPIC #966 I6). Each lens is a SEPARATE LLM call (one prompt per lens,
# NOT one prompt with N sections — the cq-cycle trap ADR-038 §2 rejects). The N
# calls run bounded-parallel in isolated subshells (ZBUILD_CURRENT_STAGE unset)
# so the concurrent route_to_model calls don't corrupt shared stage-io/banner/
# budget state. Findings are aggregated + de-duped by file + category + proximity
# into an advisory merge-readiness report. Advisory only: no recommended merge
# action, no pipeline gate — the caller always returns 0.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_RR_LENSES_LOADED:-}" ]] && return 0
_ZBUILD_RR_LENSES_LOADED=1

# Load _RR_LENSES from manifest.yaml config.lenses; fail-soft to the hardcoded list.
# BASH_SOURCE[0] is this file (lenses.sh); ".." reaches the plugin root containing manifest.yaml.
_rr_load_lenses() {
    local _manifest_dir _manifest _item
    _manifest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || true
    _manifest="${_manifest_dir}/manifest.yaml"
    local -a _items=()
    if [[ -f "$_manifest" ]]; then
        while IFS= read -r _item; do
            [[ -n "$_item" ]] && _items+=("$_item")
        done < <(awk '
            BEGIN { in_cfg=0; in_lst=0 }
            /^config:$/              { in_cfg=1; next }
            in_cfg && /^[^ ]/        { in_cfg=0; in_lst=0; next }
            in_cfg && /^  lenses:$/  { in_lst=1; next }
            in_lst && /^  [^ #]/     { in_lst=0 }
            in_lst && /^    - [a-z]/ { val=substr($0,7); gsub(/[[:space:]]+$/,"",val); if (val!="") print val }
        ' "$_manifest" 2>/dev/null)
    fi
    if [[ "${#_items[@]}" -gt 0 ]]; then
        _RR_LENSES=("${_items[@]}")
    else
        # Fail-soft: manifest absent or unparseable — use known-good list.
        _RR_LENSES=(correctness security test-coverage design-conformance integration error-handling performance edge-case architecture red-team maintainability)
    fi
}
_rr_load_lenses

# Severity ordinal map (jq-injected for max-severity selection in dedup).
_RR_SEV_RANK='{"low":1,"medium":2,"high":3,"critical":4}'

# Per-lens artifact registry: maps lens name → artifact path. Empty by default;
# producer issues populate entries before calling _rr_fanout_lenses.
declare -A _RR_LENS_ARTIFACT_REGISTRY=()

# Proximity window (lines): two findings on the same file+category within this
# many lines de-dupe to one. Override with ZBUILD_RR_PROXIMITY_WINDOW. Clamped
# to a positive integer — a 0 or non-integer would be a jq division-by-zero /
# --argjson parse error that degrades the whole report to the fallback.
_rr_proximity_window() {
    local w="${ZBUILD_RR_PROXIMITY_WINDOW:-10}"
    [[ "$w" =~ ^[1-9][0-9]*$ ]] || w=10
    printf '%s' "$w"
}

# ─── _rr_lens_charter <lens> ────────────────────────────────────────────────
# The distinct question each lens asks. ADR-038: lenses differ by the artifact
# they receive (#973); for I6 they differ by charter over a shared bundle.
_rr_lens_charter() {
    case "$1" in
        correctness)
            printf '%s' "Examine the change for logic errors: off-by-one mistakes, unhandled null/undefined values, incorrect assumptions about data shapes, and control-flow bugs." ;;
        security)
            printf '%s' "Examine the change for security weaknesses: injection risks, credential or secret exposure, path traversal, and missing input validation at system boundaries (CLI, parsers, plugin manifests)." ;;
        test-coverage)
            printf '%s' "Examine whether the changed lines are exercised by tests: untested public functions, missing edge-case coverage, and assertions that are too weak to catch a regression." ;;
        design-conformance)
            printf '%s' "Examine whether the change implements what the plan and design described: missing pieces, out-of-scope additions, and divergence from the stated approach." ;;
        integration)
            printf '%s' "Examine the change for integration problems: missing imports, broken call chains, mismatched interfaces between modules, functions called with wrong argument shapes, and wiring gaps where new code is not connected to existing code." ;;
        error-handling)
            printf '%s' "Examine the change for error-handling gaps: silent error swallowing, missing error paths when external commands fail, inconsistent error patterns, and unchecked return values." ;;
        performance)
            printf '%s' "Examine the change for performance problems: O(n^2) or worse loop patterns, unbounded memory allocation or file reads, missing pagination or streaming for large data, and repeated expensive operations that could be cached." ;;
        edge-case)
            printf '%s' "Examine the change for edge-case gaps: zero-length inputs, empty strings and arrays, boundary values at maximum or minimum, Unicode and special characters in data paths, and concurrent access timing issues." ;;
        architecture)
            printf '%s' "Examine the change for architectural violations: layer-boundary breaches, coupling between components that should be isolated, divergence from established patterns and conventions, and structural decisions that would impede future evolution." ;;
        red-team)
            printf '%s' "Examine the change as a hostile reviewer looking for exploitable flaws: race conditions, privilege escalation paths, logic errors that can be triggered by adversarial input, and security assumptions that break under adversarial conditions." ;;
        maintainability)
            printf '%s' "Examine the change for long-term maintainability risks: code smells, poor naming, unclear logic, coupling issues, missing tests, and violations of established patterns that make future changes harder." ;;
        *)
            printf '%s' "Examine the change for issues relevant to the ${1} concern." ;;
    esac
}

# ─── _rr_build_lens_prompt <lens> <evidence_content> ────────────────────────
# One prompt for ONE lens. Advisory contract: emit findings + a 0-10 score only.
_rr_build_lens_prompt() {
    local lens="$1" evidence="$2" charter
    charter="$(_rr_lens_charter "$lens")"
    cat <<PROMPT
You are the "${lens}" review lens. ${charter}

This is an advisory report. Describe what you find; do NOT recommend a merge
action and do NOT gate anything. Report only issues you can point to in the
change below.

OUTPUT CONTRACT (obey absolutely):
- Respond with EXACTLY ONE JSON object. First character '{', last character '}'.
- No markdown code fences, no prose before or after the JSON.
- Schema:
  {
    "score": <integer 0-10, 10 = no concerns for this lens>,
    "findings": [
      {
        "file": "<path>",
        "category": "<short category, e.g. logic, injection, coverage>",
        "severity": "<one of: low, medium, high, critical>",
        "line": <integer line number or null>,
        "message": "<one-sentence description>"
      }
    ]
  }
- If you find nothing for this lens, return {"score": 10, "findings": []}.

CHANGE UNDER REVIEW:
${evidence}

Emit the JSON object now.
PROMPT
}

# ─── _rr_parse_lens_out <lens> <out_file> <rc> ──────────────────────────────
# Normalize one lens's raw LLM output into {name, score, findings[]}. A failed
# or unparseable lens degrades to an empty result (advisory — never fatal).
_rr_parse_lens_out() {
    local lens="$1" out_file="$2" rc="$3"
    local empty
    empty="$(jq -nc --arg n "$lens" '{name:$n, score:0, findings:[]}')"

    if [[ "$rc" -ne 0 || ! -s "$out_file" ]]; then
        emit_event "review_report.lens.failed" "lens=$lens" "rc=$rc" 2>/dev/null || true
        printf '%s' "$empty"; return 0
    fi

    local json
    json="$(extract_first_json_object < "$out_file" 2>/dev/null || true)"
    if [[ -z "$json" ]] || ! printf '%s' "$json" | jq empty >/dev/null 2>&1; then
        emit_event "review_report.lens.unparseable" "lens=$lens" 2>/dev/null || true
        printf '%s' "$empty"; return 0
    fi

    # Coerce to the normalized shape; tolerate string or object findings.
    printf '%s' "$json" | jq -c --arg n "$lens" '
        {
          name: $n,
          score: ((.score // 0) | if type=="number" then floor else 0 end),
          findings: [ (.findings // [])[] |
            if type=="object" then {
              file: (.file // "unknown"),
              category: (.category // "general"),
              severity: (if (.severity|tostring|ascii_downcase) as $s
                         | ["low","medium","high","critical"] | index($s)
                         then (.severity|tostring|ascii_downcase) else "low" end),
              line: (.line // null),
              message: (.message // (.|tostring))
            } else {
              file: "unknown", category: "general", severity: "low",
              line: null, message: (.|tostring)
            } end ]
        }' 2>/dev/null || printf '%s' "$empty"
}

# ─── _rr_populate_artifact_registry <artifact_dir> ──────────────────────────
# Registers per-lens artifacts before _rr_fanout_lenses runs. Sets
# _RR_LENS_ARTIFACT_REGISTRY["design-conformance"] to reachability-ablation.json
# when that file is non-empty (#1077 resolver registration).
_rr_populate_artifact_registry() {
    local artifact_dir="$1"
    local ablation_path="$artifact_dir/reachability-ablation.json"
    if [[ -s "$ablation_path" ]]; then
        _RR_LENS_ARTIFACT_REGISTRY["design-conformance"]="$ablation_path"
    fi
}

# ─── _rr_register_lens_artifact <lens> <path> ───────────────────────────────
# Register a per-lens artifact path. Called by the review-report plugin (before
# _rr_fanout_lenses) to wire distinct evidence without sourcing private internals.
_rr_register_lens_artifact() {
    local lens="$1" path="$2"
    _RR_LENS_ARTIFACT_REGISTRY["$lens"]="$path"
}

# ─── _rr_lens_evidence <lens> <artifact_dir> ────────────────────────────────
# Returns the registered artifact path for the lens when _RR_LENS_ARTIFACT_REGISTRY
# has a non-empty file entry, or empty stdout to signal fallback to shared bundle.
_rr_lens_evidence() {
    local lens="$1"
    local path="${_RR_LENS_ARTIFACT_REGISTRY[$lens]:-}"
    if [[ -n "$path" && -s "$path" ]]; then
        printf '%s' "$path"
    fi
    return 0
}

# ─── _rr_fanout_lenses <scope_manifest> <evidence_file> <artifact_dir> <tier> ─
# Bounded-parallel: run each lens as an isolated subshell LLM call, batched by
# ZBUILD_RR_MAX_PARALLEL. ADR-043: redaction is owned by the router — each lens
# prompt is redacted by route_to_model by construction, so this builds prompts
# from RAW evidence. $1 (scope_manifest) is accepted for call-compat, unused.
# Writes per-lens result JSON and echoes the path to the combined lenses array.
_rr_fanout_lenses() {
    local evidence_file="$2" artifact_dir="$3" tier="${4:-T2}"
    local max="${ZBUILD_RR_MAX_PARALLEL:-4}"
    [[ "$max" -ge 1 ]] 2>/dev/null || max=1
    mkdir -p "$artifact_dir"

    # Resolve the shared evidence; an absent/empty bundle yields a clean report.
    local evidence_content="(no change bundle available)"
    if [[ -s "$evidence_file" ]]; then
        evidence_content="$(cat "$evidence_file")"
    fi

    # Build all prompts up front (sequential, local), then launch in batches.
    # Per-lens evidence: if a lens has a registered artifact, use it (raw);
    # otherwise use the shared bundle. The router redacts every prompt.
    local lens _lens_specific_path _lens_ev_content
    for lens in "${_RR_LENSES[@]}"; do
        _lens_specific_path="$(_rr_lens_evidence "$lens" "$artifact_dir")"
        if [[ -n "$_lens_specific_path" && -s "$_lens_specific_path" ]]; then
            _lens_ev_content="$(cat "$_lens_specific_path")"
        else
            _lens_ev_content="$evidence_content"
        fi
        _rr_build_lens_prompt "$lens" "$_lens_ev_content" \
            > "$artifact_dir/lens-$lens-prompt.txt"
    done

    local total="${#_RR_LENSES[@]}" i=0
    while [[ $i -lt $total ]]; do
        local j=0
        local -a _batch_pids=()
        while [[ $j -lt $max && $((i + j)) -lt $total ]]; do
            lens="${_RR_LENSES[$((i + j))]}"
            (
                # Isolation: unset the shared stage so concurrent route_to_model
                # calls don't corrupt stage-io/banner/budget state.
                unset ZBUILD_CURRENT_STAGE
                export ZBUILD_ROUTER_JSON_OUTPUT=1
                local _out _rc=0
                _out="$(route_to_model "$tier" "$(cat "$artifact_dir/lens-$lens-prompt.txt")")" || _rc=$?
                printf '%s' "$_out" > "$artifact_dir/lens-$lens.out"
                printf '%s' "$_rc"  > "$artifact_dir/lens-$lens.rc"
            ) &
            _batch_pids+=("$!")
            j=$((j + 1))
        done
        # Wait only on THIS batch's subshells (not a bare `wait` that would also
        # block on any unrelated background job the caller may be running).
        local _p
        for _p in "${_batch_pids[@]}"; do wait "$_p" 2>/dev/null || true; done
        i=$((i + max))
    done

    # Collect + normalize (sequential).
    : > "$artifact_dir/review-report-lenses.json.tmp"
    for lens in "${_RR_LENSES[@]}"; do
        local rc; rc="$(cat "$artifact_dir/lens-$lens.rc" 2>/dev/null || echo 1)"
        _rr_parse_lens_out "$lens" "$artifact_dir/lens-$lens.out" "$rc" \
            >> "$artifact_dir/review-report-lenses.json.tmp"
        printf '\n' >> "$artifact_dir/review-report-lenses.json.tmp"
    done
    jq -sc '.' "$artifact_dir/review-report-lenses.json.tmp" \
        > "$artifact_dir/review-report-lenses.json"
    rm -f "$artifact_dir/review-report-lenses.json.tmp"
    printf '%s' "$artifact_dir/review-report-lenses.json"
}

# ─── _rr_aggregate <lenses_json_file> ───────────────────────────────────────
# Aggregate per-lens results into the advisory merge-readiness report. Flat
# findings are de-duped by file + category + proximity bucket, carrying the max
# severity, the union of contributing lenses, and the union of messages.
_rr_aggregate() {
    local lenses_file="$1" window; window="$(_rr_proximity_window)"
    jq -c \
        --argjson rank "$_RR_SEV_RANK" \
        --argjson win "$window" '
        . as $lenses
        | [ $lenses[] as $l | ($l.findings // [])[] | . + {lens: $l.name} ] as $all
        | ( $all
            | group_by([.file, .category, ((.line // 0) / $win | floor)])
            | map({
                file: .[0].file,
                category: .[0].category,
                line: ([ .[].line | select(. != null) ] | min),
                severity: ( max_by($rank[.severity] // 0) | .severity ),
                lenses: ([ .[].lens ] | unique),
                messages: ([ .[].message ] | unique)
              })
          ) as $flat
        | ( [ $lenses[].score ] ) as $scores
        | ( [ $flat[].severity ] ) as $sevs
        | (
            if ($sevs | any(. == "critical")) then "needs_attention"
            elif ($scores | any(. <= 3)) then "needs_attention"
            elif ($flat | length) == 0 and ($scores | all(. >= 7)) then "ready"
            else "advisory" end
          ) as $readiness
        | {
            schema_version: 1,
            merge_readiness: $readiness,
            lenses: $lenses,
            findings: $flat,
            summary: (
              "\($flat | length) merge-readiness finding(s) across "
              + "\($lenses | length) lens(es)"
              + " (\([ $sevs[] | select(. == "critical") ] | length) critical, "
              + "\([ $sevs[] | select(. == "high") ] | length) high)."
            ),
            escalation_note: (
              if $readiness == "needs_attention" then
                "One or more lenses scored <=3 or found a critical-severity issue; consider requesting a tier-2 expert review or escalating to a senior reviewer before merging. Advisory only — this does not block the pipeline."
              else null end
            )
          }' "$lenses_file" 2>/dev/null \
    || printf '{"schema_version":1,"merge_readiness":"advisory","lenses":[],"findings":[],"summary":"Report unavailable: aggregation error."}'
}
