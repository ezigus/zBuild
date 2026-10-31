#!/usr/bin/env bash
# tests/unit/retired-retry-settings-test.sh — the retry settings that lived
# inside a stage are gone; the template's per-stage `retry:` is the only one
# (ADR-054 §6a, ADR-017, amended 2026-10-31, #2439).
#
# T1 [change] a template stage with router.max_iterations is refused, and the
#             message says why
# T2 [change] a template stage with router.retries is refused, and says why
# T3 [change] a plugin manifest declaring config.router.retries or
#             config.router.retry_on_exhaustion is refused
# T4 [change] no shipped template or manifest sets any of them
# T5 [change] the shipped templates write the retries that are not the default:
#             design retry: 2, build retry: 2
# T6 [change] the environment overrides are gone from the engine
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
print_test_header "retry settings inside a stage are retired (#2439)"
setup_test_env "retired-retry-settings"

_tpl() {   # <router key> <value> → the template file
    local f="$TEST_TEMP_DIR/t-$1.yaml"
    cat > "$f" <<YAML
id: t
name: t
defaults:
  strategy: fanout
flow:
  - one
one:
  roles: [r]
  router:
    $1: $2
YAML
    printf '%s' "$f"
}

# ── T1, T2 ───────────────────────────────────────────────────────────────────
for _k in max_iterations retries; do
    _out="$(load_template "$(_tpl "$_k" 2)" 2>&1)"; _rc=$?
    assert_eq "[T1/T2] router.$_k is refused" "yes" "$([[ $_rc -ne 0 ]] && echo yes || echo no)"
    assert_contains "[T1/T2] ...and the message names it" "$_out" "router.$_k"
    assert_contains "[T1/T2] ...and points at retry:" "$_out" "retry:"
done

# ── T3 ───────────────────────────────────────────────────────────────────────
for _k in timeout_s retries retry_on_exhaustion; do
    D="$TEST_TEMP_DIR/plugins/agent/p-$_k"; mkdir -p "$D"
    cat > "$D/manifest.yaml" <<MF
id: p-$_k
name: P
kind: agent
version: 0.0.1
hooks:
  run: p_run
requires:
  core:
    - redaction
provides:
  role: p
  result_contract: 3
config:
  router:
    $_k: 1
outputs:
  - id: r
    path: \${artifact_dir}/r.json
    type: json
    required: true
    primary: true
MF
    printf 'p_run() { :; }\n' > "$D/plugin.sh"
    _vm=0; validate_manifest "$D/manifest.yaml" >/dev/null 2>&1 || _vm=$?
    if [[ "$_k" == timeout_s ]]; then
        assert_eq "[T3] control: the same manifest with config.router.timeout_s is valid" "0" "$_vm"
    elif [[ $_vm -ne 0 ]]; then
        assert_pass "[T3] config.router.$_k is refused"
    else
        assert_fail "[T3] config.router.$_k is refused" "validate_manifest accepted it"
    fi
done

# ── T4 ───────────────────────────────────────────────────────────────────────
_hits=""
for _f in "$REPO_ROOT"/config/templates/*.yaml "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    _in_router=0
    while IFS= read -r _l; do
        if [[ "$_l" =~ ^[[:space:]]+router:[[:space:]]*(#.*)?$ ]]; then _in_router=1; continue; fi
        if (( _in_router )) && [[ "$_l" =~ ^[[:space:]]{0,2}[A-Za-z_] ]]; then _in_router=0; fi
        if (( _in_router )) && [[ "$_l" =~ ^[[:space:]]+(max_iterations|retries|retry_on_exhaustion): ]]; then
            _hits+="${_f#"$REPO_ROOT"/}: $_l"$'\n'
        fi
    done < "$_f"
done
assert_eq "[T4] no template or manifest sets a router call limit or call retry" "" "$_hits"

# ── T5 ───────────────────────────────────────────────────────────────────────
for _t in simple deployed; do
    load_template "$REPO_ROOT/config/templates/$_t.yaml" >/dev/null 2>&1
    assert_eq "[T5] $_t.yaml: design retry: 2" "2" "$(template_stage_retry design)"
    assert_eq "[T5] $_t.yaml: build retry: 2" "2" "$(template_stage_retry build)"
done

# ── T6 ───────────────────────────────────────────────────────────────────────
for _v in ZBUILD_ROUTER_MAX_ITERATIONS ZBUILD_ROUTER_RETRIES ZBUILD_ROUTER_RETRY_ON_EXHAUSTION \
          ZBUILD_DISPOSITION_REDISPATCH ZBUILD_LOOP_DIFF_CAP_CHARS ZBUILD_LOOP_BANNER_DEDUPE_MIN_CHARS; do
    if grep -rqF --exclude-dir=tests "$_v" "$REPO_ROOT/core" "$REPO_ROOT/scripts/lib" "$REPO_ROOT/plugins" --include='*.sh'; then
        assert_fail "[T6] $_v is gone from the engine" "still named in core/, scripts/lib/ or plugins/"
    else
        assert_pass "[T6] $_v is gone from the engine"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
