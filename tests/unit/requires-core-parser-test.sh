#!/usr/bin/env bash
# tests/unit/requires-core-parser-test.sh
# `_yaml_get_requires_core_list` reads the WHOLE requires.core list (#2083).
#
# Split from tests/unit/requires-core-resolution-test.sh, which was 626 lines
# against CLAUDE.md's 500-line rule. The seam is a real one, not an arbitrary
# cut to get under a number: that file is about the RESOLVER — what a declared
# entry means and whether a plugin can reach it — while this one is about the
# PARSER underneath it, whether the declaration is read at all. They close
# different issues (#2065 vs #2083) and fail for different reasons, so a reader
# chasing one is not made to page through the other.
#
# Deliberately its own file rather than assertions bolted onto a crowded one,
# following tests/unit/route-missing-include-test.sh's precedent: the parser
# belongs to no single plugin, and it is sourced by everything that reads a
# manifest, so a sandbox leak in the resolver suite must not be able to take
# this guard down with it. It stands alone — it does NOT source the file it was
# split from, and duplicates the three helpers it needs (a dozen lines) rather
# than reaching across.
#
# ─── The bug ────────────────────────────────────────────────────────────────
# The parser accepted only `^[[:space:]]+-[[:space:]]+` lines inside the `core:`
# block. Anything else fell through to the terminating branch, so a comment or
# a blank line SILENTLY ENDED THE LIST and every later entry was dropped:
#
#     requires:
#       core:
#         - redaction
#         # a rationale comment
#         - event-bus
#         - router
#
# parsed to `redaction` alone. A blank line does the same; a comment BEFORE the
# first entry returns the empty list. All three are valid YAML. Measured before
# the fix: [redaction] / [redaction] / [].
#
# ─── Why the existing tests could not have caught it ────────────────────────
# `requires.core` had exactly one enforced consumer — the kind: agent check that
# the literal string `redaction` is present — and that entry sits at POSITION 1
# of the list, the one position truncation cannot reach. The asymmetry did the
# rest: a comment BEFORE `- redaction` empties the list and the check fails
# loudly, while one AFTER it leaves `redaction` intact and drops only the
# remainder, so validation passed and the rest of the declaration quietly did
# not exist. The bug was structurally invisible to the only check that read it.
#
# ─── Why it had to be fixed alongside #2065, not after ──────────────────────
# #2065 makes the whole list load-bearing: a resolver reading through a
# truncating parser reports "no violation" for a declaration it never saw. That
# is a fix containing the bug it fixes — green, and blind to exactly the
# declarations it exists to check. SPEC-8 below is that end-to-end case.
#
# ─── SPECs ──────────────────────────────────────────────────────────────────
# (These were SPEC-13/13h/13i in the resolver file before the split; renumbered
#  from 1 here because this file is standalone and a lone "SPEC-13" with no
#  1-12 above it reads as a fragment.)
# SPEC-1: a comment BETWEEN entries does not end the list
# SPEC-2: a blank line between entries does not end the list
# SPEC-3: a comment BEFORE the first entry does not empty the list
# SPEC-4: the inline `core: [a, b, c]` form still parses
# SPEC-5: a trailing comment on an entry is still stripped
# SPEC-6: the block still TERMINATES — a sibling key ends it, and a later `- `
#         list (provides.events) is never swept in. The over-reach direction:
#         skipping comments must not make the parser run on forever.
# SPEC-7: every real multi-line manifest parses to the set an INDEPENDENT
#         reader finds — sed range addressing, not an awk state machine, so it
#         cannot share the bug under test
# SPEC-8[the bite]: a `router` declared AFTER a comment is still resolved and
#         still refused when the plugin loads no router. This is the assertion
#         that proves #2065 is not blind.
# SPEC-9: the asymmetry that hid the bug — `redaction` survives a following
#         comment (the half that always worked) AND so does everything after it
set -uo pipefail
# Deliberately NOT `set -e`: assert_fail returns non-zero when called without a
# detail argument, which under -e would abort before print_test_results.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

for _dep in scripts/lib/helpers.sh scripts/lib/test-helpers.sh; do
    if [[ ! -f "$REPO_ROOT/$_dep" ]]; then
        printf 'requires-core-parser-test: required dependency missing: %s\n' \
            "$REPO_ROOT/$_dep" >&2
        exit 2
    fi
done
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "requires.core list parsing (#2083)"
setup_test_env "requires-core-parser"

