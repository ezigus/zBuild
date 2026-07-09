#!/usr/bin/env bash
# Unit (#891): impact's per-stage router.max_turns is raised to 45 in
# standard.yaml. impact is the most tool-heavy stage (Reads every scope file +
# repo-wide greps); the generic 25 default starved it (max_turns reached on a
# trivial issue in dogfood run 20260615092055-4885). This pins the headroom.
# #1242: also pin the right-sized router.timeout_s (180→600) — the 45-turn T2
# (sonnet) job overran the T1-era 180s budget (rc=124, run 20260704195255); 600
# matches its comparable tool-heavy sibling `design`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: impact router.max_turns headroom (#891)"
setup_test_env "impact-max-turns-891"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# #979: standard.yaml retired; simple.yaml's `impact` stage carries the same
# router.max_turns:45 / timeout_s:600 headroom (both were right-sized together).
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1

assert_eq "impact router.max_turns is 45 (raised from the 25 default)" \
    "45" "$(template_stage_router_max_turns impact 2>/dev/null)"
# #1242: right-sized wall-clock budget — 600s (matches `design`), not the
# T1-era 180s that SIGTERM'd a 45-turn T2 job twice (rc=124).
assert_eq "impact router.timeout_s is 600 (right-sized 180→600, #1242)" \
    "600" "$(template_stage_router_timeout impact 2>/dev/null)"
# Guard the rationale: it must exceed the generic 25 default.
mt="$(template_stage_router_max_turns impact 2>/dev/null)"
if [[ "$mt" =~ ^[0-9]+$ ]] && (( mt > 25 )); then
    assert_pass "impact max_turns ($mt) > generic default (25)"
else
    assert_fail "impact max_turns should exceed 25" "got: $mt"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
