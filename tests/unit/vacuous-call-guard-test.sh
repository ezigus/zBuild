#!/usr/bin/env bash
# Guard: a repo-private function called with its failure SWALLOWED must exist.
#
# #1991. The shape that motivated this (#1989):
#
#   t5_fb_body="$(_design_read_design_gate_feedback 2>/dev/null || true)"
#   assert_eq "T5: ... empty outside cycle" "" "$t5_fb_body"
#
# When #1979 deleted that function this did not fail. `command not found` went
# to the suppressed stderr, `|| true` cleared the rc, the variable was empty,
# and an assertion that it IS empty succeeded. Nobody edited the test — a
# deletion three files away disarmed it, and CI stayed green.
#
# Scope is deliberately the SWALLOWED form only. An unswallowed call to a
# missing function already fails loudly; the swallowed one is what goes silent,
# and narrowing to it is what keeps the false-positive budget at zero.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "guard: swallowed calls to undefined repo-private functions (#1991)"
setup_test_env "vacuous-call-guard"

# ─── _vcg_defs <root> — every function defined anywhere under <root> ─────────
# Whole tree on purpose: helpers legitimately live in tests/lib/ and in the
# calling test itself, so a narrower search would invent false positives.
_vcg_defs() {
    grep -rhoE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' \
        --include='*.sh' "$1" 2>/dev/null \
        | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)//' \
        | sort -u
}

# ─── _vcg_line_fn[_v] <grep line> — the command after the line's first `$(` ──
# Minus any VAR=value assignment prefixes: `$(_MAX=5 _build_read_x ...)` runs
# _build_read_x, not _MAX. Worked out by the shell: a sed per line made this
# file start 7,600 processes (ADR-065 §5, round 9). SPEC-10 holds it to the sed
# it replaced. A line whose first `$` does not open `$(` is taken whole, as the
# sed's unmatched pattern left it.
_VCG_OPEN_RE='^[^$]*[$][(][[:space:]]*'
_VCG_ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+'
_vcg_line_fn() { local _o; _vcg_line_fn_v _o "$1"; printf '%s' "$_o"; }
_vcg_line_fn_v() {
    local -n _vlo="$1"
    local _vl_cmd="$2"
    [[ "$_vl_cmd" =~ $_VCG_OPEN_RE ]] && _vl_cmd="${_vl_cmd:${#BASH_REMATCH[0]}}"
    while [[ "$_vl_cmd" =~ $_VCG_ASSIGN_RE ]]; do _vl_cmd="${_vl_cmd:${#BASH_REMATCH[0]}}"; done
    _vlo="${_vl_cmd%%[^A-Za-z0-9_]*}"
}

# ─── _vcg_scan <root> [dir...] — report "<fn> <file>:<line>" per violation ───
_vcg_scan() {
    local _root="$1"; shift
    local -A _defs=()
    local _d; while IFS= read -r _d; do [[ -n "$_d" ]] && _defs[$_d]=1; done < <(_vcg_defs "$_root")
    local _line _file _rest _lno _fn
    # Same exclusions as sigpipe-antipattern-guard-test.sh (#1884): a COMMENT is
    # not executed, this guard's own file carries the pattern as documentation
    # and fixtures rather than as live calls, and legacy-DoNotUse/ is frozen.
    grep -rnE '\$\([^)]*(2>/dev/null|\|\| true)' --include='*.sh' "$@" 2>/dev/null \
    | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; } \
    | { grep -v '/vacuous-call-guard-test.sh:' || true; } \
    | { grep -v '/legacy-DoNotUse/' || true; } \
    | while IFS= read -r _line; do
        _file="${_line%%:*}"; _rest="${_line#*:}"; _lno="${_rest%%:*}"
        _vcg_line_fn_v _fn "$_line"
        # #2013: the old rule was `[[ "$_fn" == _* ]]`, chosen to keep the
        # false-positive budget at zero. It cost the guard its own bug class —
        # `zbuild_engine_tmp` was deleted in #2017 and seven files went on
        # calling it in swallowed form, invisibly, because the name starts with
        # `z`. The prefix was never the property that mattered.
        #
        # What matters: the name resolves to NOTHING. Three filters, in cost
        # order, each load-bearing:
        #   - an underscore somewhere in the name. Repo functions have them;
        #     external commands almost never do (`pkg-config`, not `pkg_config`).
        #     This keeps `git`, `jq` and `date` out of the report without
        #     depending on what happens to be installed on the runner.
        #   - `command -v` — a real command, builtin or keyword.
        #   - defined somewhere in the tree.
        # Anything surviving all three is a call that silently yields "".
        [[ "$_fn" == *_* ]] || continue
        command -v "$_fn" >/dev/null 2>&1 && continue
        [[ -n "${_defs[$_fn]+x}" ]] || printf '%s %s:%s\n' "$_fn" "${_file#"$_root"/}" "$_lno"
    done | sort -u
}

