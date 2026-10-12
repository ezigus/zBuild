#!/usr/bin/env bash
# tests/unit/run-limit-precedence-test.sh — run-level wall-clock limit (#1944)
#
# SPEC-2 [code]:
#   _runner_resolve_run_limit_s resolves template max_run_s > ZBUILD_MAX_RUN_S >
#   20700; a non-integer or non-positive value in template or env yields
#   disposition misconfigured and the run does not reach the dispatch loop.
#
# SPEC-5 [no-code]:
#   The limit is resolved from template, env, or constant only; scripts/lib/
#   stage-limits.sh and core/pipeline/runner.sh contain no reference to
#   GITHUB_ACTIONS, CI, or any platform-specific variable in the new code.
#
# SPEC-6 [no-code]:
#   ADR-025 names timed_out in its word vocabulary with ## Enforced by entries
#   citing the new tests; ADR-054 gains a §11 for the run-level limit with
#   ## Enforced by; config/adr-enforcement-baseline.txt no longer lists
#   ADR-054-stage-contract.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-limit-precedence: max_run_s resolution + platform-free + ADR alignment (#1944)"
setup_test_env "run-limit-precedence"

RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
STAGE_LIMITS="$REPO_ROOT/scripts/lib/stage-limits.sh"

# ─── SPEC-2: _runner_resolve_run_limit_s ────────────────────────────────────

print_test_section "[#1944/SPEC-2] _runner_resolve_run_limit_s is defined in stage-limits.sh"

# shellcheck source=../../scripts/lib/stage-limits.sh
source "$STAGE_LIMITS" 2>/dev/null || true

if declare -F _runner_resolve_run_limit_s >/dev/null 2>&1; then
    assert_pass "[#1944/SPEC-2] _runner_resolve_run_limit_s is defined in stage-limits.sh"
else
    assert_fail "[#1944/SPEC-2] _runner_resolve_run_limit_s is defined in stage-limits.sh" \
        "function not found after sourcing scripts/lib/stage-limits.sh"
fi

print_test_section "[#1944/SPEC-2] precedence: template max_run_s > ZBUILD_MAX_RUN_S > 20700"

if declare -F _runner_resolve_run_limit_s >/dev/null 2>&1; then
    # Case 1: no template value, no env → falls back to default 20700
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf ''; }
    unset ZBUILD_MAX_RUN_S
    _runner_resolve_run_limit_s 2>/dev/null || true
    assert_eq "[#1944/SPEC-2] no template, no env → default 20700" "20700" "${_RUNNER_MAX_RUN_S:-}"

    # Case 2: env only → uses env
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf ''; }
    ZBUILD_MAX_RUN_S=3600
    _runner_resolve_run_limit_s 2>/dev/null || true
    assert_eq "[#1944/SPEC-2] env ZBUILD_MAX_RUN_S=3600 used when no template value" "3600" "${_RUNNER_MAX_RUN_S:-}"
    unset ZBUILD_MAX_RUN_S

    # Case 3: template value > env → template wins
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf '7200'; }
    ZBUILD_MAX_RUN_S=3600
    _runner_resolve_run_limit_s 2>/dev/null || true
    assert_eq "[#1944/SPEC-2] template value wins over ZBUILD_MAX_RUN_S" "7200" "${_RUNNER_MAX_RUN_S:-}"
    unset ZBUILD_MAX_RUN_S

    # Case 4: template value only (no env) → template wins over default
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf '1800'; }
    unset ZBUILD_MAX_RUN_S
    _runner_resolve_run_limit_s 2>/dev/null || true
    assert_eq "[#1944/SPEC-2] template value wins over default" "1800" "${_RUNNER_MAX_RUN_S:-}"
else
    assert_fail "[#1944/SPEC-2] precedence checks skipped — function not found" "missing implementation"
fi

print_test_section "[#1944/SPEC-2] non-integer / non-positive → misconfigured, rc=1"

