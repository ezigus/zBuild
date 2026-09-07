#!/usr/bin/env bash
# tests/unit/plugin-route-source-guard-test.sh
# A plugin that calls route_to_model must source core/router/route.sh (#2063).
#
# This is tests/unit/route-missing-include-test.sh (#1624) pointed the other way.
# That file guards route.sh's own base includes — one bad library there takes
# down all dispatch. This one guards the edge above it: a plugin that names
# route_to_model but never loads the only file defining it. Production then has
# no such function and the stage silently does nothing, which is how #2060,
# #2061 and #2062 all shipped. The suite could not see it because every unit
# test defines its own route_to_model stub — the tests supply exactly the thing
# production is missing, so the router-absent path is never exercised.
#
# Like its sibling this is deliberately its own file rather than assertions
# bolted onto a crowded existing one: the wiring it asserts belongs to no single
# plugin, and core-router-route-test.sh already carries ~50 unrelated router
# tests whose sandbox leaks (#1644) would take this guard down with them.
#
# SPEC-1: every plugin.sh with a NON-COMMENT route_to_model reference sources
#         core/router/route.sh — and the failure NAMES the offending file
# SPEC-2: a comment-only mention (validate, deploy, the tool plugins) is not a call
# SPEC-3: the comment stripper is itself correct — a trailing comment on a real
#         call line still counts as code, `${#x}` is not a comment marker
# SPEC-4[vacuity]: the detector is not inert — the known callers are detected
# SPEC-5: the sourced path resolves to a real file, and the variable it
#         interpolates is assigned in the same file (#1771's class: a source
#         line pointing at a moved file passes a naive grep)
# SPEC-6[negative control]: synthetic plugins prove the guard fires — including
#         one whose ONLY mention of the path is a `# shellcheck source=`
#         directive, which a comment-blind grep would accept as the real thing
# SPEC-7: every manifest DECLARING `router` in requires.core has a sibling
#         plugin.sh that sources route.sh — the declaration side of SPEC-1
#
# Why both a call-site guard (SPEC-1) and a declaration guard (SPEC-7): they
# fail differently and neither subsumes the other.
#   - test-author's manifest declared `requires.core: [..., router]` all along
#     (#2060). The contract was right; only the source line was missing. SPEC-7
#     catches "declared but not loaded" however the call is written — through a
#     wrapper, through indirection, or from a lib the plugin sources later.
#   - security-lens is the converse: it calls route_to_model and sources
#     route.sh, but its manifest does NOT declare `router`. A declaration-only
#     guard is blind to that shape, so SPEC-1 stays.
# SPEC-7 is deliberately scoped to `router` and NOT generalised to the rest of
# requires.core. `redaction` is supplied TRANSITIVELY by route.sh (ADR-043,
# redaction-by-construction), and `state` names a DIRECTORY of five files with
# no single marker, so a naive path match reports most of the tree broken.
# `router` has exactly one file and no transitive provider, which is what makes
# it checkable statically without a resolver.
#
# BOUNDARY: this file is a STATIC guard only. `requires.core` is validated
# today only syntactically — core/plugin-registry/manifest-validation.sh:329-335
# checks the literal string `redaction` is present for kind: agent, and :422-444
# checks the block is a list. Nothing at dispatch resolves an entry to a module;
# it is the sole consumer, and neither the runner nor plugin-bootstrap.sh reads
# it. Resolving requires.core properly, and the runtime post-source marker
# check, are #2065 — not this file.
set -uo pipefail
# Deliberately NOT `set -e`: assert_fail returns non-zero when called without a
# detail argument, which under -e would abort before print_test_results — a
# failing test that exits 0. Same reason route-missing-include-test.sh omits it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

for _dep in scripts/lib/helpers.sh scripts/lib/test-helpers.sh; do
    if [[ ! -f "$REPO_ROOT/$_dep" ]]; then
        printf 'plugin-route-source-guard-test: required dependency missing: %s\n' \
            "$REPO_ROOT/$_dep" >&2
        exit 2
    fi
