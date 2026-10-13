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

# ─── SPEC-2: template_max_run_s() from the real template.sh ─────────────────
# This section sources the REAL template.sh to test its template_max_run_s()
# function directly. If template.sh is reverted (function removed), the
# assert_fail below fires — making template.sh testable.
print_test_section "[#1944/SPEC-2] template_max_run_s() reads max_run_s from template YAML (real function)"
TEMPLATE_SH="$REPO_ROOT/core/pipeline/template.sh"

# shellcheck source=../../core/pipeline/template.sh
source "$TEMPLATE_SH" 2>/dev/null || true

# Build two YAML fixtures: one WITH max_run_s, one WITHOUT
_tpl_yaml="$TEST_TEMP_DIR/max-run-test.yaml"
cat > "$_tpl_yaml" <<'EOF'
id: max-run-test
max_run_s: 3600
extends: simple
EOF

_tpl_none="$TEST_TEMP_DIR/no-max-run.yaml"
cat > "$_tpl_none" <<'EOF'
id: no-max-run-test
extends: simple
EOF

if declare -F template_max_run_s >/dev/null 2>&1; then
    # Real function from template.sh: must extract the value from the YAML.
    _TPL_SOURCE_FILE="$_tpl_yaml"
    _tmr="$(template_max_run_s 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-2] template_max_run_s() returns max_run_s value from YAML" "3600" "$_tmr"

    # When max_run_s is absent, function returns empty (no override)
    _TPL_SOURCE_FILE="$_tpl_none"
    _tmr_empty="$(template_max_run_s 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-2] template_max_run_s() returns empty when max_run_s absent" "" "$_tmr_empty"
    unset _TPL_SOURCE_FILE
else
    assert_fail "[#1944/SPEC-2] template_max_run_s() defined in core/pipeline/template.sh" \
        "function not found after sourcing template.sh — implementation missing or template.sh reverted"
fi

print_test_section "[#1944/SPEC-2] misconfigured run (invalid ZBUILD_MAX_RUN_S): runner rejects before dispatch"
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

# Run with invalid env var — must fail before dispatch loop
_miscfg_rc=0
( cd "$MISCFG_OVERLAY" && ZBUILD_MAX_RUN_S="not-a-number" bash "$RUNNER" \
    --template limit-single --goal "test misconfigured limit" ) \
    >"$TEST_TEMP_DIR/miscfg.stdout" 2>"$TEST_TEMP_DIR/miscfg.stderr" \
    || _miscfg_rc=$?

assert_eq "[#1944/SPEC-2] invalid ZBUILD_MAX_RUN_S → runner exits non-zero" "1" "$_miscfg_rc"
if [[ -e "$STAGE_MARKER" ]]; then
    assert_fail "[#1944/SPEC-2] stage did not run when env limit is misconfigured" \
        "stage marker exists — dispatch loop was reached"
else
    assert_pass "[#1944/SPEC-2] stage did not run when env limit is misconfigured"
fi

# Check that misconfigured is explained (state file OR stderr)
_miscfg_sf="$ZBUILD_STATE_DIR/pipeline-state.json"
if [[ -f "$_miscfg_sf" ]]; then
    _miscfg_disp="$(jq -r '.disposition // empty' "$_miscfg_sf" 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-2] pipeline-state.json disposition=misconfigured (env)" "misconfigured" "$_miscfg_disp"
else
    _miscfg_err="$(cat "$TEST_TEMP_DIR/miscfg.stderr" 2>/dev/null || true)"
    if grep -qi "misconfigured\|invalid.*max_run_s\|max_run_s.*invalid\|non-integer\|non-positive\|max_run_s.*must be" \
            <<< "$_miscfg_err" 2>/dev/null; then
        assert_pass "[#1944/SPEC-2] stderr explains misconfigured env limit"
    else
        assert_fail "[#1944/SPEC-2] runner names misconfigured env limit on stderr" \
            "stderr: $(head -c 400 "$TEST_TEMP_DIR/miscfg.stderr" 2>/dev/null)"
    fi
fi

# ─── SPEC-2 (template layer): runner rejects invalid template max_run_s ──────
# A template that contains `max_run_s: not-a-number` must make the runner
# abort with rc=1 before any stage dispatches. This exercises template.sh's
# template_max_run_s() function, which is called by _runner_resolve_run_limit_s.
print_test_section "[#1944/SPEC-2] misconfigured run (invalid template max_run_s): runner rejects before dispatch"

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-miscfg-tpl"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events-miscfg-tpl"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR"
unset ZBUILD_MAX_RUN_S

# Template with an invalid max_run_s value in the YAML.
# MUST use new-shape (flow: style): the old-shape merger strips top-level keys
# like max_run_s: when building the merged file (only stages:/stage_definitions:
# blocks are carried over from the per-repo file). New-shape copies the file
# verbatim, so max_run_s: not-a-number survives in _TPL_SOURCE_FILE.
cat > "$MISCFG_OVERLAY/.zbuild/templates/limit-bad-tpl.yaml" <<'EOF'
id: limit-bad-tpl
extends: simple
max_run_s: not-a-number
flow:
  - intake

intake:
  gate: auto
  io:
    destinations: [file]
    tail_lines: 50
EOF
(cd "$MISCFG_OVERLAY" && git add .zbuild && git commit -q -m "add limit-bad-tpl template") \
    >/dev/null 2>&1

