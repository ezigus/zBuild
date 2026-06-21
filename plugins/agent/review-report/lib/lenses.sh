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

# I6 fixed roster (mirrors manifest config.lenses; #974 makes it config-driven
# and adds the full cq + persona content). Each entry is one independent LLM call.
_RR_LENSES=(correctness security test-coverage design-conformance)

# Severity ordinal map (jq-injected for max-severity selection in dedup).
_RR_SEV_RANK='{"low":1,"medium":2,"high":3,"critical":4}'

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

# ─── _rr_fanout_lenses <scope_manifest> <evidence_file> <artifact_dir> <tier> ─
# Bounded-parallel: redact the shared evidence bundle once (the ADR-004
# chokepoint; #973 moves this per-lens when evidence diverges), then run each
# lens as an isolated subshell LLM call, batched by ZBUILD_RR_MAX_PARALLEL.
# Writes per-lens result JSON and echoes the path to the combined lenses array.
_rr_fanout_lenses() {
    local scope_manifest="$1" evidence_file="$2" artifact_dir="$3" tier="${4:-T2}"
    local max="${ZBUILD_RR_MAX_PARALLEL:-4}"
    [[ "$max" -ge 1 ]] 2>/dev/null || max=1
    mkdir -p "$artifact_dir"

    # Resolve evidence; an absent/empty bundle yields a clean empty report.
    local evidence_content="(no change bundle available)"
    if [[ -s "$evidence_file" ]]; then
        # Redaction chokepoint (ADR-004): refuse to send raw text to any lens.
        local redacted="$artifact_dir/review-report-evidence.redacted.txt"
        if apply_scope_redaction "$evidence_file" "$redacted" "$scope_manifest" "" "0"; then
            evidence_content="$(cat "$redacted")"
        else
            emit_event "review_report.evidence.redaction_failed" "evidence=$(basename "$evidence_file")" 2>/dev/null || true
            # All lenses degrade to empty; still emit a report and return 0.
            local lens
            : > "$artifact_dir/review-report-lenses.json.tmp"
            for lens in "${_RR_LENSES[@]}"; do
                jq -nc --arg n "$lens" '{name:$n, score:0, findings:[]}' \
                    >> "$artifact_dir/review-report-lenses.json.tmp"
            done
            jq -sc '.' "$artifact_dir/review-report-lenses.json.tmp" \
                > "$artifact_dir/review-report-lenses.json"
            rm -f "$artifact_dir/review-report-lenses.json.tmp"
            printf '%s' "$artifact_dir/review-report-lenses.json"
            return 0
        fi
    fi

    # Build all prompts up front (sequential, local), then launch in batches.
    local lens
    for lens in "${_RR_LENSES[@]}"; do
        _rr_build_lens_prompt "$lens" "$evidence_content" \
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
        | {
            schema_version: 1,
            merge_readiness: (
              if ($sevs | any(. == "critical")) then "needs_attention"
              elif ($scores | any(. <= 3)) then "needs_attention"
              elif ($flat | length) == 0 and ($scores | all(. >= 7)) then "ready"
              else "advisory" end),
            lenses: $lenses,
            findings: $flat,
            summary: (
              "\($flat | length) merge-readiness finding(s) across "
              + "\($lenses | length) lens(es)"
              + " (\([ $sevs[] | select(. == "critical") ] | length) critical, "
              + "\([ $sevs[] | select(. == "high") ] | length) high)."
            )
          }' "$lenses_file" 2>/dev/null \
    || printf '{"schema_version":1,"merge_readiness":"advisory","lenses":[],"findings":[],"summary":"Report unavailable: aggregation error."}'
}
