#!/usr/bin/env bash
# tests/unit/acceptance-negctl-signal-test.sh — a test file that dies on a
# signal is not a timeout.
#
# Why: #1847 run 20260928144733-57620. A TESTFILE stubbed the model call as
# `kill -TERM "$$"` — it signalled its own process. At the merge-base (no
# handler yet) the file died after ~1s with rc=143, and the negative control
# reported `negctl_error:timeout` for every SPEC after that point: infra, owned
# by nobody, under a 60s timer that never fired.
#
# Exit codes 124/137/143 are OS conventions, not zBuild's: GNU `timeout` exits
# 124 when ITS timer fires (137 if its -k kill-after lands); 143 is 128+15 —
# "a SIGTERM killed it", from anyone. So only the timer's own codes mean timeout.
#
# S1 [change] a [change] SPEC whose baseline run dies on SIGTERM (no verdict
#             printed) is `NEGCTL FAIL <spec> killed_by_signal`, not a timeout
# S2 [change] a SPEC that printed its ✗ before the file died keeps that evidence:
#             the control holds (NEGCTL PASS)
# S3 [change] a [guard] SPEC whose baseline run dies on a signal is
#             killed_by_signal too — not guard_regressed, not a timeout
# S4 [guard]  a run the timer really stops is still `NEGCTL ERROR timeout:`
# S5 [change] the gate classes killed_by_signal as recoverable, and its reason
#             names the cause and the fix
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

print_test_header "acceptance negctl — a signal is not a timeout"
setup_test_env "acceptance-negctl-signal"
unset ZBUILD_ISSUE 2>/dev/null || true

GIT="$(command -v git)"
REPO="$(setup_git_temp_repo negctl-signal-repo)"   # main @ seed = baseline

(
    cd "$REPO" || exit 1
    "$GIT" checkout -q -b feature
    mkdir -p tests
    # HEAD's implementation installs the handler the baseline lacks.
    printf '#!/usr/bin/env bash\ntrap "true" TERM\n' > impl.sh
    # S1: no verdict before the self-signal.
    cat > tests/s1-test.sh <<'EOF'
#!/usr/bin/env bash
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
# shellcheck disable=SC1090
[[ -f "$impl" ]] && source "$impl"
kill -TERM "$$"
echo "  ✓ [SPEC-1] survives a TERM"
EOF
    # S2: its own ✗ first, then the self-signal.
    cat > tests/s2-test.sh <<'EOF'
#!/usr/bin/env bash
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
if [[ -f "$impl" ]]; then echo "  ✓ [SPEC-2] handler installed"; else echo "  ✗ [SPEC-2] handler installed"; fi
# shellcheck disable=SC1090
[[ -f "$impl" ]] && source "$impl"
kill -TERM "$$"
[[ -f "$impl" ]]
EOF
    # S3: a [guard] whose file kills itself at the baseline.
    cat > tests/s3-test.sh <<'EOF'
#!/usr/bin/env bash
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
# shellcheck disable=SC1090
[[ -f "$impl" ]] && source "$impl"
kill -TERM "$$"
echo "  ✓ [SPEC-3] still fine"
EOF
    chmod +x tests/*.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: handler + self-signalling tests"
)
DM="$REPO/design.md"
cat > "$DM" <<'EOF'
```acceptance
SPEC-1[change]: survives a TERM
SPEC-2[change]: handler installed
SPEC-3[guard]: still fine
TESTFILES:
SPEC-1: tests/s1-test.sh
SPEC-2: tests/s2-test.sh
SPEC-3: tests/s3-test.sh
```
EOF

print_test_section "S1–S3: a file that dies on a signal"
OUT="$(ZBUILD_NEGCTL_TIMEOUT=60 acceptance_negctl_check "$DM" "$REPO" 2>/dev/null || true)"
assert_eq "[S1] no verdict before the signal → killed_by_signal" \
    "NEGCTL FAIL SPEC-1 killed_by_signal" "$(grep 'SPEC-1' <<< "$OUT" || true)"
assert_eq "[S2] a ✗ printed before the signal is still evidence → the control holds" \
    "NEGCTL PASS SPEC-2" "$(grep 'SPEC-2' <<< "$OUT" || true)"
assert_eq "[S3] a [guard] that dies on a signal → killed_by_signal" \
    "NEGCTL FAIL SPEC-3 killed_by_signal" "$(grep 'SPEC-3' <<< "$OUT" || true)"
if grep -q 'timeout' <<< "$OUT"; then
    assert_fail "[S1] nothing here is reported as a timeout" "$(grep timeout <<< "$OUT")"
else
    assert_pass "[S1] nothing here is reported as a timeout"
fi

print_test_section "S4: the timer's own stop is still a timeout"
if command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1; then
    REPO4="$(setup_git_temp_repo negctl-signal-repo4)"
    ( cd "$REPO4" || exit 1; "$GIT" checkout -q -b feature; mkdir -p tests
      printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
      printf '#!/usr/bin/env bash\n# [SPEC-1] slow\nsleep 30\n' > tests/slow-test.sh
      chmod +x tests/slow-test.sh impl.sh; "$GIT" add -A; "$GIT" commit -q -m slow )
    printf '```acceptance\nSPEC-1: slow\nTESTFILES:\ntests/slow-test.sh\n```\n' > "$REPO4/design.md"
    OUT4="$(ZBUILD_NEGCTL_TIMEOUT=1 ZBUILD_NEGCTL_KILL_GRACE=1 acceptance_negctl_check "$REPO4/design.md" "$REPO4" 2>/dev/null || true)"
    assert_eq "[S4] a run the timer stops → NEGCTL ERROR timeout:SPEC-1" \
        "NEGCTL ERROR timeout:SPEC-1" "$(grep 'SPEC-1' <<< "$OUT4" || true)"
else
    assert_pass "[S4] skipped — no timeout binary"
fi

print_test_section "S5: the gate's class and wording"
# shellcheck source=../../scripts/lib/acceptance-disposition.sh
source "$REPO_ROOT/scripts/lib/acceptance-disposition.sh"
assert_eq "[S5] killed_by_signal is recoverable (the test's author can fix it)" \
    "recoverable" "$(_ag_failure_class_disposition killed_by_signal)"
assert_contains "[S5] the gate declares the class" \
    "$(cat "$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml")" "- killed_by_signal"
_ag_reason_src="$(sed -n '/^_ag_join_ids()/,/^}/p; /^_ag_build_reason()/,/^}/p' "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh")"
eval "$_ag_reason_src"
_reason="$(_ag_build_reason "killed_by_signal:SPEC-8" "killed_by_signal:SPEC-9")"
assert_contains "[S5] the reason names the SPECs" "$_reason" "SPEC-8/SPEC-9"
assert_contains "[S5] ...says the file died on a signal, not a timeout" "$_reason" "died on a signal"
assert_contains "[S5] ...and names the usual cause" "$_reason" 'its own process'
if grep -q '^infra' <<< "${_reason#*— }"; then
    assert_fail "[S5] it is not listed as infra" "$_reason"
else
    assert_pass "[S5] it is not listed as infra"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
