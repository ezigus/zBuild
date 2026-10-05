#!/usr/bin/env bash
# tests/unit/no-fault-routing-test.sh — the engine no longer decides who owns a
# finding (#2271, ADR-068).
#
# Why: findings went back to the wrong stage regularly, because the engine
# guessed ownership — fault classes on gate results, a `route_back` jump from
# the build loop to the design loop, ownership framing in the summaries later
# stages read, and an escalation ladder in the acceptance check. Each misroute
# was fixed with another rule (#1777, #2157, #1847, #1846). Eric (2026-10-03):
# "much too complicated and wrong". Nested loops, numbered findings and answers
# replace all of it; this test keeps it gone.
#
# R1 [change] a template that declares `route_back` is refused, and the error
#             says the loops replace it
# R2 [change] no engine or plugin code reads or writes a fault class or a
#             route_back (comments aside)
# R3 [change] the summaries later stages read carry no ownership framing
#             ("yours to fix", "owned by", "has to change for this")
# R4 [guard]  the files that held the ownership and fault rules are gone
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the engine no longer decides who owns a finding (#2271)"
setup_test_env "no-fault-routing"

print_test_section "R1: route_back is refused"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
T="$TEST_TEMP_DIR/rb.yaml"
cat > "$T" <<'EOF'
id: rb
name: route_back
defaults:
  strategy: fanout
flow:
  - design_loop
  - build_loop
design_loop:
  type: cycle
  flow:
    - design
  exit_when: { stage: design, field: verdict, op: eq, value: pass }
  max_iterations: 2
build_loop:
  type: cycle
  flow:
    - build
  exit_when: { stage: build, field: verdict, op: eq, value: pass }
  max_iterations: 2
  route_back:
    to: design_loop
design:
  roles: [designer]
build:
  roles: [builder]
EOF
_TPL_STAGES=(); _TPL_CYCLES=()
_out="$(load_template "$T" 2>&1)"; _rc=$?
if [[ $_rc -ne 0 ]]; then
    assert_pass "[R1] a template with route_back does not load (rc=$_rc)"
else
    assert_fail "[R1] a template with route_back does not load" "rc=0"
fi
assert_contains "[R1] the error says what replaces it" "$_out" "nested loops"

print_test_section "R2: no fault class or route_back in code"
_hits="$(cd "$REPO_ROOT" && grep -rnE 'route_back|ROUTE_BACK|fault_vocabulary|fault_is_valid|_CYCLE_DISPATCH_FAULT|runner_read_stage_fault|\.fault\b|"fault"|fault:\$|--arg (ft|f) "\$_?fault' \
    core plugins scripts/lib --include='*.sh' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v 'no-fault-routing' | grep -v '#2271' || true)"
assert_eq "[R2] no code reads or writes a fault class or a route_back" "" "$_hits"

print_test_section "R3: no ownership framing"
for _w in "yours to fix" "owned by" "has to change for this" "not yours to fix"; do
    if grep -qF -- "$_w" "$REPO_ROOT/core/pipeline/input-resolve.sh"; then
        assert_fail "[R3] the summaries do not say '$_w'" "found in input-resolve.sh"
    else
        assert_pass "[R3] the summaries do not say '$_w'"
    fi
done

print_test_section "R4: the rule files are gone"
for _f in core/pipeline/finding-owner.sh core/pipeline/fault.sh; do
    if [[ -e "$REPO_ROOT/$_f" ]]; then
        assert_fail "[R4] $_f is gone" "still present"
    else
        assert_pass "[R4] $_f is gone"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
