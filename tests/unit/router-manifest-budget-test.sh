#!/usr/bin/env bash
# tests/unit/router-manifest-budget-test.sh — #1816 (ADR-017 Amendment §11)
#
# A plugin may declare its own budget. `config.router.{timeout_s,max_turns,
# retries}` in the plugin's OWN manifest resolves as the DEFAULT — below the
# template accessor and the operator env knob, above the compile-time constant:
#
#   template accessor  >  env var  >  manifest config.router.*  >  constant
#
# The load-bearing guarantee is the LAST layer: a manifest that declares
# nothing must resolve byte-identically to the pre-#1816 engine. That is what
# keeps this one change rather than fourteen, so it is asserted first and for
# every knob.
#
# This file must NEVER export ZBUILD_PLUGIN_DIR as a stand-in for dispatch:
# the value under test is the one plugin_hook_call sets (#1862/ADR-054 §3).
# Here the env var is set EXPLICITLY per-assertion to isolate the resolution
# rule; that the engine actually sets it during a real dispatch is proved
# across the process boundary in tests/integration/router-manifest-budget-*.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# route.sh ONLY — deliberately not manifest-validation.sh. The reader has to
# arrive with the router, because _route_manifest_knob degrades to the constant
# when it is missing: a test that sourced it here would stay green with the
# manifest layer unreachable in production. SPEC-0 asserts the arrival.
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

print_test_header "router manifest budget — plugin-declared timeout_s/max_turns/retries (#1816)"

setup_test_env "router-manifest-budget"

# Nothing ambient may supply what is under test.
unset ZBUILD_PLUGIN_DIR ZBUILD_CURRENT_STAGE 2>/dev/null || true
unset ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_MAX_TURNS ZBUILD_ROUTER_RETRIES 2>/dev/null || true
unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE 2>/dev/null || true
# yaml_get memoizes per (file,key); fixtures below reuse paths across cases.
export ZBUILD_YAML_CACHE=0

# ─── Fixtures ────────────────────────────────────────────────────────────────
_FIX="$TEST_TEMP_DIR/plugins"
mkdir -p "$_FIX/declares" "$_FIX/silent" "$_FIX/partial" "$_FIX/malformed" "$_FIX/nested"

# Declares all three, and a tier_default above them — the manifest shape the
# issue describes: the reasoning and the number in the same file.
cat > "$_FIX/declares/manifest.yaml" <<'EOF'
id: declares
kind: agent
config:
  tier_default: T2
  router:
    timeout_s: 600
    max_turns: 45
    retries: 1
EOF

# Declares NO router block. This is the regression guard: every knob must
# resolve to the pre-#1816 compile-time constant.
cat > "$_FIX/silent/manifest.yaml" <<'EOF'
id: silent
kind: agent
config:
  tier_default: T1
EOF

# Declares one knob only — the other two still fall to the constant.
cat > "$_FIX/partial/manifest.yaml" <<'EOF'
id: partial
kind: agent
config:
  router:
    timeout_s: 900
EOF

# Out-of-range / non-numeric. validate_manifest is the loud gate (asserted
# below); the RESOLVER must not hand a garbage budget to the router.
cat > "$_FIX/malformed/manifest.yaml" <<'EOF'
id: malformed
kind: agent
config:
  router:
    timeout_s: soon
    max_turns: 9999
    retries: -3
EOF

# A `router:` key that is NOT under `config:` must not be read — the block is
# addressed by path, not by name.
cat > "$_FIX/nested/manifest.yaml" <<'EOF'
id: nested
kind: agent
router:
  timeout_s: 111
config:
  tier_default: T1
EOF

# The shape the issue actually asks for: the number and the reasoning in one
# place. Comments on the block headers, on the values, and a following
# top-level key that must close the block.
mkdir -p "$_FIX/commented"
cat > "$_FIX/commented/manifest.yaml" <<'EOF'
id: commented
kind: agent
config:   # my own defaults
  tier_default: T2
  router:  # #1242: T2 per-turn latency drove the wall clock up, not the flow
    timeout_s: 600   # matches `design`, the comparable tool-heavy T2 sibling
    max_turns: 45
provides:
  artifact_type: findings.json
  timeout_s: 7
