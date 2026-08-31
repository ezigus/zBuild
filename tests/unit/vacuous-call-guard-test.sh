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
    grep -rhoE '^[[:space:]]*(function[[:space:]]+)?_[A-Za-z0-9_]+[[:space:]]*\(\)' \
        --include='*.sh' "$1" 2>/dev/null \
        | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)//' \
        | sort -u
}

# ─── _vcg_scan <root> [dir...] — report "<fn> <file>:<line>" per violation ───
_vcg_scan() {
    local _root="$1"; shift
    local _defs; _defs="$(_vcg_defs "$_root")"
    local _line _file _rest _lno _cmd _fn
    # Same exclusions as sigpipe-antipattern-guard-test.sh (#1884): a COMMENT is
    # not executed, this guard's own file carries the pattern as documentation
    # and fixtures rather than as live calls, and legacy/ is frozen.
    grep -rnE '\$\([^)]*(2>/dev/null|\|\| true)' --include='*.sh' "$@" 2>/dev/null \
    | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; } \
    | { grep -v '/vacuous-call-guard-test.sh:' || true; } \
    | { grep -v '/legacy/' || true; } \
    | while IFS= read -r _line; do
        _file="${_line%%:*}"; _rest="${_line#*:}"; _lno="${_rest%%:*}"
        # What follows the first `$(`, minus any VAR=value assignment prefixes:
        # `$(_MAX=5 _build_read_x ...)` runs _build_read_x, not _MAX.
        _cmd="$(sed -E 's/^[^$]*\$\([[:space:]]*//' <<< "$_line")"
        while [[ "$_cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
            _cmd="$(sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//' <<< "$_cmd")"
        done
        _fn="$(sed -E 's/[^A-Za-z0-9_].*$//' <<< "$_cmd")"
        [[ "$_fn" == _* ]] || continue
        grep -qx "$_fn" <<< "$_defs" || printf '%s %s:%s\n' "$_fn" "${_file#"$_root"/}" "$_lno"
    done | sort -u
}

# ─── SPEC-1: the tree is clean ──────────────────────────────────────────────
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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