done
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin → route.sh source guard (#2063)"
setup_test_env "plugin-route-source-guard"

_ROUTER_LIB="core/router/route.sh"

# ─── The detector ────────────────────────────────────────────────────────────
# Every predicate below runs on the COMMENT-STRIPPED text, so a mention inside
# prose never counts as a call and a `# shellcheck source=` directive never
# counts as a source. Both halves matter: the first would flag the two plugins
# that document making no LLM calls, the second would clear a plugin that only
# tells shellcheck where the router lives.

# _strip_comments <file> — drop each line from the first `#` that opens a
# comment: one at line start, or preceded by whitespace. That predicate is what
# keeps `$#` and `${#arr[@]}` (preceded by `$` and `{`) out of it, and what
# keeps a trailing comment from erasing the code before it. Known limit: a `#`
# inside a quoted string ends the line early, which can only ever HIDE a call,
# never invent one — SPEC-3 pins the behaviour so it cannot rot unnoticed.
_strip_comments() {
    awk '{
        out = ""
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == "#") {
                p = (i == 1) ? "" : substr($0, i - 1, 1)
                if (i == 1 || p == " " || p == "\t") break
            }
            out = out c
        }
        print out
    }' "$1"
}

# _calls_router <file> — rc 0 when route_to_model survives comment stripping.
# Substring, not whole word: route_to_model_loop is the same function family
# from the same file, and build/design reach the router only through it.
#
# NOT `_strip_comments "$1" | grep -q`: under `set -o pipefail` an early-exiting
# grep SIGPIPEs the awk still writing, and awk's 141 becomes the pipeline's
# status — so the predicate returns FALSE on exactly the long files where the
# match came early. That silently un-detected impact/plugin.sh on the first
# run of this file (#1015's class). The substitution has no pipe to break.
_calls_router() {
    local _code
    _code="$(_strip_comments "$1")"
    grep -qF 'route_to_model' <<<"$_code"
}

# _router_source_line <file> — the `source`/`.` line loading route.sh, if any.
# Same no-pipe discipline as _calls_router: `| head -1` would SIGPIPE the grep.
_router_source_line() {
    local _code _hits
    _code="$(_strip_comments "$1")"
    _hits="$(grep -E "^[[:space:]]*(source|\.)[[:space:]]+.*${_ROUTER_LIB//./\\.}" \
        <<<"$_code")"
    [[ -n "$_hits" ]] && sed -n '1p' <<<"$_hits"
    return 0
}

_sources_router() {
    [[ -n "$(_router_source_line "$1")" ]]
}

# _scan <file...> — print every file that calls the router without loading it.
_scan() {
    local f
    for f in "$@"; do
        if _calls_router "$f" && ! _sources_router "$f"; then
            printf '%s\n' "$f"
        fi
    done
}

# The population under test: every plugin entrypoint in the tree.
_PLUGINS=()
while IFS= read -r _p; do _PLUGINS+=("$_p"); done < <(
    cd "$REPO_ROOT" && find plugins -name plugin.sh -type f | sort
)

# ─── SPEC-1: no plugin calls the router without loading it ───────────────────
# The offenders are NAMED. A bare non-zero exit would leave the operator with
# the same search this guard exists to spare them.
cd "$REPO_ROOT" || exit 2
_OFFENDERS="$(_scan "${_PLUGINS[@]}")"
# Vacuity: SPEC-4 guards the DETECTOR (a typo in _calls_router) by calling it on
# hardcoded paths; it never touches _PLUGINS, so it cannot see an empty
# POPULATION. Two different failure modes. Without this, a find that returns
# nothing — directory rename, path drift, a failed cd in the process
# substitution — passes SPEC-1 with "all 0 plugins", which is the free pass this
# whole guard exists to prevent.
if [[ "${#_PLUGINS[@]}" -eq 0 ]]; then
    assert_fail "[SPEC-1][vacuity] find returned no plugin.sh files" \
        "the population is empty; SPEC-1 asserted nothing"
elif [[ -z "$_OFFENDERS" ]]; then
    assert_pass "[SPEC-1] all ${#_PLUGINS[@]} plugins that call route_to_model source $_ROUTER_LIB"
