#!/usr/bin/env bash
# tests/unit/requires-core-resolution-test.sh
# `requires.core` entries resolve to something real, or the plugin is refused (#2065).
#
# `requires.core` was validated as TEXT and never resolved: the validator checked
# a kind:agent list contained the literal string `redaction` and that the block
# was a list. Nothing mapped an entry to a core module — which is how
# test-author, spec-coverage and spec-correspondence each declared
# `[redaction, event-bus, router]`, sourced none of them, and were dispatched
# anyway for months (#2060/#2061/#2062).
#
# Resolution is STATIC and at LOAD. A post-source `declare -F` inside
# plugin_hook_call would be a TAUTOLOGY for half the vocabulary: the engine shell
# already holds event-bus and all five core/state files and dispatch is a
# subshell of it, so it passes for free and blesses plugins depending on ambient
# engine functions. SPEC-8 pins that measurement. Full rationale — the three
# classes, the `state` decision, and the relationship to #2063 (call-site
# direction), #1321 (requires.plugins) and #2083 (the parser, fixed in this PR)
# — is in ADR-001 §"requires.core resolution" and requires-core.sh's header.
# Do not re-derive it here.
#
# The thirteen SPECs are banner-marked below in order; each banner carries its
# own reasoning, so there is no index here to drift out of step with them.
#
# The PARSER underneath all of this (`_yaml_get_requires_core_list`, #2083) is
# asserted in tests/unit/requires-core-parser-test.sh — split from this file
# when it passed CLAUDE.md's 500-line rule, and deliberately neither sourcing it
# nor sourced by it.
set -uo pipefail
# Deliberately NOT `set -e`: assert_fail returns non-zero when called without a
# detail argument, which under -e would abort before print_test_results.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

for _dep in scripts/lib/helpers.sh scripts/lib/test-helpers.sh; do
    if [[ ! -f "$REPO_ROOT/$_dep" ]]; then
        printf 'requires-core-resolution-test: required dependency missing: %s\n' \
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

print_test_header "requires.core resolution (#2065)"
setup_test_env "requires-core-resolution"

# ─── Precondition: the resolver API exists ──────────────────────────────────
# Without this, SPEC-9/11 and half of SPEC-12 PASS on a tree with no
# requires-core.sh at all: `command not found` makes their loops read nothing,
# so "no violations found" is indistinguishable from "nothing was looked at".
# Not hypothetical — this file did exactly that on its first, pre-implementation
# run, which is the green-but-inert class the whole issue is about.
_API_OK=1
for _fn in requires_core_vocabulary requires_core_marker requires_core_providers \
           requires_core_class requires_core_unresolved; do
    if ! declare -F "$_fn" >/dev/null 2>&1; then
        assert_fail "[SPEC-0] resolver API missing: $_fn" \
            "core/plugin-registry/requires-core.sh is not loaded; every resolver assertion below would pass by reading nothing"
        _API_OK=0
    fi
done
[[ "$_API_OK" -eq 1 ]] && assert_pass "[SPEC-0] the resolver API is loaded (5 functions)"

# ─── Fixture plumbing ───────────────────────────────────────────────────────
# A fixture is a real plugin directory: validate_manifest is the unit under
# test, so it must be fed a manifest it would accept but for the rule being
# probed. Everything except requires.core and the plugin.sh body is constant.
_FX_ROOT="$TEST_TEMP_DIR/plugins/agent"

# _fixture <name> <kind> <requires-core-block> <plugin.sh body>
# Prints the plugin dir. The requires block is inserted verbatim so a fixture
# can also omit `requires:` entirely (SPEC-10).
_fixture() {
    local name="$1" kind="$2" req="$3" body="$4"
    local d="$_FX_ROOT/$name"
    mkdir -p "$d"
    {
        printf 'id: %s\n' "$name"
        printf 'name: %s\n' "$name"
        printf 'kind: %s\n' "$kind"
        printf 'version: 0.1.0\n'
        printf 'hooks:\n  run: %s_run\n' "${name//-/_}"
        printf '%s\n' "$req"
    } > "$d/manifest.yaml"
    printf '%s\n' "$body" > "$d/plugin.sh"
    printf '%s' "$d"
}

# _validate_err <plugin_dir> — validate_manifest's stderr, rc appended as a
# final `rc=N` line so one capture carries both.
_validate_err() {
    local out rc
    out="$(validate_manifest "$1/manifest.yaml" 2>&1)"; rc=$?
    printf '%s\nrc=%s\n' "$out" "$rc"
}

