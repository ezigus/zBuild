#!/usr/bin/env bash
# tests/unit/yaml-get-cache-test.sh
# Acceptance tests for yaml_get memoization (#1614).
#
# SPEC-1: cached output is byte-identical + rc-identical to uncached, across the
#         whole observable contract (missing file, missing key, empty value,
#         comment stripping, quotes, a `|` inside a value, nested, block scalar)
# SPEC-2: missing-file rc=2 survives the cache (distinct from missing-key rc=0)
# SPEC-3: a present-but-empty value returns exactly one newline, not zero bytes
# SPEC-4: block scalar keeps its quirk (returns the literal `|`)
# SPEC-5: yaml_cache_flush <file> drops only that file, and a rewrite is then seen
# SPEC-6: ZBUILD_YAML_CACHE=0 disables caching (a rewrite is seen with no flush)
# SPEC-7: identical relative paths under two roots do not collide
# SPEC-8: NEGATIVE CONTROL — the cache is actually used (fails if it is inert)
# SPEC-9: yaml_cache_prewarm fills the CALLING shell and a subshell inherits it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "yaml_get memoization (#1614)"
setup_test_env "yaml-get-cache"

# shellcheck disable=SC1091
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"

# A fixture covering every shape the contract distinguishes.
_write_fixture() {
    local path="$1" id="${2:-demo}"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
id: $id
name: Demo Plugin   # trailing comment
kind: agent
empty_val:
quoted: "has spaces"
piped: a|b
hooks:
  init: demo_init
description: |
  block line one
EOF
}

FIX="$TEST_TEMP_DIR/plugins/agent/demo/manifest.yaml"
_write_fixture "$FIX"

# _probe <file> <key> — prints "rc|bytecount"; byte count is what distinguishes a
# present-but-empty value (1 byte) from a missing key (0 bytes).
_probe() {
    local out; out="$TEST_TEMP_DIR/probe.out"
    yaml_get "$1" "$2" >"$out" 2>/dev/null
    local rc=$?
    printf '%s|%s' "$rc" "$(wc -c <"$out" | tr -d ' ')"
}

# ── SPEC-1: cached vs uncached equivalence over the full contract ─────────────
_cases=(
    "missing-file:$TEST_TEMP_DIR/nope.yaml:id"
    "missing-key:$FIX:nosuch"
    "top-level:$FIX:id"
    "comment-stripped:$FIX:name"
    "empty-value:$FIX:empty_val"
    "quoted:$FIX:quoted"
    "pipe-in-value:$FIX:piped"
    "nested-present:$FIX:hooks.init"
    "nested-absent:$FIX:hooks.nosuch"
    "block-scalar:$FIX:description"
)
_mismatch=0 _detail=""
for _c in "${_cases[@]}"; do
    _lbl="${_c%%:*}"; _rest="${_c#*:}"; _f="${_rest%%:*}"; _k="${_rest#*:}"
    yaml_cache_flush
    ZBUILD_YAML_CACHE=0
    _un="$(_probe "$_f" "$_k")"
    ZBUILD_YAML_CACHE=1
    yaml_cache_flush
    _c1="$(_probe "$_f" "$_k")"   # miss
    _c2="$(_probe "$_f" "$_k")"   # hit
    if [[ "$_un" != "$_c1" || "$_un" != "$_c2" ]]; then
        _mismatch=$((_mismatch + 1))
        _detail+="${_lbl}: uncached=${_un} miss=${_c1} hit=${_c2}; "
    fi
done
if [[ "$_mismatch" -eq 0 ]]; then
    assert_pass "[SPEC-1] cached output is rc- and byte-identical to uncached across all ${#_cases[@]} contract cases"
else
    assert_fail "[SPEC-1] cached output must match uncached exactly (${_mismatch} mismatch(es))" "$_detail"
fi