# ─── Precondition: the parser exists ────────────────────────────────────────
# Without this, SPEC-7's sweep passes by comparing nothing to nothing on a tree
# where the parser has been renamed or moved: `command not found` yields empty
# on both sides. The resolver suite learned this the hard way on its own first
# run, where three assertions passed for exactly that reason.
_PARSER_OK=1
if ! declare -F _yaml_get_requires_core_list >/dev/null 2>&1; then
    assert_fail "[SPEC-0] _yaml_get_requires_core_list is unavailable" \
        "the manifest parser moved; every assertion below would compare empty to empty"
    _PARSER_OK=0
else
    assert_pass "[SPEC-0] the parser is loaded"
fi

# ─── Helpers (duplicated on purpose — this file stands alone) ───────────────
_PARSE_DIR="$TEST_TEMP_DIR/parse"
mkdir -p "$_PARSE_DIR"
# _parsed <name> <yaml> — the parser's output for a manifest fragment, comma-joined.
_parsed() {
    printf '%s\n' "$2" > "$_PARSE_DIR/$1.yaml"
    _yaml_get_requires_core_list "$_PARSE_DIR/$1.yaml" | tr '\n' ',' | sed 's/,$//'
}

# _fixture <name> <requires-core-block> <plugin.sh body> — a real kind:agent
# plugin directory, so SPEC-8 can go end-to-end through validate_manifest.
_FX_ROOT="$TEST_TEMP_DIR/plugins/agent"
_fixture() {
    local name="$1" req="$2" body="$3"
    local d="$_FX_ROOT/$name"
    mkdir -p "$d"
    {
        printf 'id: %s\n' "$name"
        printf 'name: %s\n' "$name"
        printf 'kind: agent\n'
        printf 'version: 0.1.0\n'
        printf 'hooks:\n  run: %s_run\n' "${name//-/_}"
        printf '%s\n' "$req"
    } > "$d/manifest.yaml"
    printf '%s\n' "$body" > "$d/plugin.sh"
    printf '%s' "$d"
}

# _validate_err <plugin_dir> — validate_manifest's stderr with `rc=N` appended.
_validate_err() {
    local out rc
    out="$(validate_manifest "$1/manifest.yaml" 2>&1)"; rc=$?
    printf '%s\nrc=%s\n' "$out" "$rc"
}

# _unresolved_entries <plugin_dir> — ONLY the entry names, comma-joined.
# Never assert against the raw resolver output with a bare entry name: the
# REASON text names provider paths, so `core/router/route.sh` contains the
# substring "router". A `grep router` on the whole line passes when some OTHER
# entry is the unresolved one — a false green this suite actually hit.
_unresolved_entries() {
    requires_core_unresolved "$1" | cut -f1 | tr '\n' ',' | sed 's/,$//'
}

print_test_section "[SPEC-1..6] list shapes the parser must read whole"


assert_eq "[SPEC-1] a comment BETWEEN entries does not end the list" \
    "redaction,event-bus,router" \
    "$(_parsed mid-comment 'requires:
  core:
    - redaction
    # a rationale comment
    - event-bus
    - router')"

assert_eq "[SPEC-2] a blank line between entries does not end the list" \
    "redaction,event-bus,router" \
    "$(_parsed mid-blank 'requires:
  core:
    - redaction

    - event-bus
    - router')"

assert_eq "[SPEC-3] a comment BEFORE the first entry does not empty the list" \
    "redaction,event-bus" \
    "$(_parsed lead-comment 'requires:
  core:
    # why we need these
    - redaction
    - event-bus')"

assert_eq "[SPEC-4] the inline form still parses" \
    "redaction,event-bus,router" \
    "$(_parsed inline 'requires:
  core: [redaction, event-bus, router]')"

assert_eq "[SPEC-5] a trailing comment on an entry is still stripped" \
    "redaction,router" \
    "$(_parsed trailing 'requires:
  core:
    - redaction   # ADR-004
    - router      # ADR-043')"

# Termination must survive the fix. Skipping comments must not let the block run
# on and sweep up `- ` items from a LATER list — `provides.events` is two lines
# of `- <name>` in almost every real manifest, and swallowing them would make
# every plugin declare a vocabulary of event names.
assert_eq "[SPEC-6] a sibling key still ends the block" \
    "redaction,event-bus" \
    "$(_parsed sibling-key 'requires:
  core:
    - redaction
    - event-bus
  plugins: []')"
assert_eq "[SPEC-6] a later top-level list is not swept into requires.core" \
    "redaction" \
    "$(_parsed later-list 'requires:
  core:
    - redaction
# a column-0 comment between the blocks
provides:
  events:
    - some.event
    - other.event')"

