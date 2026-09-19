#!/usr/bin/env bash
# Tests: the manifest index (#2152, ADR-065 §3/§4) — one find + one awk fill the
# yaml memo and _inputs_scan_manifests in the parent shell.
#
# SPEC-1: equivalence — for every manifest under plugins/ AND an adversarial
#         corpus, for every indexed key, manifest_index_get is byte- and
#         rc-identical to _yaml_get_uncached. This is the guard against a second
#         parser drifting from the first.
# SPEC-2: the index is built with exactly one find and one awk.
# SPEC-3: _inputs_scan_manifests filled in the parent serves _inputs_stage_manifest
#         from a $( ) with zero awk; tests/ manifests are excluded; first
#         occurrence wins; re-sourcing input-resolve.sh keeps the fill.
# SPEC-4: yaml_cache_flush clears the index and the input-resolve maps; the
#         ZBUILD_YAML_CACHE=0 kill switch bypasses the index.
# SPEC-5: <root> and <root>/ are one index.
# SPEC-6: absent key → 0 bytes rc 0; `key:` → one newline; a path outside the
#         root → rc 2 (the lazy path, unchanged).
# SPEC-7: sourcing core/pipeline/runner.sh forks ≤ 400 awk (was 1,050).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "manifest index — one pass fills the memos in the parent shell (#2152)"
setup_test_env "manifest-index"

# shellcheck disable=SC1091
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
if ! declare -F manifest_index_load >/dev/null 2>&1; then
    assert_fail "[SPEC-0] manifest_index_load is defined" "missing — core/plugin-registry/manifest-index.sh not sourced by manifest-validation.sh"
    print_test_results; exit 1
fi
assert_pass "[SPEC-0] manifest_index_load is defined"

# file-backed counters: the work may run in a subshell
AWKS="$TEST_TEMP_DIR/awks"; FINDS="$TEST_TEMP_DIR/finds"; : > "$AWKS"; : > "$FINDS"
awk()  { printf 'x\n' >> "$AWKS";  command awk  "$@"; }
find() { printf 'x\n' >> "$FINDS"; command find "$@"; }
_n() { wc -l < "$1" | tr -d ' '; }

# ─── adversarial corpus ──────────────────────────────────────────────────────
CORPUS="$TEST_TEMP_DIR/corpus"
_m() { mkdir -p "$CORPUS/$1"; printf '%b' "$2" > "$CORPUS/$1/manifest.yaml"; }
_m agent/a1 'id: a1\nname: Demo Plugin   # trailing comment\nkind: agent\nversion: 1.0.0\nsummary:\nname_quoted: "has spaces"\npersona:\n  role: a|b\n  perspective: |\n    block\nhooks:\n  run: run_a1\n  cleanup: '"'"'quoted single'"'"'\nprovides:\n  role: builder\n  result_contract: 2\n  alias: b\n'
_m agent/a2 'id: a2\nid: a2-dup\nkind: agent\nhooks:\n  run: first\nhooks:\n  run: second\nprovides:\n  deep:\n    deeper:\n      role: depth4\n'
_m agent/a3 'id:a3\nname: trailing spaces   \nkind: "#not-a-comment"\nversion: "unterminated\nsummary: value: with: colons | and pipes\nplatform: darwin\npersona: inline\nhooks:\n# a column-0 comment inside the block\n- a column-0 list item inside the block\n  run: still_in_block\nprovides:\n  role: rolename\nrole: top-level-role\n'
_m agent/a4 'id: a4\r\nkind: agent\r\nhooks:\r\n  run: crlf\r\n'
_m agent/a5 'id: a5\nkind: tool\nconvergence: gate\ncapabilities:\n  empty_diff_legitimate: true\nconfig:\n  tier_default: T1\nhooks:\n  run: no_trailing_newline'
_m agent/a6 ''
_m agent/a7 'id: a7\nsummary: >-\nname: >\nversion: |+\nkind: |-\n'
_m tool/t1 'id: t1\nkind: tool\nprovides:\n  role: tester\n'
mkdir -p "$CORPUS/tool/t1/tests"; printf 'id: t1-fixture\nkind: tool\nprovides:\n  role: tester\n' > "$CORPUS/tool/t1/tests/manifest.yaml"