EOF

# ─── SPEC-0 the reader arrives with the router ───────────────────────────────
print_test_section "[SPEC-0] sourcing route.sh alone provides the manifest reader"

if declare -F manifest_router_knob >/dev/null 2>&1; then
    assert_pass "route.sh brings manifest_router_knob by construction"
else
    assert_fail "route.sh brings manifest_router_knob by construction" \
        "the manifest layer would be inert in any process that sources only route.sh"
fi

# ─── SPEC-1 regression guard: a silent manifest resolves as it does today ────
print_test_section "[SPEC-1] a manifest with no config.router block is byte-identical to today"

assert_eq "timeout_s falls to the 300s constant" \
    "300" "$(ZBUILD_PLUGIN_DIR="$_FIX/silent" _route_resolve_timeout)"
assert_eq "max_turns falls to the 25 constant" \
    "25" "$(ZBUILD_PLUGIN_DIR="$_FIX/silent" _route_resolve_max_turns)"
assert_eq "retries falls to the 0 constant (opt-in, unchanged)" \
    "0" "$(ZBUILD_PLUGIN_DIR="$_FIX/silent" _route_resolve_retries)"

# The no-dispatch case: nothing set ZBUILD_PLUGIN_DIR at all (direct router
# use, a test, a non-plugin caller). Same constants, no error.
assert_eq "no ZBUILD_PLUGIN_DIR at all → 300s constant" \
    "300" "$(_route_resolve_timeout)"
assert_eq "no ZBUILD_PLUGIN_DIR at all → 25 constant" \
    "25" "$(_route_resolve_max_turns)"
assert_eq "no ZBUILD_PLUGIN_DIR at all → 0 constant" \
    "0" "$(_route_resolve_retries)"

# A ZBUILD_PLUGIN_DIR that exists but holds no manifest must not error either.
assert_eq "ZBUILD_PLUGIN_DIR without a manifest.yaml → constant, no failure" \
    "300" "$(ZBUILD_PLUGIN_DIR="$TEST_TEMP_DIR" _route_resolve_timeout)"

# ─── SPEC-2 the manifest replaces the constant ───────────────────────────────
print_test_section "[SPEC-2] config.router.* is read as the default"

assert_eq "manifest timeout_s beats the 300s constant" \
    "600" "$(ZBUILD_PLUGIN_DIR="$_FIX/declares" _route_resolve_timeout)"
assert_eq "manifest max_turns beats the 25 constant" \
    "45" "$(ZBUILD_PLUGIN_DIR="$_FIX/declares" _route_resolve_max_turns)"
assert_eq "manifest retries beats the 0 constant" \
    "1" "$(ZBUILD_PLUGIN_DIR="$_FIX/declares" _route_resolve_retries)"

assert_eq "a partial declaration leaves the undeclared knobs on the constant" \
    "900|25|0" \
    "$(printf '%s|%s|%s' \
        "$(ZBUILD_PLUGIN_DIR="$_FIX/partial" _route_resolve_timeout)" \
        "$(ZBUILD_PLUGIN_DIR="$_FIX/partial" _route_resolve_max_turns)" \
        "$(ZBUILD_PLUGIN_DIR="$_FIX/partial" _route_resolve_retries)")"

assert_eq "a top-level router: block is NOT the plugin's declaration" \
    "300" "$(ZBUILD_PLUGIN_DIR="$_FIX/nested" _route_resolve_timeout)"

assert_eq "comments on config:/router:/the value do not hide the declaration" \
    "600" "$(ZBUILD_PLUGIN_DIR="$_FIX/commented" _route_resolve_timeout)"
assert_eq "a later top-level key closes the block (provides.timeout_s is not it)" \
    "45" "$(ZBUILD_PLUGIN_DIR="$_FIX/commented" _route_resolve_max_turns)"
assert_eq "an undeclared knob in a commented block still falls to the constant" \
    "0" "$(ZBUILD_PLUGIN_DIR="$_FIX/commented" _route_resolve_retries)"

# ─── SPEC-3 env beats the manifest ───────────────────────────────────────────
print_test_section "[SPEC-3] the operator env knob still wins over the manifest"

