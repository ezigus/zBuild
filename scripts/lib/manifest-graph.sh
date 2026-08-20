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
    # gh_comments: ADR-055 §3 (#1768, first consumer #1729).
    echo "gh_issue_body gh_issue_view gh_comments goal_string scope_paths working_tree git_branch"
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

# ─── manifest_graph_output_format <manifest> <output_id> ─────────────────────
# The declared `format:` of one output — how to CHECK the artifact, as distinct
# from `type:`, which is WHAT artifact it is (#1895). Empty when undeclared.
#
# A dedicated accessor rather than a sixth field on the shared record, and the
# reason is load-bearing: input-resolve.sh reads an output's path as
# `${rec##*|}` — the LAST field — so appending anything would silently hand it
# the format instead of the path and break resolution everywhere, with no error.
# cycle-orchestrator.sh and plugin-primary-output-atomic-test.sh unpack five
# named vars and would mis-bind the same way. The record shape is load-bearing
# in a way its arity does not advertise.
manifest_graph_output_format() {
    local manifest="${1-}" want="${2-}"
    [[ -f "$manifest" && -n "$want" ]] || return 0
    awk -v want="$want" '
        /^outputs:[[:space:]]*$/ { inb = 1; next }
        /^[a-zA-Z_]/             { inb = 0 }
        inb && /^[[:space:]]+-[[:space:]]+id:[[:space:]]*/ {
            l = $0; sub(/^[[:space:]]+-[[:space:]]+id:[[:space:]]*/, "", l)
            gsub(/["\047]/, "", l); cur = l; next
        }
        inb && cur == want && /^[[:space:]]+format:[[:space:]]*/ {
            l = $0; sub(/^[[:space:]]+format:[[:space:]]*/, "", l)
            gsub(/["\047]/, "", l); print l; exit
        }
    ' "$manifest" 2>/dev/null || true
}

# ─── manifest_graph_formats ──────────────────────────────────────────────────
# The closed set (#1895/#1894). A format names how the engine checks an artifact
# for damage, so it must be a vocabulary the engine implements, not free text.
manifest_graph_formats() { printf 'json markdown text patch'; }

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

# yaml_get lives in core/plugin-registry/manifest-validation.sh (a leaf lib that
# sources nothing). The two roster helpers below need it to read provides.role /
# provides.artifact_type. Source lazily + guarded so existing manifest-graph
# consumers (lint-contract, contract-validator) keep their current load shape.
_manifest_graph_ensure_yaml_get() {
    declare -F yaml_get >/dev/null 2>&1 && return 0
    # shellcheck source=../../core/plugin-registry/manifest-validation.sh
    source "$_ZBUILD_MGRAPH_ROOT/core/plugin-registry/manifest-validation.sh" 2>/dev/null || true
    declare -F yaml_get >/dev/null 2>&1
}

# ─── manifest_graph_resolve_member <plugins_root> <member> ─────────────────────
# Resolve a cycle/parallel member stage id to its plugin manifest path — the
# SHARED roster-resolution primitive used by both the gate-aggregator (ADR-040
# §2) and the cycle engine's generic member-disposition contract (ADR-021). Two
# strategies, in order:
#   1) id-match (manifest_graph_collect) — most members' ids match their manifest.
#   2) role binding — a template may name a member by an id that binds BY ROLE
#      to a differently-named plugin. Read the member's first declared role from
#      _TPL_STAGE_ROLES_<safe> (exported by template.sh) and find the manifest
#      whose provides.role matches.
# Echoes the manifest path; rc 1 if unresolved.
manifest_graph_resolve_member() {
    local plugins_root="$1" member="$2" m
    m="$(manifest_graph_collect "$plugins_root" "$member" 2>/dev/null)"
    if [[ -n "$m" && -f "$m" ]]; then printf '%s\n' "$m"; return 0; fi
    _manifest_graph_ensure_yaml_get || return 1
    local safe="${member//-/_}" roles_var roles role cand r
    roles_var="_TPL_STAGE_ROLES_${safe}"
    roles="${!roles_var:-}"
    role="${roles%%,*}"            # first declared role
    [[ -z "$role" ]] && return 1
    while IFS= read -r -d '' cand; do
        r="$(yaml_get "$cand" "provides.role" 2>/dev/null)"
        if [[ "$r" == "$role" ]]; then printf '%s\n' "$cand"; return 0; fi
    done < <(find "$plugins_root" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)
    return 1
}

# ─── manifest_graph_result_filename <manifest> ─────────────────────────────────
# The member's recorded result artifact FILENAME: provides.artifact_type, else
# the basename of the primary output's declared path. rc 1 if neither resolves.
manifest_graph_result_filename() {
    local manifest="$1" at row path
    _manifest_graph_ensure_yaml_get
    at="$(yaml_get "$manifest" "provides.artifact_type" 2>/dev/null)"
    if [[ -n "$at" ]]; then printf '%s\n' "$at"; return 0; fi
    row="$(manifest_graph_primary_output "$manifest" 2>/dev/null)" || return 1
    path="${row##*|}"
    [[ -z "$path" ]] && return 1
    printf '%s\n' "${path##*/}"
}

# ─── manifest_graph_capability_field <manifest> <cap_name> <field_name> ────────
# Read a scalar from capabilities.<cap_name>.<field_name> in a manifest. Echoes
# the value; rc 1 if absent or file unreadable. Handles 3-level YAML nesting:
#   capabilities:
#     <cap_name>:
#       <field_name>: <value>
manifest_graph_capability_field() {
    local manifest="$1" cap="$2" field="$3"
    [[ -f "$manifest" ]] || return 1
    local val
    val="$(awk -v cap="$cap" -v field="$field" '
        /^capabilities:[[:space:]]*$/ { in_caps=1; next }
        in_caps && /^[a-zA-Z_]/ { in_caps=0; in_cap=0 }
        in_caps && $0 ~ "^[[:space:]]+"cap":[[:space:]]*$" { in_cap=1; next }
        in_cap && /^[[:space:]]{2,}[a-zA-Z_]/ && !($0 ~ "^[[:space:]]{4,}") { in_cap=0 }
        in_cap && $0 ~ "^[[:space:]]+"field":[[:space:]]*" {
            sub(/^[^:]+:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            gsub(/[[:space:]]*$/, "")
            print; exit
        }
    ' "$manifest" 2>/dev/null)"
    [[ -n "$val" ]] || return 1
    printf '%s\n' "$val"
}
