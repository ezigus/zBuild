#!/usr/bin/env bash
# tests/unit/manifest-line-readers-test.sh — the manifest and template readers
# that ran awk on every dispatch read in the shell, and say what awk said
# (ADR-065 §5, round 7).
#
# Each ran in the stage's own process, so a memo died with it: ~550 awk in one
# three-run pipeline test. Each old awk program is kept below verbatim, and the
# new reader must give its exact output and status over every manifest and
# template in the repo plus an edge-case set (CRLF, tabs, comments, quotes, no
# final newline, a `- path:` on the dash line, nested router keys, ...).
#
# Q1 [guard]  each reader gives the old output and status, for every input
# Q2 [change] none of them starts a program
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-time-limit.sh
source "$REPO_ROOT/scripts/lib/stage-time-limit.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../core/plugin-registry/write-ownership.sh
source "$REPO_ROOT/core/plugin-registry/write-ownership.sh"
# shellcheck source=../../core/plugin-registry/attempt-archive.sh
source "$REPO_ROOT/core/plugin-registry/attempt-archive.sh"

print_test_header "manifest line readers: the shell, saying what awk said (ADR-065 §5)"
setup_test_env "manifest-line-readers"

# shellcheck disable=SC2016,SC1003  # the old readers, verbatim
# core/plugin-registry/manifest-router-budget.sh at main e77c1653, verbatim
_old_manifest_router_block() {
    local manifest="${1:-}"
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    awk -v knob="${2:-}" '
        function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
        # A trailing comment on the block header is legal YAML and is exactly
        # where a manifest explains WHY the numbers below it are what they are —
        # the reasoning this block exists to keep next to the value.
        /^config:[[:space:]]*(#.*)?$/ { in_cfg = 1; in_router = 0; next }
        # Any other column-0 key closes `config:` (and with it `router:`).
        in_cfg && /^[^[:space:]#]/ { in_cfg = 0; in_router = 0 }
        in_cfg && !in_router && /^[[:space:]]+router:[[:space:]]*(#.*)?$/ {
            in_router = 1; router_ind = indent($0); next
        }
        # A line at or shallower than `router:` ends the block; it may itself be
        # another config key, so this rule only clears the flag and falls through.
        # Comment-only lines are excluded exactly as they are for `config:`
        # above: a comment carries no indentation meaning, and treating one as a
        # block terminator would silently drop every knob declared after a
        # left-aligned comment (claude-review on PR #1870).
        in_router && /^[[:space:]]*[^[:space:]#]/ && indent($0) <= router_ind { in_router = 0 }
        in_router && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            key = line; sub(/:.*$/, "", key)
            val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
            sub(/[[:space:]]*#.*/, "", val)
            gsub(/^["'"'"']|["'"'"']$/, "", val)
            gsub(/[[:space:]]/, "", val)
            if (knob != "") { if (key == knob) { print val; exit }; next }
            printf "%s %s\n", key, val
        }
    ' "$manifest" 2>/dev/null
}

# core/pipeline/input-resolve.sh at main e77c1653, verbatim
_old_inputs_manifest_formats() {
    awk '
        function flush() { if (id != "") print id "\t" fmt; id = ""; fmt = "" }
        /^outputs:[[:space:]]*$/ { inb = 1; next }
        inb && /^[a-zA-Z_]/ { flush(); inb = 0 }
        inb && /^[[:space:]]*-[[:space:]]+id:[[:space:]]*/ {
            flush(); l = $0; sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", l)
            sub(/[[:space:]]*#.*/, "", l); gsub(/^["\047]|["\047]$/, "", l); id = l; next }
        inb && /^[[:space:]]+format:[[:space:]]*/ {
            l = $0; sub(/^[[:space:]]+format:[[:space:]]*/, "", l); sub(/[[:space:]]*#.*/, "", l)
            gsub(/^["\047]|["\047]$/, "", l); fmt = l }
        END { flush() }' "$1" 2>/dev/null
}

# core/plugin-registry/output-paths.sh at main e77c1653, verbatim
_old_registry_output_path_rows() {
    local manifest="$1"
    awk '
        BEGIN { in_block = 0; cur_path = ""; cur_required = ""; cur_primary = "" }
        function flush() {
            if (cur_path != "" && cur_required != "false") {
                print cur_path "\t" cur_primary
            }
            cur_path = ""; cur_required = ""; cur_primary = ""
        }
        /^outputs:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z_]/ { flush(); in_block = 0 }
        in_block && /^[[:space:]]*-[[:space:]]/ { flush() }
        in_block && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_path = line
            next
        }
        in_block && /^[[:space:]]+required:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+required:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_required = line
            next
        }
        in_block && /^[[:space:]]+primary:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+primary:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            # Case-folded: a manifest writing `primary: True` must not read as
            # non-primary and so slip past the empty-artifact guard downstream.
            # `required` is deliberately NOT folded — a non-canonical value there
            # already fails closed (treated as required).
            cur_primary = tolower(line)
            next
        }
        END { flush() }
    ' "$manifest" 2>/dev/null
}

# scripts/lib/stage-time-limit.sh at main e77c1653, verbatim
_old_template_stage_time_limit_read() {
    local stage_id="$1" v=""
    if [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]]; then
        v="$(awk -v stage="$stage_id" '
            function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
            $0 ~ "^"stage":[[:space:]]*$" { in_block = 1; block_ind = 0; in_defs = 0; next }
            /^stage_definitions:[[:space:]]*$/ { in_defs = 1; next }
            in_defs && /^[a-zA-Z_]/ { in_defs = 0 }
            in_defs && !in_block && $0 ~ "^  "stage":[[:space:]]*$" { in_block = 1; block_ind = 2; next }
            in_block {
                ind = indent($0)
                if ($0 ~ /[^[:space:]]/ && ind <= block_ind) { in_block = 0 }
            }
            in_block && indent($0) == block_ind + 2 && $0 ~ "^[[:space:]]+timeout_s:" {
                sub(/^[[:space:]]+timeout_s:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "")
                print; exit
            }
        ' "${_TPL_SOURCE_FILE}" 2>/dev/null)"
    fi
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || v=900
    printf '%s' "$v"
}

# scripts/lib/stage-prompt.sh at main e77c1653, verbatim
_old_sp_manifest_scalar() {
    local manifest="$1" block="$2" key="$3"
    [[ -f "$manifest" ]] || return 0
    awk -v b="$block" -v k="$key" '
        /^[^[:space:]#]/ { inblk = ($0 ~ "^" b ":[[:space:]]*(#.*)?$"); next }
        inblk && $0 ~ "^[[:space:]]+" k ":" {
            v = $0; sub("^[[:space:]]+" k ":[[:space:]]*", "", v); sub(/[[:space:]]*#.*/, "", v)
            gsub(/^["\047]|["\047]$/, "", v); print v; exit }' "$manifest" 2>/dev/null
}

# core/plugin-registry/write-ownership.sh at main e77c1653, verbatim
_old_lc_manifest_output_paths() {
    [[ -f "$1" ]] || return 0
    awk '/^outputs:/{o=1;next} /^[^[:space:]#]/{o=0}
         o && /^[[:space:]]+(-[[:space:]]+)?path:/ {
             v=$0; sub(/^[[:space:]]+(-[[:space:]]+)?path:[[:space:]]*/, "", v)
             gsub(/^["\047]|["\047][[:space:]]*$/, "", v); sub(/[[:space:]]+#.*$/, "", v); print v }' "$1"
}

# core/plugin-registry/manifest-validation.sh at main e77c1653, verbatim
_old_yaml_get_uncached() {
    local file="$1"
    local key="$2"
    if [[ "$key" == *.* ]]; then
        # Nested key like hooks.init: find "<parent>:" then indented "<child>:"
        local parent="${key%.*}"
        local child="${key#*.}"
        awk -v parent="$parent" -v child="$child" '
        $0 ~ "^"parent":" { in_block = 1; next }
        in_block && /^[a-zA-Z_]/ { in_block = 0 }
        in_block && $0 ~ "^[[:space:]]+"child":" {
            sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
        ' "$file" 2>/dev/null
    else
        # Top-level scalar
        awk -v key="$key" '
        $0 ~ "^"key":" {
            sub(/^[^:]+:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
        ' "$file" 2>/dev/null
    fi
}

# core/plugin-registry/attempt-archive.sh _attempt_manifest_facts_v's awk at main e77c1653, verbatim,
# plus #2443's X line (the result file, `primary: true`) in the same form as S
_old_attempt_facts() {
    awk '
        function flush() { if (p != "") { print "P\t" p; b = p; sub(/.*\//, "", b); if (s) print "S\t" b; if (x) print "X\t" b } p = ""; s = 0; x = 0 }
        /^outputs:[[:space:]]*$/      { in_out = 1; in_cap = 0; next }
        /^capabilities:[[:space:]]*$/ { flush(); in_cap = 1; in_out = 0; next }
        /^[a-zA-Z_]/                  { flush(); in_out = 0; in_cap = 0 }
        in_cap && /^[[:space:]]+writes_repository:[[:space:]]*true[[:space:]]*(#.*)?$/ { print "R" }
        in_out && /^[[:space:]]*-[[:space:]]+id:/ { flush() }
        in_out && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            p = line
        }
        in_out && /^[[:space:]]+summary:[[:space:]]*true/ { s = 1 }
        in_out && /^[[:space:]]+primary:[[:space:]]*true/ { x = 1 }
        END { flush() }
    ' "$1" 2>/dev/null
}

# ─── the inputs ──────────────────────────────────────────────────────────────
E="$TEST_TEMP_DIR/edge"; mkdir -p "$E"
printf 'id: crlf\r\nkind: agent\r\noutputs:\r\n  - id: a\r\n    path: ${artifact_dir}/a.json\r\n    format: json\r\n    primary: true\r\nconfig:\r\n  router:\r\n    timeout_s: 60\r\n' > "$E/crlf.yaml"
printf 'id: tabs\noutputs:\n\t- id: t\n\t  path: "${artifact_dir}/t.md"  # note\n\t  required: false\nconfig:\n\trouter:\n\t\tmax_turns: 9\n' > "$E/tabs.yaml"
printf 'id: "quoted" # c\nname: '"'"'Q'"'"'\nhooks:\n  run: q_run # trailing\n  init: "q_init"\noutputs:\n  - id: x # c\n    path: '"'"'${artifact_dir}/x.json'"'"'\n    primary: True\n    summary: true\n  - path: ${artifact_dir}/dash.json\n  - id: y\n    path: ${artifact_dir}/y "#" z.md\n    required: "false"\n    format: markdown # md\ncapabilities:\n  writes_repository: true # yes\nconfig:  # why\n  router:   # because\n# left comment\n    timeout_s: "120" # two min\n    retries: 2\n    nested:\n      deep: 1\n  other: 3\n    max_turns: 7\n' > "$E/quoted.yaml"
printf 'id: nofinal\noutputs:\n  - id: n\n    path: ${artifact_dir}/n.json' > "$E/nofinal.yaml"
printf 'id: empty-vals\nhooks:\n  run:\noutputs:\n  - id:\n    path:\nconfig:\n  router:\n    timeout_s:\n' > "$E/empty.yaml"
printf 'id: two\nrouter:\n  timeout_s: 5\nconfig:\n  router:\n    retry_on_exhaustion: 1\n    retry_on_exhaustion: 4\noutputs:\n  - id: d1\n    path: p1\n    path: p2\nid: dup\n' > "$E/dup.yaml"
: > "$E/zero.yaml"
# A key under a LATER block must not be read as the earlier block's, and a
# quoted id is still the id.
printf 'id: later\nhooks:\n  run: r\ncapabilities:\n  network: false\nother:\n  init: wrong\n  writes_repository: true\noutputs:\n  - id: "qid"\n    path: ${artifact_dir}/q.json\n    format: json\n' > "$E/later.yaml"
printf 'stages:\n  - build\n  - plan\nbuild:\n  timeout_s: 3600 # an hour\n  other:\n    timeout_s: 5\nplan:\n  gate: auto\n    timeout_s: 77\nstage_definitions:\n  review:\n    timeout_s:  1 2\n  design:\n    nested:\n      timeout_s: 9\n    timeout_s: 0042\n' > "$E/tpl.yaml"
printf 'stage_definitions:\r\n  build:\r\n    timeout_s: 300\r\n' > "$E/tpl-crlf.yaml"
MANIFESTS=()
while IFS= read -r _m; do MANIFESTS+=("$_m"); done < <(find "$REPO_ROOT/plugins" "$REPO_ROOT/tests" -name 'manifest*.yaml' -type f 2>/dev/null | sort)
MANIFESTS+=("$E"/*.yaml "$E/missing.yaml")
TEMPLATES=("$REPO_ROOT"/config/templates/*.yaml "$REPO_ROOT"/tests/fixtures/templates/*.yaml "$E/tpl.yaml" "$E/tpl-crlf.yaml" "$E/zero.yaml" "$E/missing.yaml")

# same <label> <old fn> <new fn> <args...>: output and status must match.
_DIFFS=0; _DIFF_SHOW=""; _CMPS=0
same() {
    local label="$1" old="$2" new="$3"; shift 3
    local o n orc nrc
    o="$("$old" "$@" 2>/dev/null; printf 'rc=%s' "$?")"
    n="$("$new" "$@" 2>/dev/null; printf 'rc=%s' "$?")"
    _CMPS=$((_CMPS + 1))
    if [[ "$o" != "$n" ]]; then
        _DIFFS=$((_DIFFS + 1))
        (( _DIFFS <= 5 )) && _DIFF_SHOW+="[$label $*] old=[${o//$'\n'/\\n}] new=[${n//$'\n'/\\n}]; "
    fi
}
_new_attempt_facts() { local f=""; _ATT_FACTS_FOR=""; _attempt_manifest_facts_v f "$1"; [[ -z "$f" ]] || printf '%s\n' "$f"; }
_old_attempt_facts_v() { local f; f="$(_old_attempt_facts "$1")"; [[ -z "$f" ]] || printf '%s\n' "$f"; }
# The new reader reads every stage in one pass (round 8); a fresh memo per call
# makes each comparison a fresh read of the file.
_tl_new() { local _TPL_SOURCE_FILE="$1" _tln; _ZB_STAGE_TL_MEMO=(); template_stage_time_limit_v _tln "$2"; printf '%s' "$_tln"; }
_tl_old() { _TPL_SOURCE_FILE="$1" _old_template_stage_time_limit_read "$2"; }

print_test_section "Q1: every reader, every input"
for _m in "${MANIFESTS[@]}"; do
    for _k in "" timeout_s max_turns retries retry_on_exhaustion deep bogus; do
        same router _old_manifest_router_block _manifest_router_block "$_m" "$_k"
    done
    same formats _old_inputs_manifest_formats _inputs_manifest_formats "$_m"
    same outrows _old_registry_output_path_rows _registry_output_path_rows "$_m"
    same ownpaths _old_lc_manifest_output_paths _lc_manifest_output_paths "$_m"
    same facts _old_attempt_facts_v _new_attempt_facts "$_m"
    for _bk in "capabilities writes_repository" "hooks run" "hooks init" "config check_rounds" \
               "config router" "router timeout_s" "persona id" "nope nope"; do
        # shellcheck disable=SC2086
        same scalar _old_sp_manifest_scalar _sp_manifest_scalar "$_m" $_bk
    done
    for _key in id kind name version persona hooks.run hooks.init config.check_rounds \
                capabilities.writes_repository config.router.timeout_s router.timeout_s nope outputs; do
        same yaml_get _old_yaml_get_uncached _yaml_get_uncached "$_m" "$_key"
    done
done
for _t in "${TEMPLATES[@]}"; do
    _stages="$(grep -oE '^ {0,2}[a-zA-Z_][a-zA-Z0-9_-]*:' "$_t" 2>/dev/null | tr -d ' :' | sort -u)"
    for _s in $_stages build plan review design nope; do
        same timelimit _tl_old _tl_new "$_t" "$_s"
    done
done
assert_eq "[Q1] $_CMPS comparisons, no difference" "0" "$_DIFFS" "$_DIFF_SHOW"

print_test_section "Q2: what they start"
CALLS="$TEST_TEMP_DIR/calls"
_PROGS=(awk sed grep cut tr head tail cat sort dirname basename)
_wrap()   { local c; for c in "${_PROGS[@]}"; do eval "$c() { printf '%s\\n' $c >> \"\$CALLS\"; command $c \"\$@\"; }"; done; }
_unwrap() { unset -f "${_PROGS[@]}"; }
M="$E/quoted.yaml"
: > "$CALLS"; _wrap
_manifest_router_block "$M" >/dev/null; _manifest_router_block "$M" timeout_s >/dev/null
_inputs_manifest_formats "$M" >/dev/null; _registry_output_path_rows "$M" >/dev/null
_lc_manifest_output_paths "$M" >/dev/null; _new_attempt_facts "$M" >/dev/null
_sp_manifest_scalar "$M" capabilities writes_repository >/dev/null
_yaml_get_uncached "$M" hooks.run >/dev/null; _yaml_get_uncached "$M" id >/dev/null
_tl_new "$E/tpl.yaml" build >/dev/null
_unwrap
assert_eq "[Q2] the eight readers start nothing" "" "$(sort "$CALLS" | uniq -c | tr -s ' ' | tr '\n' ';')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