# ─── SPEC-1: equivalence ─────────────────────────────────────────────────────
print_test_section "SPEC-1: index == _yaml_get_uncached, byte for byte, for every manifest and key"
_equiv_root() {
    local root="$1" label="$2" mism=0 detail="" f k a b ra rb
    yaml_cache_flush
    manifest_index_load "$root"
    while IFS= read -r f; do
        for k in "${_ZBUILD_MIDX_KEYS[@]}"; do
            a="$(_yaml_get_uncached "$f" "$k" | od -c)"; ra="${PIPESTATUS[0]}"
            b="$(manifest_index_get "$f" "$k" | od -c)"; rb="${PIPESTATUS[0]}"
            if [[ "$a" != "$b" || "$ra" != "$rb" ]]; then
                mism=$((mism + 1)); detail+="${f#"$root"/}:$k uncached=[$(_yaml_get_uncached "$f" "$k" | tr '\n' '~')] rc=$ra index=[$(manifest_index_get "$f" "$k" | tr '\n' '~')] rc=$rb; "
            fi
        done
    done < <(command find "$root" -name manifest.yaml -type f | sort)
    if [[ "$mism" -eq 0 ]]; then assert_pass "[SPEC-1] $label: every manifest × ${#_ZBUILD_MIDX_KEYS[@]} keys identical"; else assert_fail "[SPEC-1] $label: $mism mismatch(es)" "$detail"; fi
}
_equiv_root "$CORPUS" "adversarial corpus"
_equiv_root "$REPO_ROOT/plugins" "the real plugins/ tree"
_n_keys="${#_ZBUILD_MIDX_KEYS[@]}"
if (( _n_keys >= 16 )); then assert_pass "[SPEC-1] the index covers the 12 prewarm keys plus provides.alias, convergence, capabilities.empty_diff_legitimate, config.tier_default ($_n_keys)"; else assert_fail "[SPEC-1] key coverage" "only $_n_keys keys"; fi

# ─── SPEC-2: one find, one awk ───────────────────────────────────────────────
print_test_section "SPEC-2: the index is built with exactly one find and one awk"
yaml_cache_flush; : > "$AWKS"; : > "$FINDS"
manifest_index_load "$CORPUS"
assert_eq "[SPEC-2] one awk for ${_n_keys} keys × $(command find "$CORPUS" -name manifest.yaml | wc -l | tr -d ' ') manifests" "1" "$(_n "$AWKS")"
assert_eq "[SPEC-2] one find" "1" "$(_n "$FINDS")"
manifest_index_load "$CORPUS"
assert_eq "[SPEC-2] a second load of the same root forks nothing" "1|1" "$(_n "$AWKS")|$(_n "$FINDS")"

# ─── SPEC-3: input-resolve is served from the parent fill ────────────────────
print_test_section "SPEC-3: _inputs_scan_manifests filled in the parent serves \$( ) callers with zero awk"
# shellcheck disable=SC1091
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
yaml_cache_flush; : > "$AWKS"
_inputs_scan_manifests "$CORPUS"
_fill_awks="$(_n "$AWKS")"
if (( _fill_awks <= 1 )); then assert_pass "[SPEC-3] the fill itself is one pass ($_fill_awks awk)"; else assert_fail "[SPEC-3] the fill is one pass" "$_fill_awks awks"; fi
: > "$AWKS"
_TPL_STAGE_ROLES_build="builder"; _TPL_STAGE_ROLES_test="tester"
_m1="$(_inputs_stage_manifest build "$CORPUS")"; _m2="$(_inputs_stage_manifest test "$CORPUS")"; _m3="$(_inputs_stage_manifest a5 "$CORPUS")"
assert_eq "[SPEC-3] three \$( ) lookups fork zero awk" "0" "$(_n "$AWKS")"
assert_eq "[SPEC-3] role → manifest (provides.role, first occurrence)" "$CORPUS/agent/a1/manifest.yaml" "$_m1"
assert_eq "[SPEC-3] a tests/ manifest is never a producer" "$CORPUS/tool/t1/manifest.yaml" "$_m2"
assert_eq "[SPEC-3] id → manifest when no role is declared" "$CORPUS/agent/a5/manifest.yaml" "$_m3"
assert_eq "[SPEC-3] a duplicated id keeps its first occurrence" "$CORPUS/agent/a2/manifest.yaml" "${_IR_BY_ID[a2]:-}"
assert_eq "[SPEC-3] platform-specific plugins never win the generic role slot" "" "${_IR_BY_ROLE[rolename]:+set}"
# shellcheck disable=SC1091
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
: > "$AWKS"
_m1b="$(_inputs_stage_manifest build "$CORPUS")"
assert_eq "[SPEC-3] re-sourcing input-resolve.sh keeps the fill (route.sh re-sources it lazily)" "0|$CORPUS/agent/a1/manifest.yaml" "$(_n "$AWKS")|$_m1b"