# The DoD sweep: every real manifest parses to the same set an INDEPENDENT
# reader finds. The reader below is deliberately a different mechanism — sed
# range addressing rather than an awk state machine — so it cannot share the
# bug under test. If the fix ever over-reaches, this is what says so.
_raw_core_entries() {
    sed -n '/^[[:space:]]*core:[[:space:]]*$/,/^[[:space:]]\{0,2\}[a-zA-Z_][a-zA-Z_]*:/p' "$1" \
        | sed -n 's/^[[:space:]]\{4,\}-[[:space:]]*//p' \
        | sed -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$'
}
# The population, found here rather than inherited — this file stands alone.
_REAL=()
while IFS= read -r _m; do _REAL+=("$_m"); done < <(
    find "$REPO_ROOT/plugins" -maxdepth 3 -name manifest.yaml -type f | sort
)
_sweep_diff=""
_sweep_n=0
for _m in "${_REAL[@]}"; do
    # Inline-form manifests have no `- ` lines for the independent reader to
    # find; they are covered by the inline assertion above.
    grep -qE '^[[:space:]]*core:[[:space:]]*$' "$_m" || continue
    _sweep_n=$((_sweep_n + 1))
    _got="$(_yaml_get_requires_core_list "$_m" | tr '\n' ',')"
    _want="$(_raw_core_entries "$_m" | tr '\n' ',')"
    [[ "$_got" == "$_want" ]] || \
        _sweep_diff="${_sweep_diff:+$_sweep_diff; }${_m#"$REPO_ROOT"/}: parsed[$_got] raw[$_want]"
done
if [[ "$_PARSER_OK" -ne 1 ]]; then
    : # SPEC-0 already failed; an empty sweep is not evidence of agreement
elif [[ "${#_REAL[@]}" -eq 0 ]]; then
    assert_fail "[SPEC-7][vacuity] find returned no manifests" \
        "the population is empty; the sweep asserted nothing"
elif [[ "$_sweep_n" -eq 0 ]]; then
    assert_fail "[SPEC-7][vacuity] no manifest used the multi-line core: form" \
        "the sweep compared nothing"
elif [[ -z "$_sweep_diff" ]]; then
    assert_pass "[SPEC-7] all $_sweep_n multi-line manifests parse to the independently-read entry set"
else
    assert_fail "[SPEC-7] the parser and an independent reader disagree about a real manifest" \
        "$_sweep_diff"
fi

# ─── SPEC-8: the bite — a truncated declaration must still be enforced ────
# THE assertion for #2065's soundness. `router` sits after a comment, and
# plugin.sh sources nothing. With the truncating parser the resolver never sees
# `router` and reports a clean plugin; the declaration is unenforceable exactly
# because it is declared.
_REQ_COMMENTED='requires:
  core:
    - redaction
    # the router is needed for the T2 judgement call below
    - router'
# Calls the router, sources nothing — the shape test-author had when #2060 was
# filed. Single-quoted on purpose: this is plugin.sh SOURCE TEXT, and expanding
# $_P_ROOT here would rewrite the line under test.
_BODY_CALLS_NO_SOURCE='#!/usr/bin/env bash
_P_ROOT=/nonexistent
response="$(route_to_model "T2" "$prompt")"'
_fx_truncated="$(_fixture comment-truncated "$_REQ_COMMENTED" "$_BODY_CALLS_NO_SOURCE")"
assert_contains "[SPEC-8] 'router' declared after a comment is still resolved, and refused" \
    ",$(_unresolved_entries "$_fx_truncated")," ",router,"
_out="$(_validate_err "$_fx_truncated")"
if [[ "$_out" == *"rc=0"* ]]; then
    assert_fail "[SPEC-8] validate_manifest must refuse a commented-list plugin that loads no router" \
        "a comment in the list made the declaration invisible; output: ${_out//$'\n'/ }"
else
    assert_contains "[SPEC-8] the refusal names router" "$_out" "requires.core 'router'"
fi

# ─── SPEC-9: the asymmetry that hid the bug ───────────────────────────────
# A comment AFTER `- redaction` leaves the ADR-004 literal check satisfied, so
# the manifest validated while the rest of the declaration silently vanished.
# Both halves are asserted: the ADR-004 check still passes (it always did), AND
# the entries after the comment are now present.
assert_contains "[SPEC-9] redaction survives a following comment (the half that always worked)" \
    "$(_parsed asymmetry 'requires:
  core:
    - redaction
    # comment
    - event-bus
    - router')" "redaction"
assert_contains "[SPEC-9] and so does everything after it (the half that did not)" \
    "$(_parsed asymmetry 'requires:
  core:
    - redaction
    # comment
    - event-bus
    - router')" "router"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