# ── SPEC-2: missing file rc=2, distinct from missing key rc=0 ────────────────
yaml_cache_flush
assert_eq "[SPEC-2] missing file yields rc=2 + 0 bytes through the cache" \
    "2|0" "$(_probe "$TEST_TEMP_DIR/nope.yaml" "id")"
assert_eq "[SPEC-2] missing key yields rc=0 + 0 bytes (not conflated with missing file)" \
    "0|0" "$(_probe "$FIX" "nosuch")"

# ── SPEC-3: empty value is one newline, not zero bytes ──────────────────────
assert_eq "[SPEC-3] present-but-empty value returns exactly 1 byte" \
    "0|1" "$(_probe "$FIX" "empty_val")"

# ── SPEC-4: block scalar quirk preserved ────────────────────────────────────
assert_eq "[SPEC-4] block scalar returns the literal pipe (2 bytes), quirk intact" \
    "0|2" "$(_probe "$FIX" "description")"

# ── SPEC-5: flush <file> is scoped, and a rewrite is then visible ───────────
yaml_cache_flush
OTHER="$TEST_TEMP_DIR/plugins/agent/other/manifest.yaml"
_write_fixture "$OTHER" "other"
_ignore="$(yaml_get "$FIX" id)"; _ignore="$(yaml_get "$OTHER" id)"   # populate both
_write_fixture "$FIX" "rewritten"
yaml_cache_flush "$FIX"
assert_eq "[SPEC-5] after flushing one file, its rewrite is visible" \
    "rewritten" "$(yaml_get "$FIX" id)"
assert_eq "[SPEC-5] flushing one file leaves another file's entry intact" \
    "other" "$(yaml_get "$OTHER" id)"

# ── SPEC-6: kill switch — no cache, so a rewrite needs no flush ─────────────
_write_fixture "$FIX" "first"
ZBUILD_YAML_CACHE=0
_v1="$(yaml_get "$FIX" id)"
_write_fixture "$FIX" "second"
_v2="$(yaml_get "$FIX" id)"
ZBUILD_YAML_CACHE=1   # restore: a bare assignment persists for the rest of the file
if [[ "$_v1" == "first" && "$_v2" == "second" ]]; then
    assert_pass "[SPEC-6] ZBUILD_YAML_CACHE=0 disables caching (rewrite seen without flush)"
else
    assert_fail "[SPEC-6] kill switch must disable caching" "got v1=$_v1 v2=$_v2"
fi

# ── SPEC-7: same relative path under two roots must not collide ─────────────
yaml_cache_flush
ROOT_A="$TEST_TEMP_DIR/rootA/plugins/agent/dup/manifest.yaml"
ROOT_B="$TEST_TEMP_DIR/rootB/plugins/agent/dup/manifest.yaml"
_write_fixture "$ROOT_A" "from-A"
_write_fixture "$ROOT_B" "from-B"
_a="$(yaml_get "$ROOT_A" id)"; _b="$(yaml_get "$ROOT_B" id)"
if [[ "$_a" == "from-A" && "$_b" == "from-B" ]]; then
    assert_pass "[SPEC-7] identical relative paths under two roots resolve independently"
else
    assert_fail "[SPEC-7] two roots must not collide in the cache" "got A=$_a B=$_b"
fi

# ── SPEC-8: NEGATIVE CONTROL — prove the cache is not inert ─────────────────
# Counts real parses by wrapping the uncached reader. The tally MUST live in a
# FILE, not a variable: yaml_get calls _yaml_get_uncached inside a command
# substitution, so a variable increment would be lost with that subshell — the
# same trap that makes a naive per-call cache useless here (#1614). This control
# fails if the cache is a no-op.
_PARSE_LOG="$TEST_TEMP_DIR/parses.log"
: > "$_PARSE_LOG"
eval "$(declare -f _yaml_get_uncached | sed '1s/^_yaml_get_uncached/_yg_real/')"
_yaml_get_uncached() { printf 'x\n' >> "$_PARSE_LOG"; _yg_real "$@"; }
_parses() { wc -l < "$_PARSE_LOG" | tr -d ' '; }

