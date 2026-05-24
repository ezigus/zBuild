#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  compound-audit — Adaptive multi-agent audit cascade                    ║
# ║                                                                         ║
# ║  Runs specialized audit agents in parallel, deduplicates findings,      ║
# ║  escalates to specialists when needed, and converges when confidence    ║
# ║  is high. All functions fail-open with || return 0.                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_COMPOUND_AUDIT_LOADED:-}" ]] && return 0
_COMPOUND_AUDIT_LOADED=1

# _filter_gitignored_paths lives in helpers.sh — load it if not already present.
_COMPOUND_AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [[ -z "${_SW_HELPERS_LOADED:-}" ]]; then
    if [[ -f "${_COMPOUND_AUDIT_DIR}/helpers.sh" ]]; then
        source "${_COMPOUND_AUDIT_DIR}/helpers.sh"
    else
        echo "[compound-audit] WARNING: helpers.sh not found at ${_COMPOUND_AUDIT_DIR}/helpers.sh — _filter_gitignored_paths unavailable" >&2
    fi
fi
unset _COMPOUND_AUDIT_DIR

# ─── Agent prompt templates ────────────────────────────────────────────────
# Each agent gets the same context but a specialized lens.

_COMPOUND_AGENT_PROMPTS_logic="You are a Logic Auditor. Focus ONLY on:
- Control flow bugs, off-by-one errors, wrong conditions
- Algorithm errors, incorrect logic, null/undefined paths
- Race conditions, state management bugs
- Edge cases in arithmetic or string operations
Do NOT report style issues, missing features, or integration problems."

_COMPOUND_AGENT_PROMPTS_integration="You are an Integration Auditor. Focus ONLY on:
- Missing imports, broken call chains, unconnected components
- Mismatched interfaces between modules
- Functions called with wrong arguments or missing arguments
- Wiring gaps where new code isn't connected to existing code
Do NOT report logic bugs, style issues, or missing features."

_COMPOUND_AGENT_PROMPTS_completeness="You are a Completeness Auditor. Focus ONLY on:
- Spec vs. implementation gaps (does the code do what the plan says?)
- Missing test coverage for new functionality
- TODO/FIXME/placeholder code left behind
- Partial implementations (feature started but not finished)
Do NOT report logic bugs, style issues, or integration problems."

_COMPOUND_AGENT_PROMPTS_security="You are a Security Auditor. Focus ONLY on:
- Command injection, path traversal, input validation gaps
- Credential/secret exposure in code or logs
- Authentication/authorization bypass paths
- OWASP top 10 vulnerability patterns
Do NOT report non-security issues."

_COMPOUND_AGENT_PROMPTS_error_handling="You are an Error Handling Auditor. Focus ONLY on:
- Silent error swallowing (empty catch blocks, ignored return codes)
- Missing error paths (what happens when X fails?)
- Inconsistent error handling patterns
- Unchecked return values from external commands
Do NOT report non-error-handling issues."

_COMPOUND_AGENT_PROMPTS_performance="You are a Performance Auditor. Focus ONLY on:
- O(n^2) or worse patterns in loops
- Unbounded memory allocation or file reads
- Missing pagination or streaming for large data
- Repeated expensive operations that could be cached
Do NOT report non-performance issues."

_COMPOUND_AGENT_PROMPTS_edge_case="You are an Edge Case Auditor. Focus ONLY on:
- Zero-length inputs, empty strings, empty arrays
- Maximum/minimum boundary values
- Unicode, special characters, newlines in data
- Concurrent access, timing-dependent behavior
Do NOT report non-edge-case issues."

