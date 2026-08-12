#!/usr/bin/env bash
# tests/unit/core-contract-version-test.sh — #1824 result-contract negotiation.
#
# ADR-001 deferred "versioning across breaking manifest changes: bump policy TBD"
# and never came back to it. Phase 0 forces the issue: v1 and v2 result files
# coexist while ~25 plugins migrate, so the engine has to be able to say which
# contracts it can read — once, in one place, and refuse the rest at LOAD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/contract/version — result-contract negotiation (#1824)"
setup_test_env "contract-version"

# TC-1 [SPEC-1]: the range library exists and loads.
if [[ -f "$REPO_ROOT/core/contract/version.sh" ]]; then
    assert_pass "[SPEC-1] TC-1: core/contract/version.sh exists"
else
    assert_fail "[SPEC-1] TC-1: core/contract/version.sh exists" "missing"
    cleanup_test_env; print_test_results; exit 1
fi
# shellcheck source=../../core/contract/version.sh
source "$REPO_ROOT/core/contract/version.sh"

# TC-2 [SPEC-2]: the range is legible and covers coexistence (v1 and v2).
assert_eq "[SPEC-2] TC-2: range renders as MIN..MAX" "1..2" "$(contract_version_range)"
set +e; contract_version_supported 1; r1=$?; contract_version_supported 2; r2=$?; set -e
assert_eq "[SPEC-2] TC-2: v1 supported during coexistence" "0" "$r1"
assert_eq "[SPEC-2] TC-2: v2 supported" "0" "$r2"

# TC-3 [SPEC-2]: outside the range, and non-integers, are unsupported. A typo'd
# version must refuse rather than default to v1 — defaulting is how an
# unreadable plugin gets read anyway.
for bad in 0 3 99 "v2" "2.0" "" "1x"; do
    set +e; contract_version_supported "$bad"; rc=$?; set -e
    assert_eq "[SPEC-2] TC-3: '$bad' is unsupported" "1" "$rc"
done

# TC-4 [SPEC-3]: an ABSENT declaration resolves to v1 while coexistence is on.
assert_eq "[SPEC-3] TC-4: absent resolves to the coexistence default" "1" "$(contract_version_resolve "")"
set +e; contract_version_check "" "plugin 'x'" >/dev/null; rc=$?; set -e
assert_eq "[SPEC-3] TC-4: absent is accepted while v1 is in range" "0" "$rc"

# TC-5 [SPEC-4]: the refusal message names the subject, the declared version and
# the accepted range — the three facts needed to act without reading the source.
set +e; msg="$(contract_version_check 7 "plugin 'acme'")"; rc=$?; set -e
assert_eq "[SPEC-4] TC-5: an out-of-range version is refused" "1" "$rc"
case "$msg" in
    *"acme"*) assert_pass "[SPEC-4] TC-5: message names the plugin" ;;
    *) assert_fail "[SPEC-4] TC-5: message names the plugin" "got: $msg" ;;
esac
case "$msg" in
    *"contract 7"*) assert_pass "[SPEC-4] TC-5: message names the declared version" ;;
    *) assert_fail "[SPEC-4] TC-5: message names the declared version" "got: $msg" ;;
esac
case "$msg" in
    *"1..2"*) assert_pass "[SPEC-4] TC-5: message names the accepted range" ;;
    *) assert_fail "[SPEC-4] TC-5: message names the accepted range" "got: $msg" ;;
esac

# TC-6 [SPEC-5]: dropping v1 is a ONE-LINE change. Simulate #1850 by moving the
# floor and assert the consequence lands without touching any other file: an
# absent declaration stops being legible.
(
    _ZBUILD_CONTRACT_MIN=2
    set +e; contract_version_supported 1; a=$?; contract_version_check "" "plugin 'y'" >/dev/null; b=$?; set -e
    [[ "$a" -eq 1 && "$b" -eq 1 ]] && exit 0 || exit 1
)
assert_eq "[SPEC-5] TC-6: raising MIN alone retires v1 and the absent default" "0" "$?"

# TC-7 [SPEC-6]: the bounds are declared in EXACTLY ONE place. A second copy is
# how a range becomes advisory — the reader drifts from the validator and each
# is individually defensible. Anchored to assignments, so prose and `$_ZBUILD_*`
# references don't false-positive.
dupes="$(grep -rnE '^[[:space:]]*_ZBUILD_CONTRACT_(MIN|MAX|V2|DEFAULT)=' \
    "$REPO_ROOT/core" "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" 2>/dev/null \
    | grep -v '/core/contract/version.sh:' || true)"