assert_eq "ZBUILD_ROUTER_TIMEOUT beats manifest timeout_s" \
    "42" "$(ZBUILD_PLUGIN_DIR="$_FIX/declares" ZBUILD_ROUTER_TIMEOUT=42 _route_resolve_timeout)"
assert_eq "ZBUILD_ROUTER_MAX_TURNS beats manifest max_turns" \
    "7" "$(ZBUILD_PLUGIN_DIR="$_FIX/declares" ZBUILD_ROUTER_MAX_TURNS=7 _route_resolve_max_turns)"
assert_eq "ZBUILD_ROUTER_RETRIES beats manifest retries" \
    "3" "$(ZBUILD_PLUGIN_DIR="$_FIX/declares" ZBUILD_ROUTER_RETRIES=3 _route_resolve_retries)"

# ─── SPEC-4 template beats the manifest ──────────────────────────────────────
print_test_section "[SPEC-4] the template accessor still wins over the manifest"

# Stand in for template.sh's accessors: _route_resolve_knob calls whatever
# function name it is handed, exactly as the real accessors are called.
template_stage_router_timeout()   { printf '111\n'; }
template_stage_router_max_turns() { printf '12\n'; }
template_stage_router_retries()   { printf '5\n'; }

assert_eq "template timeout_s wins over manifest timeout_s" \
    "111" "$(ZBUILD_CURRENT_STAGE=fixture ZBUILD_PLUGIN_DIR="$_FIX/declares" _route_resolve_timeout)"
assert_eq "template max_turns wins over manifest max_turns" \
    "12" "$(ZBUILD_CURRENT_STAGE=fixture ZBUILD_PLUGIN_DIR="$_FIX/declares" _route_resolve_max_turns)"
assert_eq "template retries wins over manifest retries" \
    "5" "$(ZBUILD_CURRENT_STAGE=fixture ZBUILD_PLUGIN_DIR="$_FIX/declares" _route_resolve_retries)"

# ─── SPEC-5 the env-vs-template audit event is unchanged ─────────────────────
print_test_section "[SPEC-5] router.*.override_ignored still fires for env-vs-template"

_EV_LOG="$TEST_TEMP_DIR/override-events.txt"
: > "$_EV_LOG"
eb_emit_event() { printf '%s\n' "$*" >> "$_EV_LOG"; }

ZBUILD_CURRENT_STAGE=fixture ZBUILD_PLUGIN_DIR="$_FIX/declares" \
    ZBUILD_ROUTER_TIMEOUT=999 _route_resolve_timeout >/dev/null
assert_contains "env-vs-template override_ignored event still emitted" \
    "$(cat "$_EV_LOG")" "router.timeout.override_ignored"
assert_contains "the event reports the applied (template) value" \
    "$(cat "$_EV_LOG")" "applied=111"

# A manifest value LOSING to env or template is not an override_ignored case:
# the manifest is the default, and a default being replaced is the design.
: > "$_EV_LOG"
ZBUILD_PLUGIN_DIR="$_FIX/declares" ZBUILD_ROUTER_TIMEOUT=999 _route_resolve_timeout >/dev/null
assert_eq "manifest-loses-to-env emits no override_ignored event" \
    "" "$(cat "$_EV_LOG")"

unset -f template_stage_router_timeout template_stage_router_max_turns \
    template_stage_router_retries eb_emit_event

# ─── SPEC-6 a malformed declaration never reaches the router ─────────────────
print_test_section "[SPEC-6] malformed manifest values fall back, never propagate"

assert_eq "non-numeric timeout_s falls to the constant" \
    "300" "$(ZBUILD_PLUGIN_DIR="$_FIX/malformed" _route_resolve_timeout)"
assert_eq "out-of-range max_turns falls to the constant" \
    "25" "$(ZBUILD_PLUGIN_DIR="$_FIX/malformed" _route_resolve_max_turns)"
assert_eq "negative retries falls to the constant" \
    "0" "$(ZBUILD_PLUGIN_DIR="$_FIX/malformed" _route_resolve_retries)"

# ─── SPEC-7 the ADR-029 escalation override still outranks everything ────────
print_test_section "[SPEC-7] ZBUILD_ROUTER_MAX_TURNS_OVERRIDE still outranks all layers"