# ─── compound_audit_build_prompt ───────────────────────────────────────────
# Builds the full prompt for a specific agent type.
#
# Usage: compound_audit_build_prompt "logic" "$diff" "$plan" "$prev_findings_json" ["$test_evidence"] ["$file_contents"]
compound_audit_build_prompt() {
    local agent_type="$1"
    local diff="$2"
    local plan_summary="$3"
    local prev_findings="$4"
    local test_evidence="${5:-}"
    local file_contents="${6:-}"

    # Get agent-specific instructions
    local varname="_COMPOUND_AGENT_PROMPTS_${agent_type}"
    local specialization="${!varname:-"You are a code auditor. Review the changes for issues."}"

    local evidence_section=""
    if [[ -n "$test_evidence" ]]; then
        evidence_section="
## Test Evidence (Pipeline Verified — Trust This)
${test_evidence}

CRITICAL: If a test references an identifier, method, or symbol not in this diff,
it already exists in the codebase from prior commits. Do NOT flag 'missing code'
issues for anything the passing tests have already verified.
The diff shows CHANGES only — not the complete codebase.
"
    fi

    local file_contents_section=""
    if [[ -n "$file_contents" ]]; then
        file_contents_section="
## Current File State (HEAD/committed versions of all changed files)
This is ground truth from the repository HEAD. The diff above shows CHANGES only.
Use this section to verify imports, function definitions, and symbols before flagging them.

VERIFICATION RULE: Before reporting any finding about a missing import, undefined symbol,
absent function, or unresolved reference — first search the 'Current File State' section
below. If the symbol appears there, do NOT report it as missing.

${file_contents}
"
    fi

    # Seam (a): redact out-of-scope paths from diff, prev_findings, and file_contents_section
    # before audit-prompt construction. This is upstream of intel.sh:_extract_blocking_items —
    # audit findings feed _extract_blocking_items which feeds the GOAL string.
    local _ca_scope_allowlist=""
    _ca_scope_allowlist=$(_extract_scope_from_design 2>/dev/null || true)
    local _ca_diff="$diff"
    local _ca_prev="$prev_findings"
    local _ca_fcs="$file_contents_section"
    if [ -n "$_ca_scope_allowlist" ]; then
        _ca_diff=$(_redact_paths_outside_scope "$diff" "$_ca_scope_allowlist" \
            "compound_audit_diff" "${COMPOUND_QUALITY_CYCLE:-0}" 2>/dev/null || printf '%s' "$diff")
        _ca_prev=$(_redact_paths_outside_scope "$prev_findings" "$_ca_scope_allowlist" \
            "compound_audit_prev" "${COMPOUND_QUALITY_CYCLE:-0}" 2>/dev/null || printf '%s' "$prev_findings")
        _ca_fcs=$(_redact_paths_outside_scope "$file_contents_section" "$_ca_scope_allowlist" \
            "compound_audit_files" "${COMPOUND_QUALITY_CYCLE:-0}" 2>/dev/null || printf '%s' "$file_contents_section")
    fi

    cat <<EOF
${specialization}

## Code Changes (cumulative diff)
\`\`\`
${_ca_diff}
\`\`\`

## Implementation Plan/Spec
${plan_summary}

## Previously Found Issues (do NOT repeat these)
${_ca_prev}
${evidence_section}
${_ca_fcs}
## Output Format
Return ONLY valid JSON (no markdown, no explanation):
{"findings":[{"severity":"critical|high|medium|low","category":"${agent_type}","file":"path/to/file","line":0,"description":"One sentence","evidence":"The specific code","suggestion":"How to fix"}]}

If no issues found, return: {"findings":[]}
EOF
}

# ─── compound_audit_parse_findings ─────────────────────────────────────────
# Parses agent output into a findings array. Handles malformed output.
#
# Usage: compound_audit_parse_findings "$agent_stdout"
# Output: JSON array of findings (or empty array on failure)
compound_audit_parse_findings() {
    local raw_output="$1"

    # Strip markdown code fences if present
    local cleaned
    cleaned=$(echo "$raw_output" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\r')

    # Try to extract findings array
    local findings
    findings=$(echo "$cleaned" | jq -r '.findings // []' 2>/dev/null) || findings="[]"

    # Validate it's actually an array
    if echo "$findings" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$findings"
    else
        echo "[]"
    fi
}

# ─── compound_audit_dedup_structural ───────────────────────────────────────
# Tier 1 dedup: same file + same category + lines within 5 = duplicate.
# Keeps the first (highest severity) finding in each group.
#
# Usage: compound_audit_dedup_structural "$findings_json_array"
# Output: Deduplicated JSON array
compound_audit_dedup_structural() {
    local findings="$1"

    [[ -z "$findings" || "$findings" == "[]" ]] && { echo "[]"; return 0; }

    # Use jq to group by file+category, then within each group merge findings
    # whose lines are within 5 of each other
    echo "$findings" | jq '
      # Sort by severity priority (critical first) then by line
      def sev_order: if . == "critical" then 0 elif . == "high" then 1
        elif . == "medium" then 2 else 3 end;

      sort_by([(.severity | sev_order), .line]) |

      # Group by file + category
      group_by([.file, .category]) |

      # Within each group, merge findings with lines within 5
      map(
        reduce .[] as $item ([];
          if length == 0 then [$item]
          elif (. | last | .line) and $item.line and
               (($item.line - (. | last | .line)) | fabs) <= 5
          then .  # Skip duplicate (nearby line, same file+category)
          else . + [$item]
          end
        )
      ) | flatten
    ' 2>/dev/null || echo "$findings"
}

# ─── compound_audit_verify_findings ────────────────────────────────────────
# Layer 2 hallucination filter. Drops findings where the LLM claims a symbol
# is missing but structural verification proves the symbol is actually present
# in the cited file. Complements the Layer 1 full-file-context prompt (#341).
#
# Ground truth: git show HEAD:<file> → cat <file>. This mirrors
# compound_audit_collect_file_contents (line 239) so the verifier inspects
# exactly the bytes the model saw in its prompt.
#
# Fail-open rules (any of these → keep the finding, never drop):
#   1. Description + evidence doesn't match the absence pattern
#   2. No symbol could be extracted from description + evidence
#   3. File field is empty
#   4. File is unreadable via both git show and cat
#   5. grep exits non-zero (symbol genuinely not in file)
#
# Symbol extraction covers real-world LLM phrasings observed in practice:
#   - "import X"                        (Swift, Go, TS, Python)
#   - "cannot find 'X' in scope"        (Swift)
#   - "Cannot find name 'X'"            (TypeScript)
#   - "undefined: X"                    (Go)
#   - "'X' is not defined"              (Python / plain English)
# Identifiers may be lowercase. Surrounding quotes are stripped.
# Multi-symbol claims: only the first symbol is verified. If present, drop —
# Layer 1 full-file context is the right place for comprehensive analysis.
#
# Usage: compound_audit_verify_findings "$findings_json_array"
# Output: Filtered JSON array on stdout.
compound_audit_verify_findings() {
    local findings="$1"
    [[ -z "$findings" || "$findings" == "[]" ]] && { echo "[]"; return 0; }

    # Unambiguous absence phrasings. Excludes standalone "missing" and plain
    # "not defined" which match too much prose; "is not defined" is retained
    # because it is a specific compiler/runtime diagnostic phrase.
    # (e.g. "Missing null check for import stream" does NOT match — no
    # "missing import" substring — while "X is not defined" does match.)
    local absence_pattern='missing import|not imported|undefined (symbol|reference|identifier)|undefined:|undeclared (identifier|type)|use of unresolved|use of undeclared|unresolved reference|cannot find .* in scope|cannot find name|no such (module|type|identifier)|is not defined'

    local count
    # Fail-open: if jq can't parse or count the array, return original findings
    # unchanged rather than silently dropping everything.
    if ! count=$(echo "$findings" | jq -e 'if type == "array" then length else error("expected array") end' 2>/dev/null); then
        echo "$findings"
        return 0
    fi
    [[ "$count" -eq 0 ]] && { echo "[]"; return 0; }

    # Collect indices of findings to keep. Build the final array in one
    # jq pass at the end to avoid spawning a jq process per kept finding.
    local keep_indices=""
    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local desc evidence file combined symbol keep raw_fields
        keep=1
        # Single jq call extracts all fields; join with ASCII Unit Separator (\x1f),
        # a non-whitespace character so IFS read preserves empty fields between delimiters.
        raw_fields=$(echo "$findings" | jq -r ".[$i] | [.description // \"\", .evidence // \"\", .file // \"\"] | join(\"\u001f\")" 2>/dev/null || true)
        IFS=$'\x1f' read -r desc evidence file <<< "$raw_fields"
        combined="$desc $evidence"

        # Normalize path: strip leading ./ and collapse //
        file="${file#./}"
        while [[ "$file" == *//* ]]; do file="${file//\/\//\/}"; done

        # Safety: reject absolute paths and directory traversal from the
        # LLM-supplied file field before using it in git show / cat.
        # Fail-open: unsafe paths are kept, not dropped.
        if [[ "$file" == /* || "$file" == *../* || "$file" == */.. ]]; then
            keep_indices="${keep_indices}${keep_indices:+,}${i}"
            i=$((i + 1))
            continue
        fi

        if [[ -n "$file" ]] && echo "$combined" | grep -qiE "$absence_pattern" 2>/dev/null; then
            symbol=""

            # Priority 1: "import X" or "import {X}"
            symbol=$(echo "$combined" | grep -oE "import[[:space:]]+\{?[A-Za-z_][A-Za-z0-9_]*" \
                | grep -oE "[A-Za-z_][A-Za-z0-9_]*$" | grep -v '^import$' | head -1 || true)

            # Priority 2: quoted symbol after "find" / "find name"
            if [[ -z "$symbol" ]]; then
                symbol=$(echo "$combined" | grep -oE "find( name)?[[:space:]]+['\"\`]?[A-Za-z_][A-Za-z0-9_]*" \
                    | grep -oE "[A-Za-z_][A-Za-z0-9_]*$" | head -1 || true)
            fi

            # Priority 3: Go-style "undefined: X"
            if [[ -z "$symbol" ]]; then
                symbol=$(echo "$combined" | grep -oE "undefined:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*" \
                    | grep -oE "[A-Za-z_][A-Za-z0-9_]*$" | head -1 || true)
            fi

            # Priority 4: Python / plain English "'X' is not defined"
            if [[ -z "$symbol" ]]; then
                symbol=$(echo "$combined" \
                    | grep -oE "['\"\`][A-Za-z_][A-Za-z0-9_]*['\"\`][[:space:]]+is not defined" \
                    | grep -oE "[A-Za-z_][A-Za-z0-9_]*" | head -1 || true)
            fi

            # Validate: symbol must be a non-empty proper identifier, max 128
            # chars. Rejects crafted inputs that slip through the regexes
            # (e.g. excessively long names, single-char noise tokens).
            if [[ -n "$symbol" ]] && \
               [[ ${#symbol} -le 128 ]] && \
               [[ "$symbol" =~ ^[A-Za-z_][A-Za-z0-9_]{0,127}$ ]]; then
                : # valid — proceed to content check below
            else
                symbol=""
            fi

            if [[ -n "$symbol" ]]; then
                # Fetch content the same way the prompt collector does:
                # git show HEAD:file first, fall back to worktree cat.
                local content=""
                content=$(git show "HEAD:${file}" 2>/dev/null) \
                    || content=$(cat "$file" 2>/dev/null) \
                    || content=""

                if [[ -n "$content" ]] && printf '%s' "$content" | grep -qwF -- "$symbol" 2>/dev/null; then
                    # Symbol present → finding is a hallucination → drop it.
                    keep=0
                    type audit_emit >/dev/null 2>&1 && \
                        audit_emit "compound.false_positive_dropped" \
                            "symbol=$symbol" "file=$file" "description=$desc" || true
                fi
                # Empty content or grep miss → fall through to keep=1.
            fi
        fi

        if [[ "$keep" -eq 1 ]]; then
            keep_indices="${keep_indices}${keep_indices:+,}${i}"
        fi
        i=$((i + 1))
    done

    if [[ -z "$keep_indices" ]]; then
        echo "[]"
        return 0
    fi

    # Single jq pass to materialize the kept subset.
    echo "$findings" | jq --argjson ks "[$keep_indices]" '[.[$ks[]]]' 2>/dev/null || echo "$findings"
}

# ─── Escalation trigger keywords ──────────────────────────────────────────
_COMPOUND_TRIGGERS_security="injection|auth|secret|credential|permission|bypass|xss|csrf|traversal|sanitiz"
_COMPOUND_TRIGGERS_error_handling="catch|swallow|silent|ignore.*error|missing.*error|unchecked|unhandled"
_COMPOUND_TRIGGERS_performance="O\\(n|loop.*loop|unbounded|pagination|cache|memory.*leak|quadratic"
_COMPOUND_TRIGGERS_edge_case="boundary|empty.*input|null.*check|zero.*length|unicode|concurrent|race"

# ─── compound_audit_collect_file_contents ──────────────────────────────────
# Collects current full-file content for all files changed vs BASE_BRANCH.
# Binary files, deleted files, and files exceeding 800 lines are marked with
# a skip reason; the total char budget defaults to 40,000.
#
# Usage: compound_audit_collect_file_contents [max_chars=40000]
# Output: Multi-file fenced block with real newlines, or empty string.
compound_audit_collect_file_contents() {
    local max_chars="${1:-40000}"
    local base="${BASE_BRANCH:-main}"
    local total_chars=0
    local nl=$'\n'
    local output=""

    # --no-renames: ensures renamed files appear as delete+add pairs so the
    # path field is a single real path (not "old => new" syntax that breaks
    # every downstream git show / cat).
    local numstat
    numstat=$(git diff --no-renames --numstat "${base}...HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null | _filter_gitignored_paths) || return 0
    [[ -z "$numstat" ]] && return 0

    local added deleted file
    while IFS=$'\t' read -r added deleted file; do
        [[ -z "$file" ]] && continue

        # Binary files have "-" for both counts in numstat.
        if [[ "$added" == "-" && "$deleted" == "-" ]]; then
            output="${output}### ${file} (binary — skipped)${nl}${nl}"
            continue
        fi

        # Deleted: absent from worktree AND absent from HEAD tree.
        if [[ ! -e "$file" ]] && ! git cat-file -e "HEAD:${file}" 2>/dev/null; then
            output="${output}### ${file} (deleted)${nl}${nl}"
            continue
        fi

        # Prefer HEAD content (authoritative post-commit state); fall back to
        # worktree for edge cases like staged-but-uncommitted files.
        local content=""
        content=$(git show "HEAD:${file}" 2>/dev/null) || content=$(cat "$file" 2>/dev/null) || {
            output="${output}### ${file} (unreadable — skipped)${nl}${nl}"
            continue
        }

        local line_count
        line_count=$(printf '%s' "$content" | wc -l | tr -d ' ')
        line_count=${line_count:-0}

        if [[ "$line_count" -gt 800 ]]; then
            output="${output}### ${file} (${line_count} lines — skipped: exceeds 800-line limit)${nl}${nl}"
            continue
        fi

        local content_len="${#content}"
        if [[ $((total_chars + content_len)) -gt "$max_chars" ]]; then
            output="${output}### ${file} (${line_count} lines — skipped: char budget exhausted at ${max_chars})${nl}${nl}"
            continue
        fi

        total_chars=$((total_chars + content_len))
        output="${output}### ${file} (${line_count} lines)${nl}\`\`\`${nl}${content}${nl}\`\`\`${nl}${nl}"
    done <<< "$numstat"

    printf '%s' "$output"
}

# ─── compound_audit_escalate ──────────────────────────────────────────────
# Scans findings for trigger keywords, returns space-separated specialist list.
#
# Usage: compound_audit_escalate "$findings_json_array"
# Output: Space-separated specialist names (e.g., "security error_handling")
compound_audit_escalate() {
    local findings="$1"

    [[ -z "$findings" || "$findings" == "[]" ]] && return 0

    # Flatten all finding text for keyword scanning
    local all_text
    all_text=$(echo "$findings" | jq -r '.[] | .description + " " + .evidence + " " + .file' 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 0

    local specialists=""
    local spec
    for spec in security error_handling performance edge_case; do
        local varname="_COMPOUND_TRIGGERS_${spec}"
        local pattern="${!varname:-}"
        if [[ -n "$pattern" ]] && echo "$all_text" | grep -qEi "$pattern" 2>/dev/null; then
            specialists="${specialists:+${specialists} }${spec}"
        fi
    done

    echo "$specialists"
}

# ─── compound_audit_converged ─────────────────────────────────────────────
# Checks stop conditions for the cascade loop.
#
# Usage: compound_audit_converged "$new_findings" "$all_prev_findings" $cycle $max_cycles
# Output: Reason string if converged ("no_criticals", "dup_rate", "max_cycles"), empty if not
compound_audit_converged() {
    local new_findings="$1"
    local prev_findings="$2"
    local cycle="$3"
    local max_cycles="$4"

    # Hard cap: max cycles reached
    if [[ "$cycle" -ge "$max_cycles" ]]; then
        echo "max_cycles"
        return 0
    fi

    # No findings at all = converged
    local new_count
    new_count=$(echo "$new_findings" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$new_count" -eq 0 ]]; then
        echo "no_criticals"
        return 0
    fi

    # Check for critical/high in new findings
    local crit_high_count
    crit_high_count=$(echo "$new_findings" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")

    # If previous findings exist, check duplicate rate via structural match
    local prev_count
    prev_count=$(echo "$prev_findings" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$prev_count" -gt 0 && "$new_count" -gt 0 ]]; then
        # Count how many new findings structurally match previous ones
        local dup_count=0
        local i=0
        while [[ "$i" -lt "$new_count" ]]; do
            local nf nc nl
            nf=$(echo "$new_findings" | jq -r ".[$i].file // \"\"" 2>/dev/null)
            nc=$(echo "$new_findings" | jq -r ".[$i].category // \"\"" 2>/dev/null)
            nl=$(echo "$new_findings" | jq -r ".[$i].line // 0" 2>/dev/null)

            # Check if any previous finding matches file+category+nearby line
            local match
            match=$(echo "$prev_findings" | jq --arg f "$nf" --arg c "$nc" --argjson l "$nl" \
                '[.[] | select(.file == $f and .category == $c and ((.line // 0) - $l | fabs) <= 5)] | length' 2>/dev/null || echo "0")
            [[ "$match" -gt 0 ]] && dup_count=$((dup_count + 1))
            i=$((i + 1))
        done

        # If all findings are duplicates, converged
        if [[ "$dup_count" -eq "$new_count" ]]; then
            echo "dup_rate"
            return 0
        fi
    fi

    # No critical/high = converged
    if [[ "$crit_high_count" -eq 0 ]]; then
        echo "no_criticals"
        return 0
    fi

    # Not converged
    echo ""
    return 0
}

# ─── compound_audit_run_cycle ─────────────────────────────────────────────
# Runs multiple agents in parallel and collects their findings.
#
# Usage: compound_audit_run_cycle "logic integration completeness" "$diff" "$plan" "$prev_findings" $cycle "$test_evidence" "$file_contents"
# Output: Merged JSON array of all findings
compound_audit_run_cycle() {
    local agents="$1"
    local diff="$2"
    local plan_summary="$3"
    local prev_findings="$4"
    local cycle="$5"
    local test_evidence="${6:-}"
    local file_contents="${7:-}"

    local model="${COMPOUND_AUDIT_MODEL:-haiku}"
    local temp_dir
    temp_dir=$(mktemp -d) || return 0

    # Emit cycle start event
    type audit_emit >/dev/null 2>&1 && \
        audit_emit "compound.cycle_start" "cycle=$cycle" "agents=$agents" || true

    # Launch agents in parallel
    local pids=()
    local agent
    for agent in $agents; do
        local prompt
        prompt=$(compound_audit_build_prompt "$agent" "$diff" "$plan_summary" "$prev_findings" "$test_evidence" "$file_contents")

        (
            local output
            output=$(echo "$prompt" | claude -p --model "$model" 2>/dev/null) || output='{"findings":[]}'
            echo "$output" > "$temp_dir/${agent}.json"
        ) 2>/dev/null &
        pids+=($!)
    done

    # Wait for all agents
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Tag findings with the commit at which they were discovered
    local current_commit=""
    current_commit=$(git rev-parse HEAD 2>/dev/null) || current_commit=""

    # Merge findings from all agents
    local all_findings="[]"
    for agent in $agents; do
        local agent_file="$temp_dir/${agent}.json"
        if [[ -f "$agent_file" ]]; then
            local agent_findings
            agent_findings=$(compound_audit_parse_findings "$(cat "$agent_file")")

            # Layer 2: drop LLM-hallucinated "missing symbol" findings before
            # stamping, emitting, or merging into the accumulated set. (#342)
            agent_findings=$(compound_audit_verify_findings "$agent_findings") || true

            # Stamp each finding with the commit it was discovered at
            if [[ -n "$current_commit" ]]; then
                agent_findings=$(echo "$agent_findings" | jq --arg c "$current_commit" '[.[] | . + {created_at_commit: $c}]' 2>/dev/null) || true
            fi

            # Emit individual findings as audit events
            local i=0
            local fc
            fc=$(echo "$agent_findings" | jq 'length' 2>/dev/null || echo "0")
            while [[ "$i" -lt "$fc" ]]; do
                local sev desc file line
                sev=$(echo "$agent_findings" | jq -r ".[$i].severity" 2>/dev/null)
                desc=$(echo "$agent_findings" | jq -r ".[$i].description" 2>/dev/null)
                file=$(echo "$agent_findings" | jq -r ".[$i].file" 2>/dev/null)
                line=$(echo "$agent_findings" | jq -r ".[$i].line" 2>/dev/null)
                type audit_emit >/dev/null 2>&1 && \
                    audit_emit "compound.finding" "cycle=$cycle" "agent=$agent" \
                        "severity=$sev" "file=$file" "line=$line" "description=$desc" || true
                i=$((i + 1))
            done

            # Merge into all_findings
            all_findings=$(echo "$all_findings" "$agent_findings" | jq -s '.[0] + .[1]' 2>/dev/null || echo "$all_findings")
        fi
    done

    # Cleanup
    rm -rf "$temp_dir" 2>/dev/null || true

    echo "$all_findings"
}