# _unresolved_entries <plugin_dir> — ONLY the entry names, comma-joined.
# Never assert on the raw output with a bare entry name: the REASON text names
# provider paths, so `core/router/route.sh` contains "router". A `grep router`
# on the whole line passes when some OTHER entry is the unresolved one — a false
# green this suite actually hit. Assert on the field, not the prose.
_unresolved_entries() {
    requires_core_unresolved "$1" | cut -f1 | tr '\n' ',' | sed 's/,$//'
}

_REQ_ROUTER='requires:
  core:
    - redaction
    - router'
_REQ_REDACTION_ONLY='requires:
  core:
    - redaction'
_REQ_BANANA='requires:
  core:
    - redaction
    - banana'

# Bodies. Single-quoted on purpose: these are plugin.sh SOURCE TEXT, and the
# resolver reads source LINES, not a live shell — expanding $_P_ROOT here would
# rewrite the line under test. (SC2016 at `info`; the project lints at
# `--severity=warning` and does not scan tests/.)
_BODY_CALLS_NO_SOURCE='#!/usr/bin/env bash
_P_ROOT=/nonexistent
response="$(route_to_model "T2" "$prompt")"'
_BODY_CALLS_AND_SOURCES='#!/usr/bin/env bash
_P_ROOT=/nonexistent
source "$_P_ROOT/core/router/route.sh"
response="$(route_to_model "T2" "$prompt")"'
_BODY_NO_MODEL='#!/usr/bin/env bash
# Kind: tool discipline — NO LLM calls (never call route_to_model).
echo hi'
_BODY_DIRECT_REDACTION='#!/usr/bin/env bash
_P_ROOT=/nonexistent
source "$_P_ROOT/core/redaction/scope-redaction.sh"
prompt="$(apply_scope_redaction "$raw")"'

# ─── SPEC-1: the vocabulary is closed ───────────────────────────────────────
_fx_banana="$(_fixture banana-dep agent "$_REQ_BANANA" "$_BODY_NO_MODEL")"
_out="$(_validate_err "$_fx_banana")"
if [[ "$_out" == *"rc=0"* ]]; then
    assert_fail "[SPEC-1] an unknown requires.core entry must be refused" \
        "validate_manifest accepted 'banana'; output: ${_out//$'\n'/ }"
else
    assert_contains "[SPEC-1] an unknown requires.core entry is refused, named" \
        "$_out" "requires.core 'banana'"
    assert_contains "[SPEC-1] the refusal names the plugin" \
        "$_out" "banana-dep"
fi

# ─── SPEC-2: router declared, never loaded ──────────────────────────────────
# The exact shape of test-author at the moment #2060 was filed.
_fx_r_unloaded="$(_fixture router-unloaded agent "$_REQ_ROUTER" "$_BODY_CALLS_NO_SOURCE")"
_out="$(_validate_err "$_fx_r_unloaded")"
if [[ "$_out" == *"rc=0"* ]]; then
    assert_fail "[SPEC-2] 'router' declared but never sourced must be refused" \
        "validate_manifest accepted it; output: ${_out//$'\n'/ }"
else
    assert_contains "[SPEC-2] the refusal names the unresolved entry" "$_out" "requires.core 'router'"
    assert_contains "[SPEC-2] the refusal names the plugin" "$_out" "router-unloaded"
fi

# Three ways a naive matcher says yes to a file that loads nothing. Each is
# rejected by a different half of _requires_core_sources, and all three are
# asserted because a negative control showed the two halves do not cover the
# same fixtures:
#   1. a `# shellcheck source=` directive — the false accept the #2063 guard's
#      SPEC-6 rules out on the call-site side; the comment strip rejects it
#   2. a real source line for some OTHER library that names route.sh in a
#      TRAILING comment — clears the line anchor, killed by the strip
#   3. the path assigned to a variable and never sourced — survives the strip
#      because it is code, and only the `^source|.` line anchor rejects it
_BODY_SHELLCHECK_ONLY='#!/usr/bin/env bash
_P_ROOT=/nonexistent
# shellcheck source=../../../core/router/route.sh
response="$(route_to_model "T2" "$prompt")"'
_fx_sc_only="$(_fixture shellcheck-only agent "$_REQ_ROUTER" "$_BODY_SHELLCHECK_ONLY")"
assert_contains "[SPEC-2] a bare '# shellcheck source=' directive does not resolve 'router'" \
    ",$(_unresolved_entries "$_fx_sc_only")," ",router,"

