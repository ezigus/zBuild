#!/usr/bin/env bash
# Tests: scripts/lib/numstat-format.sh — shared numstat banner formatter (#506)
#
# Extracted from build's _build_format_numstat. Exercises the formatter
# standalone with fixture numstat output: in-scope/out-of-scope masking,
# binary-file rendering, truncation hint with custom --full-at, and
# event-prefix routing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/numstat-format.sh (#506)"
setup_test_env "numstat-format"

# shellcheck source=../../scripts/lib/numstat-format.sh
source "$REPO_ROOT/scripts/lib/numstat-format.sh"

# ─── V1: basic format, in-scope path, footer totals ─────────────────────────
print_test_section "V1 basic numstat → +A -R path lines + total footer"
raw=$'12\t0\tcore/foo.sh\n3\t5\tcore/bar.sh'
allowed=( "core/" )
out="$(format_numstat "$raw" allowed)"
if printf '%s' "$out" | grep -qF '+12 -0  core/foo.sh' && \
   printf '%s' "$out" | grep -qF '+3 -5  core/bar.sh'; then
    assert_pass "V1 per-file lines render with +A -R prefix"
else
    assert_fail "V1 per-file lines" "got: $out"
fi
if printf '%s' "$out" | grep -qF 'total: 2 files, +15 -5'; then
    assert_pass "V1 footer aggregates files/adds/dels"
else
    assert_fail "V1 footer" "got: $out"
fi
# _NUMSTAT_FILES_COUNT side-effect via tempfile (not $()) — subshell capture
# above loses the assignment by construction (mirrors build's tempfile pattern).
fct_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-ns-fct.XXXXXX")"
format_numstat "$raw" allowed > "$fct_tmp"
rm -f "$fct_tmp"
assert_eq "V1 _NUMSTAT_FILES_COUNT side-effect (tempfile pattern)" "2" "$_NUMSTAT_FILES_COUNT"

# ─── V2: out-of-scope path masked ───────────────────────────────────────────
print_test_section "V2 out-of-scope path → <out-of-scope-context>"
raw=$'4\t0\tcore/in.sh\n9\t9\tsecrets/leak.env'
allowed=( "core/" )
out="$(format_numstat "$raw" allowed)"
if printf '%s' "$out" | grep -qF '<out-of-scope-context>' && \
   ! printf '%s' "$out" | grep -qF 'secrets/leak.env'; then
    assert_pass "V2 out-of-scope path masked, real path absent"
else
    assert_fail "V2 redaction" "got: $out"
fi

# ─── V3: binary file ("-\t-\tpath") rendered without crashing ───────────────
print_test_section "V3 binary file (numstat \"-\\t-\\tpath\") renders"
raw=$'-\t-\tassets/logo.png'
allowed=( "assets/" )
out="$(format_numstat "$raw" allowed)"
if printf '%s' "$out" | grep -qF '+- --  assets/logo.png' && \
   printf '%s' "$out" | grep -qF 'total: 1 files, +0 -0'; then
    assert_pass "V3 binary file rendered, totals stay numeric"
else
    assert_fail "V3 binary" "got: $out"
fi

# ─── V4: truncation hint honors --full-at ───────────────────────────────────
print_test_section "V4 >50 files → truncation hint with custom --full-at path"
big=""
for i in $(seq 1 60); do
    big+=$'1\t0\tcore/f'"${i}"$'.sh\n'
done
# strip trailing newline
big="${big%$'\n'}"
allowed=( "core/" )
out="$(format_numstat "$big" allowed --full-at "diff.patch")"
if printf '%s' "$out" | grep -qE '↪ \[10 more files · full at diff\.patch\]'; then
    assert_pass "V4 truncation hint uses --full-at value"
else
    assert_fail "V4 truncation hint" "got: $(printf '%s' "$out" | tail -5)"
fi
fct_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-ns-fct.XXXXXX")"
format_numstat "$big" allowed --full-at "diff.patch" > "$fct_tmp"
rm -f "$fct_tmp"
assert_eq "V4 untruncated _NUMSTAT_FILES_COUNT (tempfile pattern)" "60" "$_NUMSTAT_FILES_COUNT"

# ─── V5: empty allowlist disables redaction ─────────────────────────────────
print_test_section "V5 empty allowlist → no redaction"
raw=$'1\t0\tany/where/file.sh'
allowed=()
out="$(format_numstat "$raw" allowed)"
if printf '%s' "$out" | grep -qF 'any/where/file.sh' && \
   ! printf '%s' "$out" | grep -qF '<out-of-scope-context>'; then
    assert_pass "V5 empty allowlist leaves path verbatim"
else
    assert_fail "V5 empty allowlist" "got: $out"
fi

# ─── V6: _numstat_path_in_scope standalone helper ───────────────────────────
print_test_section "V6 _numstat_path_in_scope prefix-match semantics"
allowed=( "core/" "plugins/agent/build/plugin.sh" )
if _numstat_path_in_scope "core/foo.sh" allowed; then
    assert_pass "V6 dir prefix matches descendant"
else
    assert_fail "V6 dir prefix" "core/foo.sh should match core/"
fi
if _numstat_path_in_scope "plugins/agent/build/plugin.sh" allowed; then
    assert_pass "V6 exact file match"
else
    assert_fail "V6 exact" "should match"
fi
if ! _numstat_path_in_scope "scripts/lib/numstat-format.sh" allowed; then
    assert_pass "V6 unrelated path rejected"
else
    assert_fail "V6 unrelated" "should NOT match"
fi

cleanup_test_env
print_test_results