# ─── SPEC-1: the tree is clean ──────────────────────────────────────────────
# Under the WIDENED rule (#2013), so this covers both shapes now: `_`-prefixed
# helpers and repo functions like `zbuild_engine_tmp` that never had a prefix.
# A hit here is a live bug of the #2017 shape, not a test to relax.
_vcg_found="$(_vcg_scan "$REPO_ROOT" \
    "$REPO_ROOT/tests" "$REPO_ROOT/plugins" "$REPO_ROOT/scripts" "$REPO_ROOT/core")"
if [[ -z "$_vcg_found" ]]; then
    assert_pass "[SPEC-1] no swallowed call to an undefined repo-private function"
else
    assert_fail "[SPEC-1] no swallowed call to an undefined repo-private function" \
        "$(tr '\n' ' ' <<< "$_vcg_found")"
fi

# ─── SPEC-2: the guard can actually detect one ──────────────────────────────
# A guard that only ever reports zero is indistinguishable from a guard that
# cannot report at all — which is the exact failure this whole issue is about.
_vcg_fx="$TEST_TEMP_DIR/fixture"; mkdir -p "$_vcg_fx"
cat > "$_vcg_fx/bad.sh" <<'FX'
out="$(_vcg_totally_undefined_fn 2>/dev/null || true)"
FX
_vcg_hit="$(_vcg_scan "$_vcg_fx" "$_vcg_fx")"
case "$_vcg_hit" in
    *_vcg_totally_undefined_fn*) assert_pass "[SPEC-2] a seeded vacuous call IS detected" ;;
    *) assert_fail "[SPEC-2] a seeded vacuous call IS detected" "scanner returned: '$_vcg_hit'" ;;
esac

# ─── SPEC-3: a DEFINED function called the same way is not flagged ──────────
cat > "$_vcg_fx/good.sh" <<'FX'
_vcg_defined_fn() { printf 'x'; }
out="$(_vcg_defined_fn 2>/dev/null || true)"
FX
rm -f "$_vcg_fx/bad.sh"
_vcg_ok="$(_vcg_scan "$_vcg_fx" "$_vcg_fx")"
assert_eq "[SPEC-3] a defined function is not flagged" "" "$_vcg_ok"

# ─── SPEC-4: an assignment prefix does not become a false positive ──────────
# `$(_VCG_MAX=5 _vcg_defined_fn ...)` runs _vcg_defined_fn; a naive extractor
# reports _VCG_MAX (undefined, because it is a variable) and cries wolf.
cat > "$_vcg_fx/good.sh" <<'FX'
_vcg_defined_fn() { printf 'x'; }
out="$(_VCG_MAX=5 _vcg_defined_fn "$1" 2>/dev/null || true)"
FX
_vcg_asn="$(_vcg_scan "$_vcg_fx" "$_vcg_fx")"
assert_eq "[SPEC-4] an assignment prefix is not mistaken for the command" "" "$_vcg_asn"

# ─── SPEC-5: a definition living in tests/lib/ still counts ─────────────────
# Definitions are collected tree-wide precisely so a shared test helper is not
# reported as missing.
mkdir -p "$_vcg_fx/lib"
cat > "$_vcg_fx/lib/helper.sh" <<'FX'
_vcg_helper_fn() { printf 'y'; }
FX
cat > "$_vcg_fx/good.sh" <<'FX'
out="$(_vcg_helper_fn 2>/dev/null || true)"
FX
_vcg_lib="$(_vcg_scan "$_vcg_fx" "$_vcg_fx")"
assert_eq "[SPEC-5] a definition in a sibling lib counts as defined" "" "$_vcg_lib"

# ─── SPEC-6: a repo function WITHOUT the leading underscore is caught ───────
# #2013. The narrowing to `_`-prefixed names was a false-positive budget
# decision, and it cost the guard the very bug it exists for: #2010 added
# `zbuild_engine_tmp` to helpers.sh, #2017 removed it, and SEVEN files went on
# calling it in swallowed form. Nothing flagged them — this guard skipped the
# name because it starts with `z`, not `_`.
#
# The prefix was never the property that mattered. What matters is that the name
# resolves to NOTHING: not a function in the tree, not a command on PATH, not a
# shell builtin. Anything else is a call that silently produces an empty string.
cat > "$_vcg_fx/lib/helper.sh" <<'FX'
_vcg_helper_fn() { printf 'y'; }
FX
cat > "$_vcg_fx/good.sh" <<'FX'
d="$(zbuild_vcg_engine_tmp 2>/dev/null || true)"
FX
_vcg_np="$(_vcg_scan "$_vcg_fx" "$_vcg_fx")"
case "$_vcg_np" in
    *zbuild_vcg_engine_tmp*) assert_pass "[SPEC-6] an undefined non-underscore repo function is caught" ;;
    *) assert_fail "[SPEC-6] an undefined non-underscore repo function is caught" \
        "scanner returned: '$_vcg_np' — this is the #2017 bug, still invisible" ;;
