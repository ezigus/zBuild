#!/usr/bin/env bash
# tests/unit/nameref-local-clash-test.sh — a `_v` form's locals never hide its
# caller's variable (ADR-065 §5, round 9).
#
# A `_v` function fills the caller's variable through a nameref (`local -n o="$1"`).
# The name is looked up when the function assigns, so a local of the function with
# the caller's name takes the assignment and the caller gets nothing — no error,
# just an empty answer. _stage_scratch_key_v did this to stage_scratch_dir_v's
# `key`, and every stage ran without its scratch dir.
#
# N1 [change] no call `f_v <name> …` in core/, scripts/ or plugins/ passes a name
#             that f_v declares local
# N2 [guard]  the check finds such a clash in a fixture
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "nameref clash: a _v form's locals never hide the caller's variable"
setup_test_env "nameref-local-clash"

# _clashes <file>... — "<fn> <name> <file>:<line>" for each call that passes a
# name the called _v function declares local. One awk: it reads each `_v`
# function's locals (from `local`/`declare` in its body, which ends at the next
# `}` in column 0), then rereads the files for the calls.
_clashes() {
    awk '
        {
            if (match($0, /^[A-Za-z_][A-Za-z0-9_]*_v\(\)/)) {
                fn = substr($0, 1, RLENGTH - 2); infn = 1
                if ($0 ~ /\}[[:space:]]*$/ && $0 !~ /\{[[:space:]]*$/) infn = 0
            } else if (infn && $0 ~ /^\}/) { infn = 0 }
            if (infn || ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*_v\(\)/)) {
                line = $0; sub(/#.*/, "", line)
                while (match(line, /(^|[;{[:space:]])(local|declare)[[:space:]]+/)) {
                    rest = substr(line, RSTART + RLENGTH); line = rest
                    n = split(rest, w, /[[:space:]]+/)
                    for (i = 1; i <= n; i++) {
                        t = w[i]
                        if (t ~ /^-/) continue
                        if (t ~ /^[;|&]/ || t == "") break
                        sub(/=.*/, "", t)
                        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*$/) locals[fn SUBSEP t] = 1
                        else break
                        if (w[i] ~ /[;]$/) break
                    }
                }
            }
            files[FILENAME] = 1
        }
        END {
            for (f in files) {
                ln = 0
                while ((getline l < f) > 0) {
                    ln++
                    s = l; sub(/^[[:space:]]*#.*/, "", s)
                    while (match(s, /[A-Za-z_][A-Za-z0-9_]*_v[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
                        call = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
                        split(call, cw, /[[:space:]]+/)
                        if ((cw[1] SUBSEP cw[2]) in locals) print cw[1], cw[2], f ":" ln
                    }
                }
                close(f)
            }
        }' "$@" | sort -u
}

print_test_section "N1: the tree"
mapfile -t _files < <(find "$REPO_ROOT/core" "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" -name '*.sh' -not -path '*/legacy-DoNotUse/*' | sort)
_found="$(_clashes "${_files[@]}")"
assert_eq "[N1] no call passes a name its _v function declares local" "" "${_found//"$REPO_ROOT"\//}"

print_test_section "N2: the check can see one"
FX="$TEST_TEMP_DIR/fx.sh"
cat > "$FX" <<'SH'
_fx_key_v() {
    local -n _fko="$1"
    local key="$2"
    _fko="${key}-x"
}
_fx_dir_v() {
    local -n _fdo="$1"
    local key; _fx_key_v key "$2"
    _fdo="/s/$key"
}
_fx_ok_v() { local -n _foo="$1"; local _fo_k="$2"; _foo="$_fo_k"; }
_fx_caller() { local key; _fx_ok_v key a; }
SH
assert_eq "[N2] the clash in a fixture is reported" "_fx_key_v key $FX:8" "$(_clashes "$FX")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