# ─── SPEC-4: flush and the kill switch ───────────────────────────────────────
print_test_section "SPEC-4: yaml_cache_flush clears the index and the maps; ZBUILD_YAML_CACHE=0 bypasses"
yaml_cache_flush
assert_eq "[SPEC-4] flush empties the index" "0" "${#_ZBUILD_MIDX[@]}"
assert_eq "[SPEC-4] flush empties the input-resolve maps" "0|" "${#_IR_BY_ID[@]}|${_IR_SCAN_KEY:-}"
ZBUILD_YAML_CACHE=0
: > "$AWKS"
manifest_index_load "$CORPUS"
assert_eq "[SPEC-4] with the kill switch the index is not built" "0|0" "${#_ZBUILD_MIDX[@]}|$(_n "$AWKS")"
ZBUILD_YAML_CACHE=1

# ─── SPEC-5: root normalisation ──────────────────────────────────────────────
print_test_section "SPEC-5: <root> and <root>/ are one index"
yaml_cache_flush; : > "$AWKS"
manifest_index_load "$CORPUS/"; manifest_index_load "$CORPUS"
assert_eq "[SPEC-5] one build for both spellings" "1" "$(_n "$AWKS")"

# ─── SPEC-6: absent vs empty vs missing ──────────────────────────────────────
print_test_section "SPEC-6: absent → 0 bytes rc 0; empty → one newline; outside the root → rc 2"
yaml_cache_flush; manifest_index_load "$CORPUS"
_probe() { local out; out="$(manifest_index_get "$1" "$2" | od -An -c | tr -d ' \n')"; printf '%s|%s' "${PIPESTATUS[0]}" "$out"; }
assert_eq "[SPEC-6] absent key: rc 0, 0 bytes" "0|" "$(_probe "$CORPUS/tool/t1/manifest.yaml" summary)"
assert_eq "[SPEC-6] empty value: rc 0, one newline" '0|\n' "$(_probe "$CORPUS/agent/a1/manifest.yaml" summary)"
assert_eq "[SPEC-6] a path outside the root: rc 2" "2|" "$(_probe "$TEST_TEMP_DIR/nope.yaml" id)"
yaml_cache_flush; yaml_cache_prewarm "$CORPUS"
assert_eq "[SPEC-6] prewarm records absent keys as rc 0 empty (so a subshell lookup never re-parses)" "0" "${_ZBUILD_YAML_RC["$CORPUS/tool/t1/manifest.yaml"$'\034'summary]:-unset}"

# ─── SPEC-7: what sourcing the runner costs ──────────────────────────────────
print_test_section "SPEC-7: sourcing core/pipeline/runner.sh forks ≤ 400 awk"
_runner_awks="$(bash -c '
    AWKS="$1"; : > "$AWKS"
    awk() { printf "x\n" >> "$AWKS"; command awk "$@"; }
    source "$2/scripts/lib/helpers.sh" >/dev/null 2>&1
    source "$2/core/pipeline/runner.sh" >/dev/null 2>&1
    wc -l < "$AWKS" | tr -d " "
' _ "$TEST_TEMP_DIR/runner-awks" "$REPO_ROOT" 2>/dev/null)"
if [[ "$_runner_awks" =~ ^[0-9]+$ ]] && (( _runner_awks <= 400 )); then
    assert_pass "[SPEC-7] source runner.sh forks $_runner_awks awk (≤ 400; was 1,050)"
else
    assert_fail "[SPEC-7] source runner.sh forks ≤ 400 awk" "got ${_runner_awks:-?}"
fi

unset -f awk find
cleanup_test_env
print_test_results
exit $((FAIL > 0))