else
    assert_fail "[SPEC-1] a plugin calls route_to_model without sourcing $_ROUTER_LIB" \
        "offenders: $(tr '\n' ' ' <<<"$_OFFENDERS")"
fi

# ─── SPEC-2: a comment-only mention is not a call ────────────────────────────
# validate and deploy say "No LLM calls (no route_to_model)" in their headers;
# the four tool plugins carry "NEVER call route_to_model". A comment-blind grep
# would demand all six source a router they must never use.
_COMMENT_ONLY=(
    plugins/agent/validate/plugin.sh
    plugins/agent/deploy/plugin.sh
    plugins/tool/test/plugin.sh
    plugins/tool/teardown/plugin.sh
    plugins/tool/hydrate/plugin.sh
    plugins/tool/persist/plugin.sh
)
for _f in "${_COMMENT_ONLY[@]}"; do
    if [[ ! -f "$_f" ]]; then
        assert_fail "[SPEC-2] fixture plugin missing: $_f" "the guard's own premise moved"
        continue
    fi
    # The premise: the file does mention route_to_model somewhere. If that
    # comment is ever deleted the assertion below becomes vacuous, so say so.
    if ! grep -qF 'route_to_model' "$_f"; then
        assert_fail "[SPEC-2] $_f no longer mentions route_to_model" \
            "drop it from _COMMENT_ONLY rather than leaving a vacuous case"
    elif _calls_router "$_f"; then
        assert_fail "[SPEC-2] a comment-only mention must not count as a call" \
            "$_f was read as a caller"
    else
        assert_pass "[SPEC-2] comment-only mention not counted as a call: $_f"
    fi
done

# ─── SPEC-3: the comment stripper is correct ─────────────────────────────────
# This guard is worth exactly what its stripper is worth. Strip too little and
# every documenting plugin is flagged; strip too much and a real call goes
# unseen and the whole file passes vacuously.
_strip_line() { printf '%s\n' "$1" > "$TEST_TEMP_DIR/line.sh"; _strip_comments "$TEST_TEMP_DIR/line.sh"; }

_S3_CODE=(
    'raw="$(route_to_model "$tier" "$prompt")"   # ADR-043: the router redacts'
    '    route_to_model "$tier" "$p" >/dev/null || rc=$?'
    'if [[ ${#specs[@]} -gt 0 ]]; then route_to_model "$t" "$p"; fi'
    'n=$#; route_to_model "T1" "$p"'
)
_S3_COMMENT=(
    '# No LLM calls (no route_to_model); kind:agent for guard parity'
    '    # #491: do NOT redirect route_to_model'"'"'s stderr — see ADR-015 §v4.'
    'source "$_ROOT/core/router/route.sh"   # route_to_model redacts (ADR-043)'
)
for _l in "${_S3_CODE[@]}"; do
    if grep -qF 'route_to_model' <<<"$(_strip_line "$_l")"; then
        assert_pass "[SPEC-3] survives stripping (code): ${_l:0:44}"
    else
        assert_fail "[SPEC-3] a real call must survive comment stripping" "line: $_l"
    fi
done
for _l in "${_S3_COMMENT[@]}"; do
    if grep -qF 'route_to_model' <<<"$(_strip_line "$_l")"; then
        assert_fail "[SPEC-3] a commented mention must not survive stripping" "line: $_l"
    else
        assert_pass "[SPEC-3] stripped away (comment): ${_l:0:44}"
    fi
done