if declare -F _runner_resolve_run_limit_s >/dev/null 2>&1; then
    # Non-integer in template
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf 'not-a-number'; }
    unset ZBUILD_MAX_RUN_S
    _rc2=0
    _runner_resolve_run_limit_s 2>/dev/null || _rc2=$?
    assert_eq "[#1944/SPEC-2] non-integer template value → rc=1" "1" "$_rc2"

    # Non-positive (zero) in template
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf '0'; }
    unset ZBUILD_MAX_RUN_S
    _rc2=0
    _runner_resolve_run_limit_s 2>/dev/null || _rc2=$?
    assert_eq "[#1944/SPEC-2] template value=0 → rc=1" "1" "$_rc2"

    # Negative in template
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf -- '-5'; }
    unset ZBUILD_MAX_RUN_S
    _rc2=0
    _runner_resolve_run_limit_s 2>/dev/null || _rc2=$?
    assert_eq "[#1944/SPEC-2] negative template value → rc=1" "1" "$_rc2"

    # Non-integer in ZBUILD_MAX_RUN_S
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf ''; }
    ZBUILD_MAX_RUN_S="thirty"
    _rc2=0
    _runner_resolve_run_limit_s 2>/dev/null || _rc2=$?
    assert_eq "[#1944/SPEC-2] non-integer ZBUILD_MAX_RUN_S → rc=1" "1" "$_rc2"
    unset ZBUILD_MAX_RUN_S

    # Non-positive in ZBUILD_MAX_RUN_S
    _RUNNER_MAX_RUN_S=""
    template_max_run_s() { printf ''; }
    ZBUILD_MAX_RUN_S=0
    _rc2=0
    _runner_resolve_run_limit_s 2>/dev/null || _rc2=$?
    assert_eq "[#1944/SPEC-2] ZBUILD_MAX_RUN_S=0 → rc=1" "1" "$_rc2"
    unset ZBUILD_MAX_RUN_S
else
    assert_fail "[#1944/SPEC-2] validation checks skipped — function not found" "missing implementation"
fi

print_test_section "[#1944/SPEC-2] misconfigured run: runner rejects invalid limit before dispatch"
# Run the actual runner with an invalid ZBUILD_MAX_RUN_S; it must exit non-zero
# before dispatching any stage (no stage marker written).
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-miscfg"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events-miscfg"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR" "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

# Minimal single-stage plugin
mock_plugin_factory "intake" "agent" 0 >/dev/null

MISCFG_OVERLAY="$(setup_git_temp_repo miscfg-run-limit)"
mkdir -p "$MISCFG_OVERLAY/.zbuild/templates"
cat > "$MISCFG_OVERLAY/.zbuild/templates/limit-single.yaml" <<'EOF'
id: limit-single
extends: simple
stages:
  - id: intake
    gate: auto
    io:
      destinations: [file]
      tail_lines: 50
EOF

STAGE_MARKER="$TEST_TEMP_DIR/stage-ran-marker"
cat > "$TEST_TEMP_DIR/plugins/agent/intake/plugin.sh" <<PLUG
intake_run() {
    : > "${STAGE_MARKER}"
    $(mock_v2_result_line intake)
    return 0
}
PLUG

set +e
ZBUILD_MAX_RUN_S="not-a-number" \
( cd "$MISCFG_OVERLAY" && bash "$RUNNER" --template limit-single --goal "test misconfigured limit" ) \
    >"$TEST_TEMP_DIR/miscfg.stdout" 2>"$TEST_TEMP_DIR/miscfg.stderr"
_miscfg_rc=$?
set -e

assert_eq "[#1944/SPEC-2] invalid ZBUILD_MAX_RUN_S → runner exits non-zero" "1" "$_miscfg_rc"
if [[ -e "$STAGE_MARKER" ]]; then
    assert_fail "[#1944/SPEC-2] stage did not run when limit is misconfigured" \
        "stage marker exists — dispatch loop was reached"
else
    assert_pass "[#1944/SPEC-2] stage did not run when limit is misconfigured"
fi

# Check pipeline-state.json reflects misconfigured disposition
_miscfg_sf="$ZBUILD_STATE_DIR/pipeline-state.json"
if [[ -f "$_miscfg_sf" ]]; then
    _miscfg_disp="$(jq -r '.disposition // empty' "$_miscfg_sf" 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-2] pipeline-state.json disposition=misconfigured" "misconfigured" "$_miscfg_disp"
else
    # State file may be absent if the runner refuses before creating it; check stderr instead
    if grep -qi "misconfigured\|invalid.*max_run_s\|max_run_s.*invalid\|non-integer\|non-positive\|max_run_s.*must be" \
            "$TEST_TEMP_DIR/miscfg.stderr" 2>/dev/null; then
        assert_pass "[#1944/SPEC-2] stderr explains misconfigured limit"
    else
        assert_fail "[#1944/SPEC-2] runner names misconfigured limit on stderr" \
            "stderr: $(head -c 400 "$TEST_TEMP_DIR/miscfg.stderr" 2>/dev/null)"
    fi
fi

# ─── SPEC-5: no platform-specific env vars in new limit code ────────────────

print_test_section "[#1944/SPEC-5] stage-limits.sh contains no GITHUB_ACTIONS or bare CI reference"

# GITHUB_ACTIONS check — never acceptable in limit resolution
_ga_count_sl="$(grep -c 'GITHUB_ACTIONS' "$STAGE_LIMITS" 2>/dev/null || true)"
assert_eq "[#1944/SPEC-5] stage-limits.sh: no GITHUB_ACTIONS reference" "0" "$_ga_count_sl"