_BODY_TRAILING_COMMENT='#!/usr/bin/env bash
_P_ROOT=/nonexistent
source "$_P_ROOT/scripts/lib/helpers.sh"   # not core/router/route.sh — see ADR-043
response="$(route_to_model "T2" "$prompt")"'
_fx_trailing="$(_fixture trailing-comment agent "$_REQ_ROUTER" "$_BODY_TRAILING_COMMENT")"
assert_contains "[SPEC-2] route.sh named only in a trailing comment does not resolve 'router'" \
    ",$(_unresolved_entries "$_fx_trailing")," ",router,"

_BODY_PATH_VAR='#!/usr/bin/env bash
_P_ROOT=/nonexistent
_ROUTER_LIB="$_P_ROOT/core/router/route.sh"
response="$(route_to_model "T2" "$prompt")"'
_fx_pathvar="$(_fixture path-var-only agent "$_REQ_ROUTER" "$_BODY_PATH_VAR")"
assert_contains "[SPEC-2] route.sh assigned to a variable but never sourced does not resolve 'router'" \
    ",$(_unresolved_entries "$_fx_pathvar")," ",router,"

# ─── SPEC-3: router declared and loaded ─────────────────────────────────────
_fx_r_loaded="$(_fixture router-loaded agent "$_REQ_ROUTER" "$_BODY_CALLS_AND_SOURCES")"
assert_contains "[SPEC-3] 'router' declared and sourced is accepted" \
    "$(_validate_err "$_fx_r_loaded")" "rc=0"

# ─── SPEC-4: reaches a model with no redactor anywhere on its path ──────────
# Declares redaction, calls route_to_model, sources nothing. Refused twice over
# (router unresolved AND redaction unresolved); SPEC-4 asserts the redaction
# half is one of the reasons, which SPEC-2's fixture cannot show.
_REQ_REDACT_NO_ROUTER='requires:
  core:
    - redaction
    - event-bus'
_fx_unredacted="$(_fixture unredacted-caller agent "$_REQ_REDACT_NO_ROUTER" "$_BODY_CALLS_NO_SOURCE")"
_out="$(_validate_err "$_fx_unredacted")"
if [[ "$_out" == *"rc=0"* ]]; then
    assert_fail "[SPEC-4] a model-reaching plugin with no redactor must be refused" \
        "validate_manifest accepted it; output: ${_out//$'\n'/ }"
else
    assert_contains "[SPEC-4] the refusal names redaction as the unresolved entry" \
        "$_out" "requires.core 'redaction'"
fi

# ─── SPEC-5: redaction satisfied transitively through route.sh (ADR-043) ────
# The trap. route.sh sources scope-redaction.sh by construction, so a plugin
# that names only the router HAS redaction. A rule that demanded a literal
# core/redaction/ source line would report most of plugins/agent broken.
assert_contains "[SPEC-5] sourcing route.sh satisfies 'redaction' transitively (ADR-043)" \
    "$(_validate_err "$_fx_r_loaded")" "rc=0"

# And the direct path still works for a plugin that redacts without routing.
_fx_direct="$(_fixture direct-redactor agent "$_REQ_REDACTION_ONLY" "$_BODY_DIRECT_REDACTION")"
assert_contains "[SPEC-5] sourcing scope-redaction.sh directly satisfies 'redaction'" \
    "$(_validate_err "$_fx_direct")" "rc=0"

# ─── SPEC-6: redaction is vacuous for a plugin that reaches no model ────────
_fx_no_model="$(_fixture no-model-agent agent "$_REQ_REDACTION_ONLY" "$_BODY_NO_MODEL")"
assert_contains "[SPEC-6] a kind:agent that reaches no model is not forced to load a redactor" \
    "$(_validate_err "$_fx_no_model")" "rc=0"

# The three real plugins of that shape, by name — if one of them ever starts
# calling the router this assertion is the thing that notices.
for _p in deploy validate review-aggregator; do
    _m="$REPO_ROOT/plugins/agent/$_p/manifest.yaml"
    if [[ ! -f "$_m" ]]; then
        assert_fail "[SPEC-6] fixture plugin missing: plugins/agent/$_p" "the premise moved"
        continue
    fi
    validate_manifest "$_m" >/dev/null 2>&1
    assert_eq "[SPEC-6] the real no-LLM agent still validates: $_p" "0" "$?"
done

