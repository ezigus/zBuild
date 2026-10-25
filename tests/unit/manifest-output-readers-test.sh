#!/usr/bin/env bash
# tests/unit/manifest-output-readers-test.sh — the manifest's outputs block is
# read by the shell, with the awk readers' answers (ADR-065 §5, round 6).
#
# They run on every result read and every dispatch (306 + 198 + 87 awks in one
# three-run pipeline test), on a file that is a few dozen lines long.
#
# R1 [change] _verdict_primary_output_path, manifest_graph_get_outputs,
#             manifest_graph_output_format and manifest_graph_output_summary
#             start no program
# R2 [guard]  each gives the awk reader's exact output, for every real manifest
#             and an adversarial corpus (the awk programs below are the
#             readers as they were, copied verbatim)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "manifest outputs readers: the shell, with awk's answers (ADR-065 §5)"
setup_test_env "manifest-output-readers"

# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

# ─── the readers as they were (awk), verbatim ───────────────────────────────
# shellcheck disable=SC2016
_ref_primary() {
    [[ -f "$1" ]] || return 0
    awk '
        BEGIN { in_out=0; cur_path=""; cur_primary=""; emitted=0 }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]*-[[:space:]]*id:/ {
            if (cur_primary == "true" && cur_path != "") {
                print cur_path; emitted=1; exit
            }
            cur_path=""; cur_primary=""
            next
        }
        in_out && /^[[:space:]]+path:/ {
            line=$0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_path=line; next
        }
        in_out && /^[[:space:]]+primary:/ {
            line=$0
            sub(/^[[:space:]]+primary:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_primary=line; next
        }
        END {
            if (!emitted && cur_primary == "true" && cur_path != "") print cur_path
        }
    ' "$1" 2>/dev/null
}
_ref_block() {
    awk -v block="$2" '
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
        $0 ~ "^"block":[[:space:]]*$" { in_block = 1; next }
        $0 ~ "^"block":[[:space:]]*\\[\\][[:space:]]*$" { exit }
        in_block && /^[a-zA-Z_]/ { flush(); exit }
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
    ' "$1" 2>/dev/null
}
_ref_field() {   # <manifest> <output_id> <field> — format / summary
    [[ -f "$1" && -n "$2" && -n "$3" ]] || return 0
    awk -v want="$2" -v field="$3" '
        /^outputs:[[:space:]]*$/ { inb = 1; next }
        /^[a-zA-Z_]/             { inb = 0 }
        inb && /^[[:space:]]+-[[:space:]]+id:[[:space:]]*/ {
            l = $0; sub(/^[[:space:]]+-[[:space:]]+id:[[:space:]]*/, "", l)
            sub(/[[:space:]]+$/, "", l)
            gsub(/["\047]/, "", l); cur = l; next
        }
        inb && cur == want && $0 ~ ("^[[:space:]]+" field ":[[:space:]]*") {
            l = $0; sub("^[[:space:]]+" field ":[[:space:]]*", "", l)
            sub(/[[:space:]]*#.*$/, "", l)
            sub(/[[:space:]]+$/, "", l)
            gsub(/["\047]/, "", l); print l; exit
        }
    ' "$1" 2>/dev/null || true
}

# ─── adversarial corpus ──────────────────────────────────────────────────────
C="$TEST_TEMP_DIR/corpus"; mkdir -p "$C"
_c() { printf '%b' "$2" > "$C/$1.yaml"; }
_c first   'id: a\noutputs:\n  - id: one\n    path: ${artifact_dir}/one.json\n    primary: true\n    format: json\n    summary: true\n  - id: two\n    path: two.md\n'
_c last    'outputs:\n  - id: one\n    path: one.md\n  - id: two\n    type: x/y@1\n    path: "two.json"   # c\n    primary: "true"\n'
_c none    'outputs:\n  - id: one\n    path: one.md\n    primary: false\n'
_c before  'outputs:\n  - id: one\n    primary: true\n    path: p1\n  - id: two\n    path: p2\n'
_c nopath  'outputs:\n  - id: one\n    primary: true\n  - id: two\n    primary: true\n    path: p2\n'
_c twice   'outputs:\n  - id: one\n    path: p1\n    path: p1b\n    primary: true\n    primary: false\n'
_c closed  'outputs:\n  - id: one\n    path: p1\nhooks:\n  run: x\n    primary: true\n'
_c inline  'inputs:\n  - id: i1\n    path: in.md\n    source: plan\n    required: true\noutputs: []\n'
_c inputs  'inputs:\n  - id: i1   # why\n    type: "t@1"\n    source: plan\n    required: true\n    path: ${artifact_dir}/in.md\n  - id: i2\noutputs:\n  - id: o1\n'
_c crlf    'outputs:\r\n  - id: one\r\n    path: p.json\r\n    primary: true\r\n    format: json\r\n'
_c noeol   'outputs:\n  - id: one\n    path: p.json\n    primary: true'
_c col0    'outputs:\n- id: zero\n  path: z.md\n  primary: true\n  format: markdown\n'
_c quotes  "outputs:\n  - id: 'q1'\n    path: '\${artifact_dir}/a#b.md'\n    primary: 'true'\n    format: \"json\"  # j\n    summary: 'true'\n"
_c tabs    'outputs:\n\t- id: t1\n\t  path:\tp.md\t\n\t  primary:\ttrue\n'
_c comment 'outputs:   # the list\n  - id: c1\n    path: c.md\n    primary: true\n'
_c reopen  'outputs:\n  - id: a\n    path: pa\noutputs:\n  - id: b\n    path: pb\n    primary: true\n'
_c idcomm  'outputs:\n  - id: x1 # note\n    format: json\n    summary: yes\n'
_c spaced  'outputs:\n  -   id:   s1  \n    path:     sp.md   \n    primary:   true  \n'
_c empties 'outputs:\n  - id:\n    path:\n    primary: true\n  - id: e2\n    path: ""\n    primary: true\n'
_c dash    'outputs:\n  - id: d1\n  - path: dp\n    primary: true\n'
_c onlyq   "outputs:\n  - id: \"\n    path: '\n    format: '\"\n"
_c carry   'outputs:\n  - id: a\n    path: pa\n    primary: true\nhooks:\n  run: x\noutputs:\n'
_c emptythen 'outputs: []\noutputs:\n  - id: late\n    path: pl\n    primary: true\n'
_c empty   ''
: > "$C/blank.yaml"

_files() { command find "$REPO_ROOT/plugins" "$C" -name '*.yaml' -type f | LC_ALL=C sort; }
_ids() { _ref_block "$1" outputs | cut -d'|' -f1; printf '%s\n' x1 one q1 zero t1 none-such ''; }

print_test_section "R2: the shell readers give the awk readers' answers"
_mp=0; _mb=0; _mf=0; _n=0; _d=""
while IFS= read -r f; do
    _n=$((_n + 1))
    a="$(_ref_primary "$f")"; b="$(_verdict_primary_output_path "$f")"
    [[ "$a" == "$b" ]] || { _mp=$((_mp + 1)); _d+="primary $f: awk=[$a] got=[$b]; "; }
    for blk in outputs inputs; do
        a="$(_ref_block "$f" "$blk")"; b="$(_mgraph_parse_block "$f" "$blk")"
        [[ "$a" == "$b" ]] || { _mb=$((_mb + 1)); _d+="$blk $f: awk=[$a] got=[$b]; "; }
    done
    while IFS= read -r oid; do
        for fld in format summary; do
            a="$(_ref_field "$f" "$oid" "$fld")"
            if [[ "$fld" == format ]]; then b="$(manifest_graph_output_format "$f" "$oid")"
            else b="$(manifest_graph_output_summary "$f" "$oid")"; fi
            [[ "$a" == "$b" ]] || { _mf=$((_mf + 1)); _d+="$fld($oid) $f: awk=[$a] got=[$b]; "; }
        done
    done < <(_ids "$f")
done < <(_files)
assert_eq "[R2] _verdict_primary_output_path agrees on all $_n files" "0" "$_mp" "$_d"
assert_eq "[R2] _mgraph_parse_block (outputs and inputs) agrees" "0" "$_mb" "$_d"
assert_eq "[R2] manifest_graph_output_format / _summary agree for every output id" "0" "$_mf" "$_d"
assert_eq "[R2] a missing file gives nothing" "||" \
    "$(_verdict_primary_output_path "$C/absent.yaml")|$(_mgraph_parse_block "$C/absent.yaml" outputs)|$(manifest_graph_output_format "$C/absent.yaml" one)"

print_test_section "R1: none of them starts a program"
CALLS="$TEST_TEMP_DIR/calls"; : > "$CALLS"
awk()  { printf 'awk\n'  >> "$CALLS"; command awk "$@"; }
grep() { printf 'grep\n' >> "$CALLS"; command grep "$@"; }
sed()  { printf 'sed\n'  >> "$CALLS"; command sed "$@"; }
_verdict_primary_output_path "$C/first.yaml" >/dev/null
manifest_graph_get_outputs "$C/first.yaml" >/dev/null
manifest_graph_output_format "$C/first.yaml" one >/dev/null
manifest_graph_output_summary "$C/first.yaml" one >/dev/null
unset -f awk grep sed
assert_eq "[R1] the four readers start nothing" "" "$(tr '\n' ' ' < "$CALLS")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