# $CI or ${CI} in non-comment code lines in stage-limits.sh
_ci_sl="$(grep -v '^[[:space:]]*#' "$STAGE_LIMITS" 2>/dev/null | grep -cE '\$\{?CI\}?[^A-Za-z0-9_]' || true)"
assert_eq "[#1944/SPEC-5] stage-limits.sh: no bare \$CI in non-comment code" "0" "$_ci_sl"

# runner.sh: no GITHUB_ACTIONS in code lines (excluding pure comments)
_ga_rn="$(grep -v '^[[:space:]]*#' "$RUNNER" 2>/dev/null | grep -c 'GITHUB_ACTIONS' || true)"
assert_eq "[#1944/SPEC-5] runner.sh: no GITHUB_ACTIONS in code lines" "0" "$_ga_rn"

# ─── SPEC-6: ADR alignment ──────────────────────────────────────────────────

print_test_section "[#1944/SPEC-6] ADR-025 names timed_out in its word vocabulary"
ADR025="$REPO_ROOT/docs/adr/ADR-025-abort-propagation.md"

if [[ ! -f "$ADR025" ]]; then
    assert_fail "[#1944/SPEC-6] ADR-025 file exists" "not found: $ADR025"
else
    # The word vocabulary line lists the abort words; timed_out must be among them
    _vocab_line="$(grep -E '(sigint|sigterm|cycle_abort).*timed_out|timed_out.*(sigint|sigterm|cycle_abort)' \
        "$ADR025" 2>/dev/null || true)"
    if [[ -n "$_vocab_line" ]]; then
        assert_pass "[#1944/SPEC-6] ADR-025 word vocabulary includes timed_out"
    else
        assert_fail "[#1944/SPEC-6] ADR-025 word vocabulary includes timed_out" \
            "timed_out not found alongside sigint/sigterm/cycle_abort in ADR-025"
    fi

    # ## Enforced by section must cite the new test files
    _enf_sec="$(awk '/^## Enforced by/,0' "$ADR025" 2>/dev/null || true)"
    if grep -q "run-timed-out-test\|run-limit-precedence-test\|run-watchdog-clean-exit-test\|resume-after-run-timeout-test" \
            <<< "$_enf_sec" 2>/dev/null; then
        assert_pass "[#1944/SPEC-6] ADR-025 ## Enforced by cites new tests"
    else
        assert_fail "[#1944/SPEC-6] ADR-025 ## Enforced by cites new tests" \
            "none of the new test files referenced in ## Enforced by"
    fi
fi

print_test_section "[#1944/SPEC-6] ADR-054 has §11 for run-level limit with ## Enforced by"
ADR054="$REPO_ROOT/docs/adr/ADR-054-stage-contract.md"

if [[ ! -f "$ADR054" ]]; then
    assert_fail "[#1944/SPEC-6] ADR-054 file exists" "not found: $ADR054"
else
    # §11 must exist (run-level limit section)
    if grep -qE '§[[:space:]]*11\b|###[[:space:]]+11\.' "$ADR054" 2>/dev/null; then
        assert_pass "[#1944/SPEC-6] ADR-054 §11 exists"
    else
        assert_fail "[#1944/SPEC-6] ADR-054 §11 exists" \
            "no §11 heading found in ADR-054"
    fi

    # §11 area must have an ## Enforced by entry citing a run-limit test
    _adr054_enf="$(awk '/## Enforced by/,0' "$ADR054" 2>/dev/null || true)"
    if grep -q "run-limit-precedence-test\|run-timed-out-test\|run-watchdog-clean-exit-test\|resume-after-run-timeout-test" \
            <<< "$_adr054_enf" 2>/dev/null; then
        assert_pass "[#1944/SPEC-6] ADR-054 ## Enforced by cites run-limit tests"
    else
        assert_fail "[#1944/SPEC-6] ADR-054 ## Enforced by cites run-limit tests" \
            "no run-limit test referenced in ADR-054 ## Enforced by"
    fi
fi

print_test_section "[#1944/SPEC-6] config/adr-enforcement-baseline.txt does not list ADR-054-stage-contract.md"
BASELINE="$REPO_ROOT/config/adr-enforcement-baseline.txt"

if [[ ! -f "$BASELINE" ]]; then
    assert_fail "[#1944/SPEC-6] adr-enforcement-baseline.txt exists" "not found: $BASELINE"
else
    if grep -q 'ADR-054-stage-contract\.md' "$BASELINE" 2>/dev/null; then
        assert_fail "[#1944/SPEC-6] ADR-054-stage-contract.md removed from baseline" \
            "still listed in config/adr-enforcement-baseline.txt"
    else
        assert_pass "[#1944/SPEC-6] ADR-054-stage-contract.md removed from baseline"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
