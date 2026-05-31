#!/usr/bin/env bash
# scripts/lib/manifest-graph.sh — ADR-020 shared manifest graph parser (issue #496).
#
# Single parser used by BOTH:
#   - core/pipeline/contract-validator.sh — runtime pre-flight check
#   - scripts/lib/lint-contract.sh        — CI lint
#
# A meta-test (tests/unit/preflight-lint-parity-test.sh) asserts that both
# callers see the same view of any given manifest set; if they ever drift,
# that test fails.
#
# Functions:
#   manifest_graph_external_allowlist           → echo space-delimited allowlist
#   manifest_graph_canonical_vars               → echo space-delimited allowed ${vars}
#   manifest_graph_get_stage_id <manifest>      → echo manifest's top-level id:
#   manifest_graph_get_inputs <manifest>        → newline-delim "id|type|source|required|path"
#   manifest_graph_get_outputs <manifest>       → newline-delim "id|type|required|path"
#   manifest_graph_inputs_block_present <m>     → rc 0 if `inputs:` key present
#   manifest_graph_outputs_block_present <m>    → rc 0 if `outputs:` key present
#   manifest_graph_probe_sentinel <manifest>    → rc 0 if manifest is parseable
#                                                  (distinguishes absent vs unparseable;
#                                                   reads top-level `id:` as sentinel)
#   manifest_graph_collect <plugins_root> <stage_id> [out_var]
#                                                → echoes ABSOLUTE path of the
#                                                  first manifest whose id == stage_id;
#                                                  rc 1 if none.
#
# Bash 5+. Sourced library; do not add `set -euo pipefail`.

[[ -n "${_ZBUILD_MANIFEST_GRAPH_LOADED:-}" ]] && return 0
_ZBUILD_MANIFEST_GRAPH_LOADED=1

_ZBUILD_MGRAPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_MGRAPH_ROOT="$(cd "$_ZBUILD_MGRAPH_DIR/.." && pwd)"
# Climb one more level if we're under scripts/lib (the canonical install).
if [[ -d "$_ZBUILD_MGRAPH_ROOT/scripts/lib" ]]; then
    : # already at repo root
else
    _ZBUILD_MGRAPH_ROOT="$(cd "$_ZBUILD_MGRAPH_DIR/../.." && pwd)"
fi

# ─── ADR-020 external sources allowlist (decision #6) ──────────────────────────
# Inputs declared `source: external` must use an id from this set. The list
# is hardcoded here and mirrored in ADR-020 §External Sources Allowlist; CI
# lint cross-references both to prevent drift.
manifest_graph_external_allowlist() {
    echo "gh_issue_body gh_issue_view goal_string scope_paths working_tree git_branch"
}

# ─── ADR-020 closed templating var set (decision #5) ──────────────────────────
# `cycle_feedback_dir` added by #511 (F2): resolves to $ZBUILD_CYCLE_FEEDBACK_DIR
# at expansion time. Only valid on inputs declared `source: cycle_feedback` —
# enforced by lint/validator (cycle_feedback_dir_in_artifact_path rule).
manifest_graph_canonical_vars() {
    echo "state_dir artifact_dir stage_io_dir run_id cycle_feedback_dir"
}

# ─── ADR-020 amendment (#511): cycle_feedback as input source ────────────────
# Returns 0 if source value is the cycle-feedback discriminator.
manifest_graph_is_cycle_feedback_source() {
    [[ "${1:-}" == "cycle_feedback" ]]
}