yaml_cache_flush
: > "$_PARSE_LOG"
yaml_get "$FIX" id >/dev/null 2>&1        # miss -> exactly 1 parse
_after_first="$(_parses)"
yaml_get "$FIX" id >/dev/null 2>&1        # hit  -> no parse
yaml_get "$FIX" id >/dev/null 2>&1        # hit  -> no parse
_after_repeats="$(_parses)"
if [[ "$_after_first" -eq 1 && "$_after_repeats" -eq 1 ]]; then
    assert_pass "[SPEC-8] cache is live: 3 identical lookups cause exactly 1 parse"
else
    assert_fail "[SPEC-8] repeated lookups must not re-parse (cache inert?)" \
        "parses after 1st=$_after_first, after 3 total=$_after_repeats (expected 1 and 1)"
fi

# Same control with the cache OFF: 3 lookups MUST cost 3 parses. Without this,
# SPEC-8 could pass on a build where the reader is never reached at all.
yaml_cache_flush
: > "$_PARSE_LOG"
ZBUILD_YAML_CACHE=0
yaml_get "$FIX" id >/dev/null 2>&1
yaml_get "$FIX" id >/dev/null 2>&1
yaml_get "$FIX" id >/dev/null 2>&1
_uncached_parses="$(_parses)"
ZBUILD_YAML_CACHE=1
assert_eq "[SPEC-8] control: with the cache off, 3 lookups cost 3 parses" \
    "3" "$_uncached_parses"

# ── SPEC-9: prewarm fills the calling shell and a subshell inherits it ─────
yaml_cache_flush
: > "$_PARSE_LOG"
yaml_cache_prewarm "$TEST_TEMP_DIR/plugins"
_prewarm_parses="$(_parses)"
# A command substitution IS a subshell: it must read the inherited cache and add
# no parse. This is the property the whole design rests on — without it the cache
# would never be hit by the 56-of-82 call sites that read yaml_get inside $( ).
_before_sub="$(_parses)"
_ignore="$(yaml_get "$FIX" id)"
_after_sub="$(_parses)"
if [[ "$_prewarm_parses" -gt 0 && "$_after_sub" -eq "$_before_sub" ]]; then
    assert_pass "[SPEC-9] prewarm populates the calling shell; a subshell lookup adds no parse"
else
    assert_fail "[SPEC-9] prewarm must be inherited by subshells" \
        "prewarm parses=$_prewarm_parses before=$_before_sub after=$_after_sub"
fi

# ── SPEC-10: arrays survive being sourced from INSIDE a function ────────────
# scripts/lib/manifest-graph.sh:289 sources this library from within a function.
# A bare `declare -A` there is function-LOCAL and vanishes on return, leaving the
# arrays undeclared; bash then evaluates a string subscript ARITHMETICALLY to 0,
# so every key collides at index 0 and yaml_get returns another key's value.
# `declare -gA` prevents that.
#
# This MUST run in a fresh process. Sourcing inside a function in THIS shell would
# still see the arrays this file already declared globally at the top, and the bug
# would be masked — the first draft of this check passed under mutation for exactly
# that reason.
_SPEC10_FIX="$TEST_TEMP_DIR/spec10/plugins/agent/s10/manifest.yaml"
_write_fixture "$_SPEC10_FIX" "s10-id"
_spec10_out="$(bash -c '
    set -uo pipefail
    _src_inside_a_function() { source "$1/core/plugin-registry/manifest-validation.sh"; }
    _src_inside_a_function "$1"
    printf "%s|%s" "$(yaml_get "$2" id)" "$(yaml_get "$2" kind)"
' _ "$REPO_ROOT" "$_SPEC10_FIX" 2>/dev/null)"
assert_eq "[SPEC-10] function-scoped source keeps keys distinct (declare -gA)" \
    "s10-id|agent" "$_spec10_out"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