# ─── SPEC-4[vacuity]: the detector is live ───────────────────────────────────
# Without this, a typo in _calls_router makes the caller set empty and SPEC-1
# passes for the worst possible reason — and it earned its keep on this file's
# first run, catching a SIGPIPE-under-pipefail bug in _calls_router that had
# silently dropped impact from the population. These seven call the router at
# d2db611; the three fixed by #2060/#2061/#2062 are deliberately NOT listed,
# because this file must not encode which side of those merges it sits on.
# review-report is absent on purpose too: it sources route.sh but reaches no
# route_to_model, and the guard is one-directional by design.
_KNOWN_CALLERS=(
    plugins/agent/build/plugin.sh
    plugins/agent/design/plugin.sh
    plugins/agent/impact/plugin.sh
    plugins/agent/monitor/plugin.sh
    plugins/agent/plan/plugin.sh
    plugins/agent/review-lens/plugin.sh
    plugins/agent/security-lens/plugin.sh
)
_undetected=""
for _f in "${_KNOWN_CALLERS[@]}"; do
    _calls_router "$_f" || _undetected="${_undetected:+$_undetected }$_f"
done
if [[ -z "$_undetected" ]]; then
    assert_pass "[SPEC-4] the detector finds all ${#_KNOWN_CALLERS[@]} known router callers"
else
    assert_fail "[SPEC-4] the detector missed a known router caller" "undetected: $_undetected"
fi

