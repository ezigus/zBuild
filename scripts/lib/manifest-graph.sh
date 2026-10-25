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

_ZBUILD_MGRAPH_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_ZBUILD_MGRAPH_ROOT="$(cd "$_ZBUILD_MGRAPH_DIR/.." && pwd)"
# Climb one more level if we're under scripts/lib (the canonical install).
if [[ -d "$_ZBUILD_MGRAPH_ROOT/scripts/lib" ]]; then
    : # already at repo root
else
    _ZBUILD_MGRAPH_ROOT="$(cd "$_ZBUILD_MGRAPH_DIR/../.." && pwd)"
fi

# ─── ADR-020 closed templating var set (decision #5) ──────────────────────────
# `cycle_feedback_dir` is retired (ADR-068 §8): the engine writes no feedback
# copy, so there is nothing for it to name.
manifest_graph_canonical_vars() {
    echo "state_dir artifact_dir stage_io_dir run_id"
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
# The first `id:` line, cleaned: leading spaces, a trailing `# comment` with
# the spaces before it, then one leading and one trailing quote. Read by the
# shell — it runs on every memo hit (ADR-065 §5); tests/unit/
# stage-dispatch-cost-test.sh D6 holds it to the awk reader it replaced.
manifest_graph_get_stage_id() {
    local _mgid
    _mgraph_stage_id_v _mgid "$1" || return 0
    printf '%s\n' "$_mgid"
}
_mgraph_stage_id_v() {   # <var> <manifest> — rc 1 when there is no id: line
    local -n _msi_out="$1"; _msi_out=""
    local _l _v
    [[ -f "$2" && -r "$2" ]] || return 1
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        [[ "$_l" == id:* ]] || continue
        _v="${_l#id:}"
        _v="${_v#"${_v%%[![:space:]]*}"}"
        if [[ "$_v" == *#* ]]; then
            _v="${_v%%#*}"
            _v="${_v%"${_v##*[![:space:]]}"}"
        fi
        _v="${_v#[\"\']}"; _v="${_v%[\"\']}"
        _msi_out="$_v"
        return 0
    done < "$2"
    return 1
}

manifest_graph_outputs_block_present() {
    local manifest="$1"
    grep -qE '^outputs:[[:space:]]*(\[\]|$)' "$manifest" 2>/dev/null
}

# ─── shell readers for the outputs/inputs block (ADR-065 §5) ─────────────────
# These replaced awk programs line for line; tests/unit/
# manifest-output-readers-test.sh R2 holds them to those programs' output.
# _mg_strip_lead_v / _mg_strip_trail_v <var> — remove leading / trailing spaces.
_mg_strip_lead_v()  { local -n _sl="$1"; _sl="${_sl#"${_sl%%[![:space:]]*}"}"; }
_mg_strip_trail_v() { local -n _st="$1"; _st="${_st%"${_st##*[![:space:]]}"}"; }
# _mg_clean_v <var> — the value after its key: a trailing `# comment` and the
# spaces before it, one leading and one trailing quote, then trailing spaces.
_mg_clean_v() {
    local -n _cv="$1"
    if [[ "$_cv" == *#* ]]; then _cv="${_cv%%#*}"; _mg_strip_trail_v "$1"; fi
    _cv="${_cv#[\"\']}"; _cv="${_cv%[\"\']}"
    _mg_strip_trail_v "$1"
}

# ─── _mgraph_parse_block — shared awk for inputs: / outputs: ──────────────────
# Emits newline-delimited records: "id|type|source|required|path".
# Used by both manifest_graph_get_inputs and manifest_graph_get_outputs.
_mgraph_parse_block() {
    local manifest="$1"
    local block="$2"   # "inputs" | "outputs"
    [[ -f "$manifest" && -r "$manifest" ]] || return 0
    local l v in_block=0 cid="" ctype="" csrc="" creq="" cpath=""
    local re_open="^${block}:[[:space:]]*\$" re_empty="^${block}:[[:space:]]*\\[\\][[:space:]]*\$"
    local re_top='^[a-zA-Z_]' re_id='^[[:space:]]*-[[:space:]]*id:'
    local re_prop='^[[:space:]]+(type|source|required|path):'
    _mgpb_flush() {
        [[ -n "$cid" ]] && printf '%s|%s|%s|%s|%s\n' "$cid" "$ctype" "$csrc" "$creq" "$cpath"
        cid=""; ctype=""; csrc=""; creq=""; cpath=""
    }
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ "$l" =~ $re_open ]] && { in_block=1; continue; }
        [[ "$l" =~ $re_empty ]] && break
        (( in_block )) || continue
        [[ "$l" =~ $re_top ]] && break
        if [[ "$l" =~ $re_id ]]; then
            _mgpb_flush
            v="${l#*id:}"; _mg_strip_lead_v v; _mg_clean_v v
            cid="$v"; continue
        fi
        if [[ -n "$cid" && "$l" =~ $re_prop ]]; then
            v="${l#*:}"; _mg_strip_lead_v v; _mg_clean_v v
            case "${BASH_REMATCH[1]}" in
                type) ctype="$v" ;; source) csrc="$v" ;; required) creq="$v" ;; path) cpath="$v" ;;
            esac
        fi
    done 2>/dev/null < "$manifest"
    _mgpb_flush
    unset -f _mgpb_flush
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
manifest_graph_output_format() { _mgraph_output_field "${1-}" "${2-}" format; }

# ─── _mgraph_output_bool <manifest> <output_id> <field> ─────────────────────
# Shared reader for the boolean markers on an output entry. `terminal` and
# `advisory` were retired with the unconsumed check (#1980); `summary` (#1976)
# is the one that remains. A dedicated accessor per marker rather than extra fields on the
# five-field pipe record: appending to that record would silently break callers
# that unpack by position (see _mgraph_parse_block above).
_mgraph_output_bool() { _mgraph_output_field "${1-}" "${2-}" "${3-}"; }

# _mgraph_output_field <manifest> <output_id> <field> — one field of one output
# entry, read by the shell. The entry's id keeps any `# comment` and loses every
# quote; the field loses its comment, trailing spaces and every quote.
_mgraph_output_field() {
    local manifest="${1-}" want="${2-}" field="${3-}"
    [[ -f "$manifest" && -r "$manifest" && -n "$want" && -n "$field" ]] || return 0
    local l v cur="" inb=0
    local re_open='^outputs:[[:space:]]*$' re_top='^[a-zA-Z_]'
    local re_id='^[[:space:]]+-[[:space:]]+id:' re_f="^[[:space:]]+${field}:"
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ "$l" =~ $re_open ]] && { inb=1; continue; }
        [[ "$l" =~ $re_top ]] && inb=0
        (( inb )) || continue
        if [[ "$l" =~ $re_id ]]; then
            v="${l#*id:}"; _mg_strip_lead_v v; _mg_strip_trail_v v
            v="${v//[\"\']/}"; cur="$v"; continue
        fi
        if [[ "$cur" == "$want" && "$l" =~ $re_f ]]; then
            v="${l#*"${field}":}"; _mg_strip_lead_v v
            if [[ "$v" == *#* ]]; then v="${v%%#*}"; fi
            _mg_strip_trail_v v
            printf '%s\n' "${v//[\"\']/}"
            return 0
        fi
    done 2>/dev/null < "$manifest"
    return 0
}

# ─── manifest_graph_output_summary <manifest> <output_id> ────────────────────
# Returns 'true' if the output entry is marked `summary: true` (#1976) — the ONE
# output a stage offers downstream as ambient prompt context. Distinct from
# `inputs:`, which stay required, resolved and programmatic (ADR-055 amendment).
manifest_graph_output_summary() { _mgraph_output_bool "${1-}" "${2-}" summary; }

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
# #2129: memoised per (root, stage). Every consumer of a stage's manifest — the
# pre-iter cleanup, the summaries collector, the aggregator roster, feedback
# resolution — walked plugins/ again: ~36 sweeps ≈ 1.3s per cycle iteration.
# Nearly every caller runs this in a `$( )` capture, where a shell variable
# dies with the subshell, so the memo is a FILE under the run's state dir
# (`$ZBUILD_STATE_DIR/runtime/mgraph-memo/`) when one is set, and an in-shell
# array otherwise. A hit is re-validated against the manifest on disk (still
# present, still that id: one read, no walk); a miss is never memoised, because
# test fixtures are created after the first lookup.
declare -gA _MGRAPH_COLLECT_MEMO 2>/dev/null || true
_mgraph_memo_file() { local _mmf; _mgraph_memo_file_v _mmf "$@" || return 1; printf '%s' "$_mmf"; }
# The name is the root and stage made filename-safe by the shell (it was a
# `printf | cksum` in a subshell on every lookup). A name cut to fit can only
# make two roots share a file, and a hit is used only when it lies under the
# root asked about and still carries the stage's id.
_mgraph_memo_file_v() {   # <var> <root> <stage>
    [[ -n "${ZBUILD_STATE_DIR:-}" ]] || return 1
    local _mmfv_k="${2//[^A-Za-z0-9._-]/_}"
    (( ${#_mmfv_k} > 150 )) && _mmfv_k="${_mmfv_k: -150}"
    printf -v "$1" '%s/runtime/mgraph-memo/%s-%s' "$ZBUILD_STATE_DIR" "$_mmfv_k" "$3"
}
manifest_graph_collect() {
    local plugins_root="$1" stage_id="$2"
    local m key="${plugins_root}|${stage_id}" mf=""
    _mgraph_memo_file_v mf "$plugins_root" "$stage_id" || mf=""
    m="${_MGRAPH_COLLECT_MEMO[$key]:-}"
    [[ -z "$m" && -n "$mf" && -f "$mf" ]] && { IFS= read -r m < "$mf" || true; } 2>/dev/null
    if [[ -n "$m" ]]; then
        local _mid=""
        [[ -f "$m" ]] && _mgraph_stage_id_v _mid "$m"
        if [[ "$m" == "${plugins_root%/}"/* && -f "$m" && "$_mid" == "$stage_id" ]]; then
            _MGRAPH_COLLECT_MEMO[$key]="$m"
            printf '%s\n' "$m"
            return 0
        fi
        unset '_MGRAPH_COLLECT_MEMO[$key]'
        [[ -n "$mf" ]] && rm -f "$mf" 2>/dev/null
    fi
    # One awk reads every manifest's first `id:` line, cleaned as
    # manifest_graph_get_stage_id cleans it, and names the first file in find
    # order whose id matches (ADR-065 §4: one pass, not one per manifest).
    local -a files=()
    while IFS= read -r -d '' m; do files+=("$m"); done \
        < <(find "$plugins_root" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)
    (( ${#files[@]} > 0 )) || return 1
    m="$(awk -v want="$stage_id" '
        /^id:[[:space:]]*/ {
            v = $0
            sub(/^id:[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*/, "", v)
            gsub(/^["'"'"']|["'"'"']$/, "", v)
            if (v == want) { print FILENAME; exit }
            nextfile
        }
    ' "${files[@]}" 2>/dev/null)"
    [[ -n "$m" ]] || return 1
    _MGRAPH_COLLECT_MEMO[$key]="$m"
    if [[ -n "$mf" ]]; then
        mkdir -p "${mf%/*}" 2>/dev/null && printf '%s' "$m" > "$mf" 2>/dev/null || true
    fi
    printf '%s\n' "$m"
    return 0
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
# roster-resolution primitive used by the cycle engine's generic
# member-disposition contract (ADR-021). Two
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
    local safe="${member//-/_}" roles_var roles role cand
    roles_var="_TPL_STAGE_ROLES_${safe}"
    roles="${!roles_var:-}"
    role="${roles%%,*}"            # first declared role
    [[ -z "$role" ]] && return 1
    # One awk over every manifest (ADR-065 §4), reading provides.role by
    # yaml_get's nested-key rules: a `provides:` line opens the block, any
    # column-0 key closes it, the first indented `role:` in it is the value.
    local -a files=()
    while IFS= read -r -d '' cand; do files+=("$cand"); done \
        < <(find "$plugins_root" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)
    (( ${#files[@]} > 0 )) || return 1
    m="$(awk -v want="$role" '
        FNR == 1 { inb = 0 }
        /^provides:/ { inb = 1; next }
        inb && /^[a-zA-Z_]/ { inb = 0 }
        inb && /^[[:space:]]+role:/ {
            v = $0
            sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*/, "", v)
            gsub(/^["'"'"']|["'"'"']$/, "", v)
            if (v == want) { print FILENAME; exit }
            nextfile
        }
    ' "${files[@]}" 2>/dev/null)"
    [[ -n "$m" ]] || return 1
    printf '%s\n' "$m"
}

# ─── manifest_graph_result_filename <manifest> ─────────────────────────────────
# The member's recorded result artifact FILENAME: the basename of the primary
# output's declared path. rc 1 if it does not resolve.
#
# #1906: provides.artifact_type used to be consulted first. It was a TYPE name,
# not a filename, and three plugins proved the difference — intake declared a
# bracketed LIST that resolved as the literal "[scope-manifest.md, intake.md]",
# security-lens declared `findings.json` while writing security-findings.json,
# and output-github-comment named a file it never writes. A member whose result
# path does not exist is skipped by both callers' `[[ -s ]]` test, so a terminal
# member would go unnoticed. The primary output is the single declaration.
manifest_graph_result_filename() {
    local manifest="$1" row path
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