STAGE_MARKER_TPL="$TEST_TEMP_DIR/stage-ran-marker-tpl"
cat > "$TEST_TEMP_DIR/plugins/agent/intake/plugin.sh" <<PLUG
intake_run() {
    : > "${STAGE_MARKER_TPL}"
    $(mock_v2_result_line intake)
    return 0
}
PLUG

_miscfg_tpl_rc=0
( cd "$MISCFG_OVERLAY" && bash "$RUNNER" \
    --template limit-bad-tpl --goal "test misconfigured template limit" ) \
    >"$TEST_TEMP_DIR/miscfg-tpl.stdout" 2>"$TEST_TEMP_DIR/miscfg-tpl.stderr" \
    || _miscfg_tpl_rc=$?

assert_eq "[#1944/SPEC-2] invalid template max_run_s → runner exits non-zero" "1" "$_miscfg_tpl_rc"
if [[ -e "$STAGE_MARKER_TPL" ]]; then
    assert_fail "[#1944/SPEC-2] stage did not run when template limit is misconfigured" \
        "stage marker exists — dispatch loop was reached"
else
    assert_pass "[#1944/SPEC-2] stage did not run when template limit is misconfigured"
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

# runner.sh: no bare $CI in non-comment code lines
_ci_rn="$(grep -v '^[[:space:]]*#' "$RUNNER" 2>/dev/null | grep -cE '\$\{?CI\}?[^A-Za-z0-9_]' || true)"
assert_eq "[#1944/SPEC-5] runner.sh: no bare \$CI in non-comment code" "0" "$_ci_rn"

# Additional platform-specific variables — none should appear in limit-resolution code
for _plat_var in TRAVIS CIRCLECI RUNNER_OS BUILD_BUILDID; do
    _cnt_sl="$(grep -c "$_plat_var" "$STAGE_LIMITS" 2>/dev/null || true)"
    assert_eq "[#1944/SPEC-5] stage-limits.sh: no $_plat_var reference" "0" "$_cnt_sl"
    _cnt_rn="$(grep -v '^[[:space:]]*#' "$RUNNER" 2>/dev/null | grep -c "$_plat_var" || true)"
    assert_eq "[#1944/SPEC-5] runner.sh: no $_plat_var in code lines" "0" "$_cnt_rn"
done

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

# ─── SPEC-6: run_end_words knows timed_out (run-open-items.sh) ──────────────
# run-open-items.sh adds timed_out to run_end_words. If reverted, the
# timed_out case falls through to a generic message that does not mention the
# wall-clock limit, and the assertion fails.
print_test_section "[#1944/SPEC-6] run_end_words timed_out describes the wall-clock limit"
RUN_OPEN_ITEMS="$REPO_ROOT/scripts/lib/run-open-items.sh"

# shellcheck source=../../scripts/lib/run-open-items.sh
source "$RUN_OPEN_ITEMS" 2>/dev/null || true

if declare -F run_end_words >/dev/null 2>&1; then
    _to_words="$(run_end_words timed_out 0 2>/dev/null || true)"
    if grep -qi 'wall-clock' <<< "$_to_words" 2>/dev/null; then
        assert_pass "[#1944/SPEC-6] run_end_words timed_out describes the wall-clock limit"
    else
        assert_fail "[#1944/SPEC-6] run_end_words timed_out describes the wall-clock limit" \
            "got: '${_to_words:-<empty>}' — timed_out case missing from run_end_words"
    fi
else
    assert_fail "[#1944/SPEC-6] run_end_words defined in run-open-items.sh" \
        "function not found after sourcing run-open-items.sh"
fi

# ─── SPEC-6: lint-adr-enforced-by passes ────────────────────────────────────
# Verifies every ## Enforced by citation in all ADRs (including ADR-025 and
# ADR-054) references a real file. Passes after this change (new test files
# exist); would fail if an ADR cited a test that did not exist yet.
print_test_section "[#1944/SPEC-6] lint-adr-enforced-by: all Enforced-by citations resolve"
_adr_lint_rc=0
bash "$REPO_ROOT/scripts/lib/lint-adr-enforced-by.sh" \
    >"$TEST_TEMP_DIR/adr-lint.stdout" 2>"$TEST_TEMP_DIR/adr-lint.stderr" \
    || _adr_lint_rc=$?
assert_eq "[#1944/SPEC-6] lint-adr-enforced-by passes (ADR citations all resolve)" \
    "0" "$_adr_lint_rc"

# ─── SPEC-6: lint-test-errexit passes (npm run lint subset) ─────────────────
# Verifies no new test file uses set -e mid-file (the pattern lint-test-errexit
# rejects). This is the specific lint check that failed in previous attempts
# when new test files had `set +e; ...; set -e` patterns. Running it here
# provides a direct assertion for the "npm run lint passes" clause of SPEC-6.
print_test_section "[#1944/SPEC-6] lint-test-errexit: no mid-file set -e in test files"
_errexit_rc=0
bash "$REPO_ROOT/scripts/lib/lint-test-errexit.sh" \
    >"$TEST_TEMP_DIR/errexit-lint.stdout" 2>"$TEST_TEMP_DIR/errexit-lint.stderr" \
    || _errexit_rc=$?
assert_eq "[#1944/SPEC-6] lint-test-errexit passes (no mid-file set -e, npm run lint subset)" \
    "0" "$_errexit_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