# ─── SPEC-7: the transitive edge is real ────────────────────────────────────
_ROUTE_SH="$REPO_ROOT/core/router/route.sh"
_REDACT_SH="core/redaction/scope-redaction.sh"
if grep -qE "^[[:space:]]*(source|\.)[[:space:]]+.*${_REDACT_SH//./\\.}" "$_ROUTE_SH"; then
    assert_pass "[SPEC-7] core/router/route.sh sources $_REDACT_SH (ADR-043 by construction)"
else
    assert_fail "[SPEC-7] route.sh no longer sources $_REDACT_SH" \
        "SPEC-5 accepts 'redaction' on the strength of this edge; without it the resolver waves through unredacted plugins"
fi

# ─── SPEC-8: the engine-ambient measurement ─────────────────────────────────
# The whole "static, not runtime" decision rests on these being true. If the
# engine stops pre-loading them, the ambient classes in requires-core.sh are
# wrong and a runtime check would become the better instrument.
_RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
_MAPWU="$REPO_ROOT/core/pipeline/strategies/common.sh"
_missing_ambient=""
for _lib in core/event-bus/event-bus.sh core/state/atomic.sh core/state/layout.sh \
            core/state/resume.sh core/state/artifact-persist.sh core/state/issue-lock.sh; do
    grep -qE "^[[:space:]]*(source|\.)[[:space:]]+.*${_lib//./\\.}" "$_RUNNER" \
        || _missing_ambient="${_missing_ambient:+$_missing_ambient }$_lib"
done
if [[ -z "$_missing_ambient" ]]; then
    assert_pass "[SPEC-8] runner.sh pre-loads event-bus + all five core/state files into the dispatch shell"
else
    assert_fail "[SPEC-8] the engine no longer pre-loads a module requires-core.sh classes as ambient" \
        "not sourced by runner.sh: $_missing_ambient"
fi
if grep -qE "^[[:space:]]*source[[:space:]]+.*core/event-bus/event-bus\.sh" "$_MAPWU"; then
    assert_pass "[SPEC-8] the map work unit pre-loads event-bus too, so ambience holds on that arm"
else
    assert_fail "[SPEC-8] the map work unit no longer pre-loads event-bus" \
        "event-bus is classed ambient on the strength of reaching all four dispatch arms"
fi

# ─── SPEC-9: every marker is defined by the provider it is mapped to ────────
_bad_marker=""
_vocab_n=0
while IFS= read -r _entry; do
    [[ -n "$_entry" ]] && _vocab_n=$((_vocab_n + 1))
done < <(requires_core_vocabulary 2>/dev/null)
if [[ "$_vocab_n" -eq 0 ]]; then
    assert_fail "[SPEC-9][vacuity] the vocabulary is empty" \
        "nothing to check markers for; SPEC-9 would assert nothing"
fi
while IFS= read -r _entry; do
    [[ -n "$_entry" ]] || continue
    _mk="$(requires_core_marker "$_entry")"
    [[ -n "$_mk" ]] || continue          # `state` has no single marker, by decision
    _found=""
    while IFS= read -r _prov; do
        [[ -n "$_prov" ]] || continue
        grep -qE "^${_mk}\(\)" "$REPO_ROOT/$_prov" && _found=1
    done < <(requires_core_providers "$_entry")
    [[ -n "$_found" ]] || _bad_marker="${_bad_marker:+$_bad_marker }${_entry}:${_mk}"
done < <(requires_core_vocabulary)
if [[ "$_vocab_n" -eq 0 ]]; then
    : # already reported above; do not print a pass for an empty sweep
elif [[ -z "$_bad_marker" ]]; then
    assert_pass "[SPEC-9] every marker function ($_vocab_n entries) is defined by one of its declared providers"
else
    assert_fail "[SPEC-9] a marker function is not defined by any provider it is mapped to" \
        "drifted: $_bad_marker"
fi

# The matcher escapes only `.` when it interpolates a provider path into an ERE.
# Guarding the INPUT instead of escaping at the call site is a deliberate
# decision recorded in _requires_core_sources' header; this is the one line that
# makes it loud rather than latent.
_unsafe_prov=""
while IFS= read -r _entry; do
    [[ -n "$_entry" ]] || continue
    while IFS= read -r _prov; do
        [[ -n "$_prov" ]] || continue
        [[ "$_prov" =~ ^[A-Za-z0-9_/.-]+$ ]] || \
            _unsafe_prov="${_unsafe_prov:+$_unsafe_prov }${_entry}:${_prov}"
    done < <(requires_core_providers "$_entry")