# ─── Sentinel probe — distinguishes absent vs. unparseable (decision #4 HIGH) ──
# Reads the top-level `id:` field. Returns 0 if the manifest file exists AND
# contains a non-empty top-level id; 1 if the file is missing; 2 if present
# but missing/empty id (treated as unparseable for our purposes).
manifest_graph_probe_sentinel() {
    local manifest="$1"
    [[ ! -f "$manifest" ]] && return 1
    local id
    id="$(awk '
        /^id:[[:space:]]*/ {
            sub(/^id:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            if ($0 != "") { print; exit }
        }
    ' "$manifest" 2>/dev/null)"
    [[ -z "$id" ]] && return 2
    return 0
}

# ─── manifest_graph_get_stage_id ───────────────────────────────────────────────
manifest_graph_get_stage_id() {
    local manifest="$1"
    awk '
        /^id:[[:space:]]*/ {
            sub(/^id:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
    ' "$manifest" 2>/dev/null
}

# ─── manifest_graph_inputs_block_present ───────────────────────────────────────
# Returns 0 if the manifest contains an `inputs:` top-level key.
# Used by the validator to distinguish "no inputs declared" (legacy/incomplete
# manifest) from "explicit zero inputs" (`inputs: []`). Per decision #1, an
# absent inputs block is malformed; zero-input plugins MUST declare `inputs: []`.
manifest_graph_inputs_block_present() {
    local manifest="$1"
    grep -qE '^inputs:[[:space:]]*(\[\]|$)' "$manifest" 2>/dev/null
}

manifest_graph_outputs_block_present() {
    local manifest="$1"
    grep -qE '^outputs:[[:space:]]*(\[\]|$)' "$manifest" 2>/dev/null
}

# ─── _mgraph_parse_block — shared awk for inputs: / outputs: ──────────────────
# Emits newline-delimited records: "id|type|source|required|path".
# Used by both manifest_graph_get_inputs and manifest_graph_get_outputs.
_mgraph_parse_block() {
    local manifest="$1"
    local block="$2"   # "inputs" | "outputs"
    awk -v block="$block" '
        BEGIN {
            cur_id = ""; cur_type = ""; cur_source = ""; cur_required = ""; cur_path = ""
            in_block = 0
            flush_pending = 0
        }
        function flush() {
            if (cur_id != "") {
                print cur_id "|" cur_type "|" cur_source "|" cur_required "|" cur_path
            }
            cur_id = ""; cur_type = ""; cur_source = ""; cur_required = ""; cur_path = ""
        }
        # Enter the block on top-level "inputs:" or "outputs:"
        $0 ~ "^"block":[[:space:]]*$" { in_block = 1; next }
        # Inline empty list "inputs: []" — no entries; nothing to emit
        $0 ~ "^"block":[[:space:]]*\\[\\][[:space:]]*$" { exit }
        # Any new top-level key ends the block
        in_block && /^[a-zA-Z_]/ { flush(); exit }
        # New list item: "  - id: foo"
        in_block && /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
            flush()
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_id = line
            next
        }
        # Continuation properties (indented siblings of id:)
        in_block && cur_id != "" && /^[[:space:]]+type:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+type:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_type = line; next
        }
        in_block && cur_id != "" && /^[[:space:]]+source:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+source:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_source = line; next
        }
        in_block && cur_id != "" && /^[[:space:]]+required:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+required:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_required = line; next
        }
        in_block && cur_id != "" && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_path = line; next
        }
        END { flush() }
    ' "$manifest" 2>/dev/null
}

manifest_graph_get_inputs() {
    _mgraph_parse_block "$1" "inputs"
}

manifest_graph_get_outputs() {
    _mgraph_parse_block "$1" "outputs"
}

# ─── manifest_graph_primary_output <manifest> ──────────────────────────────────
# Echoes the FIRST outputs[] row marked `primary: true` in the same
# pipe-delimited shape as manifest_graph_get_outputs:
#   id|type|source|required|path
# Empty stdout (rc 1) if no row is marked primary. ADR-020 amendment (#507)
# requires exactly-one primary per manifest; the lint asserts the constraint.
manifest_graph_primary_output() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 1
    local row
    row="$(awk '
        BEGIN { in_out=0; cur_id=""; cur_type=""; cur_required=""; cur_path=""; cur_primary=""; emitted=0 }
        function flush() {
            if (cur_primary == "true" && cur_id != "" && emitted == 0) {
                # outputs do not have a source column; keep position for parity.
                print cur_id "|" cur_type "||" cur_required "|" cur_path
                emitted=1
            }
            cur_id=""; cur_type=""; cur_required=""; cur_path=""; cur_primary=""
        }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { flush(); in_out=0 }
        in_out && /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
            flush()
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_id=line; next
        }
        in_out && cur_id != "" && /^[[:space:]]+type:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]+type:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_type=line; next
        }
        in_out && cur_id != "" && /^[[:space:]]+required:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]+required:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_required=line; next
        }
        in_out && cur_id != "" && /^[[:space:]]+path:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_path=line; next
        }
        in_out && cur_id != "" && /^[[:space:]]+primary:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]+primary:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_primary=line; next
        }
        END { flush() }
    ' "$manifest" 2>/dev/null)"
    if [[ -z "$row" ]]; then
        return 1
    fi
    printf '%s\n' "$row"
    return 0
}

# ─── manifest_graph_collect <plugins_root> <stage_id> ──────────────────────────
# Find the first manifest in plugins_root whose top-level id == stage_id.
# Echoes the absolute path; rc 1 if not found.
manifest_graph_collect() {
    local plugins_root="$1" stage_id="$2"
    local m
    while IFS= read -r -d '' m; do
        local id
        id="$(manifest_graph_get_stage_id "$m")"
        if [[ "$id" == "$stage_id" ]]; then
            printf '%s\n' "$m"
            return 0
        fi
    done < <(find "$plugins_root" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)
    return 1
}
