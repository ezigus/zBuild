#!/usr/bin/env bash
# Unit: Wave 19-L (#749 Copilot review on #751) — _zb_test_chain_exit_trap
# must preserve the existing trap across edge cases (no prior trap, prior
# trap with embedded quotes, multiple chained calls). The prior
# implementation used fragile string slicing and could silently produce
# an empty $inner, clobbering the prior trap and reintroducing leaks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "_zb_test_chain_exit_trap robustness (Wave 19-L, #749/#751)"
setup_test_env "trap-chain-robust"
_test_cleanup_hook() { cleanup_test_env; }

# Run each scenario in its own bash subshell so trap state stays isolated.
WITNESS_DIR="$TEST_TEMP_DIR/witness"
mkdir -p "$WITNESS_DIR"

print_test_section "scenario 1: no prior EXIT trap → new_cmd installed"

bash -c "
    set -euo pipefail
    source '$REPO_ROOT/tests/lib/test-harness.sh'
    _zb_test_chain_exit_trap \"echo S1 > '$WITNESS_DIR/s1.txt'\"
" 2>/dev/null || true

if [[ -f "$WITNESS_DIR/s1.txt" && "$(cat "$WITNESS_DIR/s1.txt")" == "S1" ]]; then
    assert_pass "T1: new_cmd installed when no prior trap"
else
    assert_fail "T1: new_cmd should run on exit when no prior trap" \
        "witness=$(ls -la "$WITNESS_DIR/" 2>/dev/null)"
fi

print_test_section "scenario 2: prior simple trap → both run, prior first"

bash -c "
    set -euo pipefail
    source '$REPO_ROOT/tests/lib/test-harness.sh'
    trap \"echo PRIOR >> '$WITNESS_DIR/s2.txt'\" EXIT
    _zb_test_chain_exit_trap \"echo NEW >> '$WITNESS_DIR/s2.txt'\"
" 2>/dev/null || true

if [[ -f "$WITNESS_DIR/s2.txt" ]]; then
    contents="$(cat "$WITNESS_DIR/s2.txt" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$contents" == "PRIOR NEW" ]]; then
        assert_pass "T2: prior trap preserved + new_cmd appended (order=PRIOR then NEW)"
    else
        assert_fail "T2: chained trap should run prior then new" "got: '$contents'"
    fi
else
    assert_fail "T2: chained trap should produce witness file" "missing"
fi

print_test_section "scenario 3: three chained calls all run in order"

bash -c "
    set -euo pipefail
    source '$REPO_ROOT/tests/lib/test-harness.sh'
    trap \"echo A >> '$WITNESS_DIR/s3.txt'\" EXIT
    _zb_test_chain_exit_trap \"echo B >> '$WITNESS_DIR/s3.txt'\"
    _zb_test_chain_exit_trap \"echo C >> '$WITNESS_DIR/s3.txt'\"
" 2>/dev/null || true

if [[ -f "$WITNESS_DIR/s3.txt" ]]; then
    contents="$(cat "$WITNESS_DIR/s3.txt" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$contents" == "A B C" ]]; then
        assert_pass "T3: three chained traps all run (order=A B C)"
    else
        assert_fail "T3: three chained traps should run in registration order" \
            "got: '$contents'"
    fi
else
    assert_fail "T3: three-chain trap should produce witness file" "missing"
fi

print_test_section "scenario 4: prior trap with embedded special chars survives"

# A trap body with a semicolon and a redirect — common patterns that
# fragile string slicing might mangle.
bash -c "
    set -euo pipefail
    source '$REPO_ROOT/tests/lib/test-harness.sh'
    trap \"echo X; echo Y >> '$WITNESS_DIR/s4.txt'\" EXIT
    _zb_test_chain_exit_trap \"echo Z >> '$WITNESS_DIR/s4.txt'\"
" >/dev/null 2>&1 || true

if [[ -f "$WITNESS_DIR/s4.txt" ]]; then
    # Both prior `echo Y` and new `echo Z` must reach the file.
    if grep -q "Y" "$WITNESS_DIR/s4.txt" && grep -q "Z" "$WITNESS_DIR/s4.txt"; then
        assert_pass "T4: prior trap with semicolon + redirect preserved AND new_cmd ran"
    else
        assert_fail "T4: prior trap with special chars must survive chaining" \
            "got: $(cat "$WITNESS_DIR/s4.txt" 2>/dev/null | tr '\n' ' ')"
    fi
else
    assert_fail "T4: scenario 4 witness file missing" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