done < <(requires_core_vocabulary)
if [[ -z "$_unsafe_prov" ]]; then
    assert_pass "[SPEC-9] every provider path is regex-safe for the matcher that consumes it"
else
    assert_fail "[SPEC-9] a provider path contains an ERE metacharacter the matcher does not escape" \
        "unsafe: $_unsafe_prov — escape it in _requires_core_sources, or rename the file"
fi

# ─── SPEC-10: ADR-004 is subsumed, not weakened ─────────────────────────────
_fx_no_redaction="$(_fixture no-redaction agent 'requires:
  core:
    - event-bus' "$_BODY_NO_MODEL")"
_out="$(_validate_err "$_fx_no_redaction")"
if [[ "$_out" == *"rc=0"* ]]; then
    assert_fail "[SPEC-10] a kind:agent omitting 'redaction' must still be refused (ADR-004)" \
        "validate_manifest accepted it; output: ${_out//$'\n'/ }"
else
    assert_contains "[SPEC-10] the ADR-004 refusal still names redaction" \
        "$_out" "requires.core 'redaction'"
fi
# kind:tool is exempt, as it always was.
_fx_tool="$(_fixture tool-no-redaction tool 'requires:
  core:
    - event-bus' "$_BODY_NO_MODEL")"
assert_contains "[SPEC-10] kind:tool is still exempt from the redaction declaration" \
    "$(_validate_err "$_fx_tool")" "rc=0"

# ─── SPEC-11: the real tree resolves clean ──────────────────────────────────
_REAL=()
while IFS= read -r _m; do _REAL+=("$_m"); done < <(
    find "$REPO_ROOT/plugins" -maxdepth 3 -name manifest.yaml -type f | sort
)
_unresolved=""
for _m in "${_REAL[@]}"; do
    _d="$(dirname "$_m")"
    _u="$(requires_core_unresolved "$_d" 2>/dev/null)"
    [[ -n "$_u" ]] && _unresolved="${_unresolved:+$_unresolved; }${_d#"$REPO_ROOT"/}: ${_u//$'\n'/, }"
done
if [[ "$_API_OK" -ne 1 ]]; then
    : # SPEC-0 already failed; an empty sweep here is not evidence of a clean tree
elif [[ "${#_REAL[@]}" -eq 0 ]]; then
    assert_fail "[SPEC-11][vacuity] find returned no manifests" \
        "the population is empty; SPEC-11 asserted nothing"
elif [[ -z "$_unresolved" ]]; then
    assert_pass "[SPEC-11] all ${#_REAL[@]} real manifests resolve every requires.core entry"
else
    assert_fail "[SPEC-11] a real plugin declares a requires.core entry it cannot resolve" \
        "$_unresolved"
fi
# Vacuity: the resolver must actually be parsing declarations, not returning
# empty because the parse broke. Count the manifests it reads a vocabulary
# entry out of — SPEC-11 passing with zero parsed declarations is the free pass.
_declaring=0
for _m in "${_REAL[@]}"; do
    [[ -n "$(_yaml_get_requires_core_list "$_m")" ]] && _declaring=$((_declaring + 1))
done
if [[ "$_declaring" -gt 0 ]]; then
    assert_pass "[SPEC-11] the resolver read requires.core out of $_declaring manifests"
else
    assert_fail "[SPEC-11] no manifest parsed a requires.core entry" \
        "the parse is inert; SPEC-11 asserted nothing"
fi

# ─── SPEC-12[negative control]: every rule is proven to fire ────────────────
# SPEC-1..SPEC-6 above are half positive and half negative already. What is NOT
# yet proven is that the RESOLVER (as opposed to validate_manifest's wrapper)
# reports the right entry for the right reason, and that the two lenient rules
# — transitive redaction and ambient event-bus/state — are lenient for a REASON
# rather than because the resolver returns empty for everything.
assert_contains "[SPEC-12] the resolver names 'router' for a declared-not-loaded router" \
    ",$(_unresolved_entries "$_fx_r_unloaded")," ",router,"
if [[ "$_API_OK" -eq 1 ]]; then
    assert_eq "[SPEC-12] the resolver returns nothing for a plugin that loads what it declares" \
        "" "$(requires_core_unresolved "$_fx_r_loaded")"
fi
# Leniency with a reason: an ambient entry resolves, a fabricated one does not.
# If the resolver were simply returning empty, the second of these would too.
_fx_ambient="$(_fixture ambient-only agent 'requires:
  core:
    - redaction
    - event-bus
    - state' "$_BODY_NO_MODEL")"