# ─── SPEC-5: the sourced path resolves, and its variable is real ─────────────
# A typo'd root variable (`$_BILD_ROOT/core/router/route.sh`), or route.sh
# moving out from under the eight plugins that name it, both leave a source
# line a naive grep is happy with and a runtime that loads nothing. #1771 is an
# open bug of exactly this class (a redaction fallback sourcing a file that is
# not there), so the positive-only form of this guard was rejected: SPEC-1 asks
# whether a source line exists, SPEC-5 asks whether it can work.
_bad_target=""
_bad_var=""
for _f in "${_PLUGINS[@]}"; do
    _line="$(_router_source_line "$_f")"
    [[ -z "$_line" ]] && continue
    _tail=""; _var=""
    if [[ "$_line" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/[^\"[:space:]]*route\.sh) ]]; then
        # `source "$_BUILD_ROOT/core/router/route.sh"` — repo-root anchored.
        _var="${BASH_REMATCH[1]}"; _tail="$REPO_ROOT${BASH_REMATCH[2]}"
    elif [[ "$_line" =~ \)(/[^\"[:space:]]*route\.sh) ]]; then
        # `source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../..."` —
        # anchored on the plugin's own directory.
        _tail="$REPO_ROOT/$(dirname "$_f")${BASH_REMATCH[1]}"
    else
        _bad_target="${_bad_target:+$_bad_target }$_f(unparsed)"
        continue
    fi
    # `${_f}`, not `$_f`: bash reads the bytes of a following non-ASCII arrow as
    # part of the name and dies `unbound variable` under set -u.
    [[ -f "$_tail" ]] || _bad_target="${_bad_target:+$_bad_target }${_f}->${_tail}"
    # An unassigned variable expands to nothing and the source silently targets
    # the wrong path. _ZBUILD_PLUGIN_ROOT is the exception: plugin-bootstrap.sh
    # sets it for every plugin, so it is never assigned in the plugin itself.
    if [[ -n "$_var" && "$_var" != "_ZBUILD_PLUGIN_ROOT" ]] \
        && ! grep -qE "^[[:space:]]*(local[[:space:]]+|export[[:space:]]+)?${_var}=" "$_f"; then
        _bad_var="${_bad_var:+$_bad_var }$_f(\$$_var)"
    fi
done
if [[ -z "$_bad_target" ]]; then
    assert_pass "[SPEC-5] every plugin's route.sh source line resolves to a real file"
else
    assert_fail "[SPEC-5] a route.sh source line points at a file that is not there" \
        "unresolved: $_bad_target"
fi
if [[ -z "$_bad_var" ]]; then
    assert_pass "[SPEC-5] every interpolated root variable is assigned in its own plugin"
else
    assert_fail "[SPEC-5] a route.sh source line interpolates an unassigned variable" \
        "unassigned: $_bad_var"
fi

# ─── SPEC-6[negative control]: the guard actually fires ──────────────────────
# SPEC-1 is an invariant, so on a healthy tree it passes without proving it
# CAN fail. These four fixtures do that on every run, so the guard cannot go
# green-but-inert after the three real offenders are fixed.
_fixture() {
    local name="$1"
    local body="$2"
    # Separate statements, not one `local a=.. b=..$a`: under `set -u` the later
    # initialiser is expanded before the earlier name is bound.
    local d="$TEST_TEMP_DIR/fx/$name"
    mkdir -p "$d"; printf '%s\n' "$body" > "$d/plugin.sh"; printf '%s' "$d/plugin.sh"
}
_fx_offender="$(_fixture offender \
'#!/usr/bin/env bash
_X_ROOT="$_ZBUILD_PLUGIN_ROOT"
response="$(route_to_model "T2" "$prompt")"')"
_fx_shellcheck_only="$(_fixture shellcheck-only \
'#!/usr/bin/env bash
_X_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/router/route.sh
response="$(route_to_model "T2" "$prompt")"')"
_fx_clean="$(_fixture clean \
'#!/usr/bin/env bash
_X_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/router/route.sh
source "$_X_ROOT/core/router/route.sh"
response="$(route_to_model "T2" "$prompt")"')"
_fx_documenting="$(_fixture documenting \
'#!/usr/bin/env bash
# Kind: tool  Tier: T0  (NO LLM calls — NEVER call route_to_model)
echo hi')"

assert_contains "[SPEC-6] a plugin calling the router unsourced is flagged, by name" \
    "$(_scan "$_fx_offender")" "$_fx_offender"
assert_contains "[SPEC-6] a bare '# shellcheck source=' directive does not satisfy the guard" \
    "$(_scan "$_fx_shellcheck_only")" "$_fx_shellcheck_only"
assert_eq "[SPEC-6] a plugin that sources route.sh is not flagged" \
    "" "$(_scan "$_fx_clean")"
assert_eq "[SPEC-6] a plugin that only documents making no LLM calls is not flagged" \
    "" "$(_scan "$_fx_documenting")"

# ─── SPEC-7: a declared router dependency must actually be loaded ────────────
# Read the declaration with the SAME parser manifest-validation.sh uses, so the
# guard cannot disagree with the validator about what a manifest says.
_undeclared_dep=""
if ! declare -f _yaml_get_requires_core_list >/dev/null 2>&1; then
    # shellcheck source=../../core/plugin-registry/manifest-validation.sh
    source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
fi
if ! declare -f _yaml_get_requires_core_list >/dev/null 2>&1; then
    assert_fail "[SPEC-7] _yaml_get_requires_core_list is unavailable" \
        "the manifest parser moved; SPEC-7 cannot run and must not pass silently"
else
    _declaring=()
    for _m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
        [[ -f "$_m" ]] || continue
        grep -Fxq "router" <<<"$(_yaml_get_requires_core_list "$_m")" || continue
        _declaring+=("$_m")
        _sib="$(dirname "$_m")/plugin.sh"
        _rel="${_sib#"$REPO_ROOT"/}"   # name them as SPEC-1 does, repo-relative
        if [[ ! -f "$_sib" ]]; then
            # kind:persona manifests are DATA with no plugin.sh; one declaring
            # `router` would be a manifest bug, so say so rather than skip.
            _undeclared_dep="${_undeclared_dep:+$_undeclared_dep }${_rel}(no plugin.sh)"
        elif ! _sources_router "$_sib"; then
            _undeclared_dep="${_undeclared_dep:+$_undeclared_dep }${_rel}"
        fi
    done
    if [[ -z "$_undeclared_dep" ]]; then
        assert_pass "[SPEC-7] all ${#_declaring[@]} manifests declaring requires.core router load it"
    else
        assert_fail "[SPEC-7] a manifest declares requires.core router but never sources $_ROUTER_LIB" \
            "declared-not-loaded: $_undeclared_dep"
    fi
    # Vacuity: an empty declaring set would pass the assertion above for the
    # worst reason. The count is not pinned — a new router plugin is expected.
    if [[ "${#_declaring[@]}" -gt 0 ]]; then
        assert_pass "[SPEC-7] the manifest parser found ${#_declaring[@]} router declarations"
    else
        assert_fail "[SPEC-7] no manifest declares requires.core router" \
            "the parse is inert; SPEC-7 asserted nothing"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