assert_eq "cycle-orchestrator escalation beats template, env AND manifest" \
    "88" "$(ZBUILD_PLUGIN_DIR="$_FIX/declares" ZBUILD_ROUTER_MAX_TURNS=7 \
        ZBUILD_ROUTER_MAX_TURNS_OVERRIDE=88 _route_resolve_max_turns)"

# ─── SPEC-8 the reader addresses the block by path ───────────────────────────
print_test_section "[SPEC-8] manifest_router_knob reads config.router.<knob>"

assert_eq "reads a declared knob" \
    "600" "$(manifest_router_knob "$_FIX/declares/manifest.yaml" timeout_s)"
assert_eq "empty for an undeclared knob" \
    "" "$(manifest_router_knob "$_FIX/silent/manifest.yaml" timeout_s)"
assert_eq "empty for a missing file (no error)" \
    "" "$(manifest_router_knob "$TEST_TEMP_DIR/nope.yaml" timeout_s || true)"
assert_eq "does not read a top-level router: block" \
    "" "$(manifest_router_knob "$_FIX/nested/manifest.yaml" timeout_s)"
assert_eq "tier_default is not a router knob" \
    "" "$(manifest_router_knob "$_FIX/declares/manifest.yaml" tier_default)"

# ─── SPEC-9 validate_manifest is the loud gate ───────────────────────────────
print_test_section "[SPEC-9] validate_manifest accepts a well-formed block, rejects a malformed one"

_vm_n=0
_write_manifest() {  # <router-block-body> → manifest path
    local body="$1"
    _vm_n=$((_vm_n + 1))
    local dir="$TEST_TEMP_DIR/vm-$_vm_n"
    mkdir -p "$dir"
    {
        printf 'id: vm-fixture\nname: VM Fixture\nkind: tool\nversion: 0.0.1\n'
        printf 'summary: fixture\n'
        printf 'hooks:\n  run: vm_run\n'
        printf 'config:\n  router:\n%s' "$body"
    } > "$dir/manifest.yaml"
    printf '%s' "$dir/manifest.yaml"
}

_expect_valid() {  # <desc> <router-block-body>
    local desc="$1" mf; mf="$(_write_manifest "$2")"
    local out; out="$(validate_manifest "$mf" 2>&1)" && { assert_pass "$desc"; return 0; }
    assert_fail "$desc" "validate_manifest rejected it: $out"
}
_expect_invalid() {  # <desc> <router-block-body>
    local desc="$1" mf; mf="$(_write_manifest "$2")"
    if validate_manifest "$mf" >/dev/null 2>&1; then
        assert_fail "$desc" "validate_manifest accepted it"
    else
        assert_pass "$desc"
    fi
}

_expect_valid "accepts a well-formed config.router block" '    timeout_s: 600
    max_turns: 45
    retries: 1
'
_expect_invalid "rejects a non-numeric timeout_s" '    timeout_s: soon
'
_expect_invalid "rejects an out-of-range timeout_s (>3600)" '    timeout_s: 5000
'
_expect_invalid "rejects timeout_s: 0 (matches the template range 1..3600)" '    timeout_s: 0
'
_expect_invalid "rejects an out-of-range max_turns (>200)" '    max_turns: 9999
'
_expect_invalid "rejects an out-of-range retries (>10)" '    retries: 11
'
_expect_valid "accepts the 0 sentinels the template already accepts" '    max_turns: 0
    retries: 0
'
_expect_invalid "rejects an unknown key inside config.router (a typo is inert, not silent)" '    timeout: 600
'

# ─── SPEC-10 every shipped manifest still validates ──────────────────────────
print_test_section "[SPEC-10] every shipped plugin manifest still passes validate_manifest"

_bad=""
while IFS= read -r _mf; do
    validate_manifest "$_mf" >/dev/null 2>&1 || _bad+="${_mf#"$REPO_ROOT/"} "
done < <(find "$REPO_ROOT/plugins" -name manifest.yaml -type f | sort)
assert_eq "no shipped manifest is rejected by the new schema check" "" "$_bad"

print_test_results
exit $((FAIL > 0))
