#!/usr/bin/env bash
# tests/unit/acceptance-negctl-runs-per-file-test.sh — #2110
# The acceptance gate judges every SPEC from ONE baseline run and ONE HEAD run
# of each test file. It used to run the whole file twice PER SPEC: 19 SPECs
# bound to one 129s file = 38 executions = 68 minutes per gate pass (#1840).
# It also bounds each run by the file's MEASURED time, not a flat 60s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"
# shellcheck source=../../scripts/lib/acceptance-reachability.sh
source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh"

print_test_header "acceptance gate — one baseline + one HEAD run per file (#2110)"
setup_test_env "negctl-runs-per-file"
GIT="$(command -v git)"

# A runner that counts every invocation, then runs the file for real.
COUNT="$TEST_TEMP_DIR/runs.count"; : > "$COUNT"
RUNNER="$TEST_TEMP_DIR/bin/count-runner"; mkdir -p "$(dirname "$RUNNER")"
cat > "$RUNNER" <<EOS
#!/usr/bin/env bash
printf '%s\\n' "\$1" >> "$COUNT"
exec bash "\$1"
EOS
chmod +x "$RUNNER"
export ZBUILD_ACCEPTANCE_RUN_CMD="$RUNNER {files}"

REPO="$(setup_git_temp_repo runs-per-file)"   # main @ seed (baseline)
(
    cd "$REPO"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    cat > impl.sh <<'EOS'
#!/usr/bin/env bash
feature_a() { return 0; }
feature_b() { return 0; }
EOS
    # One file, five [change] SPECs, one [guard] SPEC.
    cat > tests/one-test.sh <<'EOS'
#!/usr/bin/env bash
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
ok() { printf '  ✓ %s\n' "$1"; }; bad() { printf '  ✗ %s\n' "$1"; FAIL=1; }
FAIL=0
if [[ -f "$impl" ]]; then source "$impl"; fi
declare -F feature_a >/dev/null && ok "[SPEC-1] feature_a exists" || bad "[SPEC-1] feature_a exists"
declare -F feature_b >/dev/null && ok "[SPEC-2] feature_b exists" || bad "[SPEC-2] feature_b exists"
declare -F feature_a >/dev/null && ok "[SPEC-3] feature_a callable" || bad "[SPEC-3] feature_a callable"
declare -F feature_b >/dev/null && ok "[SPEC-4] feature_b callable" || bad "[SPEC-4] feature_b callable"
declare -F feature_a >/dev/null && ok "[SPEC-5] a and b" || bad "[SPEC-5] a and b"
exit "$FAIL"
EOS
    # The guard lives in its own file: under a custom runner the gate judges
    # by file rc, and one-test.sh is red at baseline by design.
    printf '#!/usr/bin/env bash\necho "  ✓ [SPEC-6] bash still works"\nexit 0\n' > tests/guard-test.sh
    chmod +x tests/one-test.sh tests/guard-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl + one tagged test file"
)
DM="$REPO/design.md"
cat > "$DM" <<'EOF2'
```scope
impl.sh
```
```acceptance
SPEC-1[change]: feature_a exists
SPEC-2[change]: feature_b exists
SPEC-3[change]: feature_a callable
SPEC-4[change]: feature_b callable
SPEC-5[change]: a and b
SPEC-6[guard]: bash still works
WIRING: impl.sh
TESTFILES:
SPEC-1: tests/one-test.sh
SPEC-2: tests/one-test.sh
SPEC-3: tests/one-test.sh
SPEC-4: tests/one-test.sh
SPEC-5: tests/one-test.sh
SPEC-6: tests/guard-test.sh
```
EOF2

export ZBUILD_NEGCTL_ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"; mkdir -p "$ZBUILD_NEGCTL_ARTIFACT_DIR"

# ─── [#2110-1] negctl: 6 SPECs on one file = exactly 2 executions ──────────
: > "$COUNT"
set +e; OUT="$(acceptance_negctl_check "$DM" "$REPO")"; RC=$?; set -e
for n in 1 2 3 4 5; do
    assert_eq "[#2110-1] SPEC-$n is a valid control" "NEGCTL PASS SPEC-$n" "$(grep "SPEC-$n\$" <<<"$OUT" || true)"