if [[ -z "$dupes" ]]; then
    assert_pass "[SPEC-6] TC-7: contract bounds assigned only in core/contract/version.sh"
else
    assert_fail "[SPEC-6] TC-7: contract bounds assigned only in core/contract/version.sh" "second copy: $dupes"
fi

# TC-7b [SPEC-6]: a bare NUMERIC comparison against the v2 boundary is also a
# second copy — and the more likely one. Assignments are obvious; an inline
# `-ge 2` reads as ordinary code. #1823 landed three of them (verdict.sh plus two
# in runner.sh's dispatch gate) while this issue was open, which is exactly how a
# range stops being one place. Anchored to a contract-ish variable so unrelated
# arithmetic doesn't false-positive.
lits="$(grep -rnE '\$\{?_?[A-Za-z_]*(contract|_sv|_cd_contract|_pd_contract)[A-Za-z_]*\}?"?[[:space:]]+-(ge|gt|lt|le|eq)[[:space:]]+[0-9]' \
    "$REPO_ROOT/core" "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" 2>/dev/null \
    | grep -v '/core/contract/version.sh:' || true)"
if [[ -z "$lits" ]]; then
    assert_pass "[SPEC-6] TC-7b: no bare numeric comparison against the contract boundary"
else
    assert_fail "[SPEC-6] TC-7b: no bare numeric comparison against the contract boundary" "literal boundary: $lits"
fi

# TC-8 [SPEC-7]: validate_manifest refuses an unreadable plugin at LOAD, and
# accepts one that declares nothing. Load-time, not dispatch-time: by dispatch
# the run has paid for the stage and the misread looks like a bad result rather
# than an unspeakable one.
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
_mk() { # <file> <id> [declared-contract]
    {
        printf 'id: %s\nname: Test\nkind: tool\nversion: 0.1.0\n' "$2"
        printf 'hooks:\n  run: test_run\nprovides:\n  artifact_type: t.json\n'
        if [[ -n "${3:-}" ]]; then printf '  result_contract: %s\n' "$3"; fi
    } > "$1"
}
_mk "$TEST_TEMP_DIR/ok.yaml"   "ok-plugin"   2
_mk "$TEST_TEMP_DIR/none.yaml" "none-plugin" ""
_mk "$TEST_TEMP_DIR/bad.yaml"  "bad-plugin"  7

set +e
validate_manifest "$TEST_TEMP_DIR/ok.yaml"   >/dev/null 2>&1; ok_rc=$?
validate_manifest "$TEST_TEMP_DIR/none.yaml" >/dev/null 2>&1; none_rc=$?
bad_out="$(validate_manifest "$TEST_TEMP_DIR/bad.yaml" 2>&1)"; bad_rc=$?
set -e
assert_eq "[SPEC-7] TC-8: in-range manifest loads" "0" "$ok_rc"
assert_eq "[SPEC-7] TC-8: manifest with no declaration loads (v1)" "0" "$none_rc"
assert_eq "[SPEC-7] TC-8: out-of-range manifest is REFUSED at load" "1" "$bad_rc"
case "$bad_out" in
    *"bad-plugin"*"1..2"*) assert_pass "[SPEC-7] TC-8: refusal names the plugin and the range" ;;
    *) assert_fail "[SPEC-7] TC-8: refusal names the plugin and the range" "got: $bad_out" ;;
esac

# TC-9 [SPEC-5]: the #1850 one-line drop has to work THROUGH validate_manifest,
# not just through the library. TC-6 proves the lib refuses an absent
# declaration once MIN rises; this proves the validator does too. The two are
# only equivalent if validate_manifest checks unconditionally — short-circuiting
# on an empty declaration passes every undeclared plugin, and those are exactly
# the ones #1850 must catch. Run in a subshell so the raised floor cannot leak.
(
    _ZBUILD_CONTRACT_MIN=2
    set +e
    out_none="$(validate_manifest "$TEST_TEMP_DIR/none.yaml" 2>&1)"; rc_none=$?
    out_v2="$(validate_manifest "$TEST_TEMP_DIR/ok.yaml" 2>&1)";     rc_v2=$?
    set -e
    # undeclared → refused; declared v2 → still fine.
    [[ "$rc_none" -eq 1 && "$out_none" == *"none-plugin"*"2..2"* && "$rc_v2" -eq 0 ]] && exit 0
    printf 'none rc=%s out=%s | v2 rc=%s\n' "$rc_none" "$out_none" "$rc_v2" >&2
    exit 1
)
assert_eq "[SPEC-5] TC-9: raising MIN refuses undeclared plugins at load, keeps v2" "0" "$?"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