esac

# ─── SPEC-7: external commands are NOT flagged ─────────────────────────────
# Widening the name filter is only safe if the resolve check holds. `git`,
# `date` and friends are called in swallowed form all over the tree and are
# defined nowhere in it; reporting them would drown the real signal and the
# guard would be switched off within a week.
cat > "$_vcg_fx/good.sh" <<'FX'
a="$(git rev-parse HEAD 2>/dev/null || true)"
b="$(date +%s 2>/dev/null || true)"
c="$(command -v jq 2>/dev/null || true)"
FX
_vcg_ext="$(_vcg_scan "$_vcg_fx" "$_vcg_fx")"
assert_eq "[SPEC-7] external commands are not flagged" "" "$_vcg_ext"

# ─── SPEC-8: shell builtins and keywords are NOT flagged ───────────────────
cat > "$_vcg_fx/good.sh" <<'FX'
a="$(printf '%s' x 2>/dev/null || true)"
b="$(type -t ls 2>/dev/null || true)"
c="$(read -r _x 2>/dev/null || true)"
FX
_vcg_bi="$(_vcg_scan "$_vcg_fx" "$_vcg_fx")"
assert_eq "[SPEC-8] builtins are not flagged" "" "$_vcg_bi"

# ─── SPEC-9: the scan's work does not grow with the lines it reads ──────────
# It reads every swallowed call in the tree (~3,700 lines); a sed per line made
# this file start 7,600 processes (ADR-065 §5, round 9).
_vcg_cost() {   # <n> — subshells the scan of <n> swallowed calls runs in
    local i; : > "$_vcg_fx/good.sh"
    for (( i = 1; i <= $1; i++ )); do
        printf 'a%s="$(_VCG_X=1 _vcg_defined_fn %s 2>/dev/null || true)"\n' "$i" "$i" >> "$_vcg_fx/good.sh"
    done
    printf '_vcg_defined_fn() { :; }\n' >> "$_vcg_fx/good.sh"
    zb_test_work "$TEST_TEMP_DIR/vcg.trace" _vcg_scan "$_vcg_fx" "$_vcg_fx"
    zb_test_work_procs "$TEST_TEMP_DIR/vcg.trace"
}
_vcg_1="$(_vcg_cost 1)"; _vcg_30="$(_vcg_cost 30)"
assert_eq "[SPEC-9] 30 lines are scanned in as many subshells as 1 ($_vcg_1)" "$_vcg_1" "$_vcg_30"

# ─── SPEC-10: …and each line names the command the sed extraction named ─────
# The extraction before SPEC-9, verbatim, over lines of every shape it meets.
_vcg_fn_old() {
    local _cmd
    _cmd="$(sed -E 's/^[^$]*\$\([[:space:]]*//' <<< "$1")"
    while [[ "$_cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
        _cmd="$(sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//' <<< "$_cmd")"
    done
    sed -E 's/[^A-Za-z0-9_].*$//' <<< "$_cmd"
}
_vcg_corpus=(
    'f.sh:1:x="$(_vcg_a 2>/dev/null || true)"'
    'f.sh:2:x="$(  _vcg_b arg 2>/dev/null)"'
    'f.sh:3:x="$(A=1 B=2 _vcg_c || true)"'
    'f.sh:4:x="$(A= _vcg_d || true)"'
    'f.sh:5:y=$z; x="$(_vcg_e || true)"'
    'f.sh:6:x="$(_vcg_f)$(_vcg_g || true)"'
    'f.sh:7:x="$(git log 2>/dev/null)"'
    'f.sh:8:x="$(__vcg_h-x 2>/dev/null)"'
    'f.sh:9:x="$(A=1)"'
    'f.sh:10:  [[ -n "$(_vcg_i "$1" 2>/dev/null || true)" ]]'
    'f.sh:11:x="$( (_vcg_j) || true)"'
)
_vcg_diff=""
for _l in "${_vcg_corpus[@]}"; do
    _vcg_old="$(_vcg_fn_old "$_l")"
    _vcg_new="$(_vcg_line_fn "$_l" 2>/dev/null)"
    [[ "$_vcg_old" == "$_vcg_new" ]] || _vcg_diff+="[$_l] sed:[$_vcg_old] now:[$_vcg_new] "
done
assert_eq "[SPEC-10] the same command for every shape of line" "" "$_vcg_diff"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