done
assert_eq "[#2110-1] SPEC-6 guard holds" "NEGCTL PASS SPEC-6 guard_spec" "$(grep 'SPEC-6' <<<"$OUT" || true)"
assert_eq "[#2110-1] negctl rc=0" "0" "$RC"
assert_eq "[#2110-1] one-test.sh was executed exactly twice (baseline + head), not per SPEC" \
    "2" "$(grep -c '/tests/one-test.sh$' "$COUNT" || true)"
assert_eq "[#2110-1] the guard's file was executed once (baseline only)" \
    "1" "$(grep -c '/tests/guard-test.sh$' "$COUNT" || true)"
assert_eq "[#2110-1] three executions in total for 6 SPECs over 2 files" "3" "$(wc -l < "$COUNT" | tr -d ' ')"
# Per-SPEC diagnostic logs keep their shape: every SPEC still gets its own log with both sections.
for n in 1 5; do
    assert_contains "[#2110-1] negctl-SPEC-$n.log has a baseline section" \
        "$(cat "$ZBUILD_NEGCTL_ARTIFACT_DIR/negctl-SPEC-$n.log")" "### SPEC-$n baseline tests/one-test.sh"
    assert_contains "[#2110-1] negctl-SPEC-$n.log has a head section" \
        "$(cat "$ZBUILD_NEGCTL_ARTIFACT_DIR/negctl-SPEC-$n.log")" "### SPEC-$n head tests/one-test.sh"
done
assert_contains "[#2110-1] guard log has only a baseline section" \
    "$(cat "$ZBUILD_NEGCTL_ARTIFACT_DIR/negctl-SPEC-6.log")" "### SPEC-6 baseline tests/guard-test.sh"

# ─── [#2110-2] reachability: the HEAD run happens once per file, not per target ──
cat > "$DM" <<'EOF2'
```scope
impl.sh
```
```acceptance
SPEC-1[change]: feature_a exists
WIRING:
impl.sh
tests/one-test.sh
TESTFILES:
SPEC-1: tests/one-test.sh
```
EOF2
: > "$COUNT"
set +e; ROUT="$(acceptance_reachability_check "$DM" "$REPO")"; set -e
assert_contains "[#2110-2] impl.sh is load-bearing" "$ROUT" "REACHABILITY PASS impl.sh"
head_runs="$(grep -c "^$REPO/" "$COUNT" || true)"
assert_eq "[#2110-2] the HEAD run of the file happened once across 2 WIRING targets" "1" "$head_runs"

# ─── [#2110-3] per-file bound from the measured test time ──────────────────
# The test stage records `file <ms> <abs-path>`; the gate's bound for that file
# is max(stage bound, 3× measured), never below the stage bound, clamped.
export ZBUILD_NEGCTL_TIMING_LOG="$TEST_TEMP_DIR/test-timing.log"
printf 'file 129000 /some/staging/dir/tests/one-test.sh\n' > "$ZBUILD_NEGCTL_TIMING_LOG"
assert_eq "[#2110-3] a 129s file gets a 387s bound when the stage bound is 60" \
    "387" "$(ZBUILD_NEGCTL_TIMEOUT=60 _acceptance_file_timeout tests/one-test.sh 60)"
assert_eq "[#2110-3] an unmeasured file keeps the stage bound" \
    "60" "$(_acceptance_file_timeout tests/other-test.sh 60)"
assert_eq "[#2110-3] with no declared timing input the stage bound stands" \
    "60" "$(ZBUILD_NEGCTL_TIMING_LOG='' _acceptance_file_timeout tests/one-test.sh 60)"
assert_eq "[#2110-3] a tiny measured time never lowers the stage bound" \
    "60" "$(printf 'file 800 /x/tests/fast-test.sh\n' > "$ZBUILD_NEGCTL_TIMING_LOG"; _acceptance_file_timeout tests/fast-test.sh 60)"
assert_eq "[#2110-3] the bound is clamped at the test stage's own per-file ceiling (480)" \
    "480" "$(printf 'file 400000 /x/tests/slow-test.sh\n' > "$ZBUILD_NEGCTL_TIMING_LOG"; _acceptance_file_timeout tests/slow-test.sh 60)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