if [[ "$_API_OK" -eq 1 ]]; then
    assert_eq "[SPEC-12] engine-ambient entries resolve without a plugin-side source line" \
        "" "$(requires_core_unresolved "$_fx_ambient")"
fi
assert_contains "[SPEC-12] but a fabricated entry in the same manifest shape does not" \
    ",$(_unresolved_entries "$_fx_banana")," ",banana,"
# And the classes are distinct — if every entry were classed ambient, SPEC-2
# would pass for free.
assert_eq "[SPEC-12] 'router' is not classed engine-ambient" \
    "plugin-loaded" "$(requires_core_class router)"
assert_eq "[SPEC-12] 'state' is classed engine-ambient (the recorded decision)" \
    "engine-ambient" "$(requires_core_class state)"
assert_eq "[SPEC-12] 'redaction' is classed conditional (required only on a model-reaching path)" \
    "conditional" "$(requires_core_class redaction)"

# ─── SPEC-13: a declaration with no plugin.sh to load it from ───────────────
# The resolver deliberately does NOT skip a manifest with no plugin.sh.
# kind:persona (#1304) is DATA — no entrypoint, no hooks — so it can never
# source anything, and a persona declaring `router` is a manifest bug that can
# only ever be false. SPEC-11 sweeps the real tree but no real manifest reaches
# this branch, so without these it is unexecuted code in a validator that now
# refuses registration.
#
# Ordering, honestly: the branch is pre-existing code from this PR's first
# commit, so there is no red-before-green here — this closes a coverage gap.
# The assertions come from the contract above, not from reading the branch, and
# their bite comes from the negative controls that disable it. The two
# ACCEPTANCE halves matter as much as the refusal: a branch that rejected any
# unsatisfied entry on a plugin.sh-less manifest would stop every persona that
# ever grows a `requires:` block from registering.
print_test_section "[SPEC-13] a plugin-loaded entry where nothing can load it"

# _fixture_nosh <name> <requires-core-block> — a kind:persona plugin dir: a
# manifest and NO plugin.sh, which is what a persona actually is on disk.
_fixture_nosh() {
    local name="$1" req="$2"
    local d="$_FX_ROOT/$name"
    mkdir -p "$d"
    {
        printf 'id: %s\n' "$name"
        printf 'name: %s\n' "$name"
        printf 'kind: persona\n'
        printf 'version: 0.1.0\n'
        printf 'persona:\n  role: a reviewer\n  perspective: looks for defects\n'
        printf '%s\n' "$req"
    } > "$d/manifest.yaml"
    rm -f "$d/plugin.sh"
    printf '%s' "$d"
}

_fx_persona_router="$(_fixture_nosh persona-router 'requires:
  core:
    - router')"
assert_contains "[SPEC-13] a plugin-loaded entry with no plugin.sh is unresolved, named" \
    ",$(_unresolved_entries "$_fx_persona_router")," ",router,"
assert_contains "[SPEC-13] the reason says there is no plugin.sh to load it from" \
    "$(requires_core_unresolved "$_fx_persona_router")" "no plugin.sh"
_out="$(_validate_err "$_fx_persona_router")"
if [[ "$_out" == *"rc=0"* ]]; then
    assert_fail "[SPEC-13] validate_manifest must refuse it end-to-end" \
        "accepted a persona declaring a module it can never load; output: ${_out//$'\n'/ }"
else
    assert_contains "[SPEC-13] the refusal names the entry" "$_out" "requires.core 'router'"
fi

# Acceptance half 1: ambient entries need no plugin.sh — the engine supplies them.
_fx_persona_ambient="$(_fixture_nosh persona-ambient 'requires:
  core:
    - event-bus
    - state')"
assert_eq "[SPEC-13] engine-ambient entries are fine with no plugin.sh" \
    "" "$(_unresolved_entries "$_fx_persona_ambient")"
assert_contains "[SPEC-13] and the manifest still validates" \
    "$(_validate_err "$_fx_persona_ambient")" "rc=0"

# Acceptance half 2: `redaction` is conditional, and a manifest with no
# plugin.sh reaches no model, so it is vacuously satisfied — not a violation.
_fx_persona_redaction="$(_fixture_nosh persona-redaction 'requires:
  core:
    - redaction')"
assert_eq "[SPEC-13] a conditional entry is vacuous with no plugin.sh to reach a model" \
    "" "$(_unresolved_entries "$_fx_persona_redaction")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
