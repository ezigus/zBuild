#!/usr/bin/env bash
# Tests: design-gate C6 (#1777) — a [guard] SPEC must hold at the merge-base.
#
# A [guard] SPEC claims an invariant, so its assertion holds at the baseline by
# definition. One that FAILS there is a mislabelled [change]. The acceptance gate
# already rejects that (`guard_regressed`) but only after build has spent its
# whole iteration budget: #1789 lost 5 iterations and 2h06m, #1809 lost 2 more
# and was aborted. C6 applies the identical rule one stage earlier.
#
# The gate must FAIL OPEN — an unrunnable check never rejects a correct design —
# and must be LOUD about it, because a silently-skipping gate is indistinguishable
# from a working one (the green-but-inert shape of #845/#1044).
#
# Drives the REAL design_gate_run against a REAL git repo. No condition is
# re-implemented in the test: the #1686 lesson (acceptance-gate-inert-wiring-
# iter1-test.sh) is that a test asserting the condition itself stays green with
# the entire implementation deleted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design-gate C6 — [guard] SPEC must hold at the merge-base (#1777)"
setup_test_env "design-gate-guard-baseline"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_NEGCTL_TIMEOUT="${ZBUILD_NEGCTL_TIMEOUT:-30}"
GIT="$(command -v git)"

# ── Fixture ───────────────────────────────────────────────────────────────────
# main (baseline): doctor.sh carries a deprecation warn line.
# feature (HEAD):  the warn line is REMOVED — that is the change.
#
# SPEC-1 asserts the line is absent  → true at HEAD, FALSE at baseline.
#        Tagged [guard], it is a mislabelled [change]: #1777's exact shape.
# SPEC-2 asserts doctor.sh is executable → true at baseline AND HEAD: a real guard.
# SPEC-3 is tagged [guard] with no testfile at all → #1255 exempts it; skip.
REPO="$(setup_git_temp_repo "guard-baseline")"
(
    cd "$REPO"
    mkdir -p scripts tests
    printf '#!/usr/bin/env bash\necho "bash 4 functional but 5 recommended"\necho ok\n' > scripts/doctor.sh
    chmod +x scripts/doctor.sh
    "$GIT" add -A && "$GIT" commit -q -m "baseline: doctor warns"

    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\necho ok\n' > scripts/doctor.sh
    chmod +x scripts/doctor.sh

    cat > tests/guard-bad-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] doctor.sh no longer carries the bash-4 warn
root="$(cd "$(dirname "$0")/.." && pwd)"
if grep -q "functional but 5 recommended" "$root/scripts/doctor.sh"; then
    echo "✗ [SPEC-1] warn line still present"
    exit 1
fi
echo "✓ [SPEC-1] warn line removed"
EOF

    cat > tests/guard-good-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-2] doctor.sh is executable
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -x "$root/scripts/doctor.sh" ]]; then
    echo "✓ [SPEC-2] doctor.sh is executable"
    exit 0
fi
echo "✗ [SPEC-2] doctor.sh not executable"
exit 1
EOF
    chmod +x tests/*.sh
    "$GIT" add -A && "$GIT" commit -q -m "feat: drop the warn line"
)

_DESIGN_MD='# Design

## Decision
Drop the deprecation warn.

```scope
scripts/doctor.sh
```

```acceptance
SPEC-1[guard]: doctor.sh no longer carries the bash-4 warn
SPEC-2[guard]: doctor.sh is executable
SPEC-3[guard]: the parallel pool behaviour is unchanged
TESTFILES:
SPEC-1: tests/guard-bad-test.sh
SPEC-2: tests/guard-good-test.sh
WIRING: scripts/doctor.sh
```
'

# ── _run_gate <repo_root> <design_md_text> ───────────────────────────────────
# Runs the REAL design-gate against <repo_root>; sets VERDICT / RESULT / VIOL /
# FEEDBACK / GATE_RC.
_seq=0
_run_gate() {
    local root="$1" md="$2"
    _seq=$((_seq + 1))
    local state_dir="$TEST_TEMP_DIR/state-$_seq"
    local art="$state_dir/artifacts"
    mkdir -p "$art"
    printf '%s' "$md" > "$art/design.md"
    printf '{"schema_version":1}' > "$state_dir/pipeline-state.json"
    unset _ZBUILD_DESIGN_GATE_PLUGIN_LOADED _ACCEPTANCE_BLOCK_LOADED \
          _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_COVERAGE_LOADED \
          _ZBUILD_MERGE_BASE_LOADED _ZBUILD_ENV_SCRUB_LOADED
    set +e
    (
        export ZBUILD_REPO_ROOT="$root"
        # shellcheck disable=SC1090
        source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh"
        design_gate_run "design-gate" "$state_dir/pipeline-state.json"
    )
    GATE_RC=$?
    set -e
    RESULT="$(cat "$art/design-gate-result.json" 2>/dev/null || echo '{}')"
    VERDICT="$(jq -r '.verdict // "MISSING"' <<< "$RESULT")"
    VIOL="$(jq -r '(.violations // [])[]' <<< "$RESULT" 2>/dev/null || true)"
    FEEDBACK="$(cat "$art/design-gate-feedback.md" 2>/dev/null || true)"
}

_run_gate "$REPO" "$_DESIGN_MD"

# ─── 1. The mislabelled guard is rejected, and named ─────────────────────────
assert_eq "[SPEC-1] a [guard] whose assertion fails at the merge-base fails the design-gate" \
    "fail" "$VERDICT"
assert_contains "[SPEC-1] the violation names the offending SPEC" \
    "$VIOL" "GUARD_REGRESSED_AT_BASELINE SPEC-1"
assert_contains "[SPEC-2] the violation suggests the likely correction ([change])" \
    "$VIOL" "tag it [change]"
assert_contains "[SPEC-2] the feedback file names the offending SPEC" \
    "$FEEDBACK" "GUARD_REGRESSED_AT_BASELINE SPEC-1"

# ─── 2. A legitimate guard is NOT rejected ───────────────────────────────────
if grep -q "GUARD_REGRESSED_AT_BASELINE SPEC-2" <<< "$VIOL"; then
    assert_fail "[SPEC-3] a guard that holds at the merge-base passes unchanged" \
        "SPEC-2 holds at baseline but was reported regressed"
else
    assert_pass "[SPEC-3] a guard that holds at the merge-base passes unchanged"
fi

# ─── 3. An untagged [guard] skips rather than failing (#1255) ────────────────
if grep -q "GUARD_REGRESSED_AT_BASELINE SPEC-3" <<< "$VIOL"; then
    assert_fail "[SPEC-4] an untagged [guard] skips rather than failing (#1255)" \
        "SPEC-3 has no testfile and must not be a violation"
else
    assert_pass "[SPEC-4] an untagged [guard] skips rather than failing (#1255)"
fi
assert_contains "[SPEC-4] the untagged guard is RECORDED as unverified, not silently dropped" \
    "$(jq -rc '.guard_precheck.skipped' <<< "$RESULT")" 'SPEC-3'

# ─── 4. Coverage is recorded — the gate cannot lie about what it checked ─────
assert_eq "[SPEC-5] guard_precheck records every declared [guard] SPEC" \
    "3" "$(jq -r '.guard_precheck.declared // "MISSING"' <<< "$RESULT")"
assert_eq "[SPEC-5] guard_precheck records how many were verified at the baseline" \
    "1" "$(jq -r '.guard_precheck.verified // "MISSING"' <<< "$RESULT")"
assert_eq "[SPEC-5] guard_precheck records how many failed" \
    "1" "$(jq -r '.guard_precheck.failed // "MISSING"' <<< "$RESULT")"
assert_contains "[SPEC-5] the feedback states the coverage in prose" \
    "$FEEDBACK" "Guard baseline coverage"

# ─── 5. rc is ALWAYS 0 — the verdict lives in the artifact (ADR-040) ─────────
assert_eq "[SPEC-6] design_gate_run still returns rc=0 with C6 violations present" \
    "0" "$GATE_RC"

# ─── 6. FAIL-OPEN: no git repo → no violation, and the reason is recorded ────
NOGIT="$TEST_TEMP_DIR/not-a-repo"
mkdir -p "$NOGIT/tests" "$NOGIT/scripts"
: > "$NOGIT/scripts/doctor.sh"
_run_gate "$NOGIT" "$_DESIGN_MD"
if grep -q "GUARD_REGRESSED_AT_BASELINE" <<< "$VIOL"; then
    assert_fail "[SPEC-7] an unrunnable C6 never rejects the design (fail-open)" \
        "violations: $VIOL"
else
    assert_pass "[SPEC-7] an unrunnable C6 never rejects the design (fail-open)"
fi
assert_contains "[SPEC-7] the fail-open reason is recorded, not silent" \
    "$(jq -rc '.guard_precheck.skipped // []' <<< "$RESULT")" "no_baseline"
assert_eq "[SPEC-7] nothing was verified, and the artifact says so" \
    "0" "$(jq -r '.guard_precheck.verified // "MISSING"' <<< "$RESULT")"

# ─── 6b. The other fail-open paths are covered too, not hand-verified ────────
# The claim this change makes is "fails open, and says so". Two of the six skip
# reasons were exercised above (no_baseline, guard_untested); these are the rest
# that can be triggered deterministically. #1686's lesson is about not
# re-implementing DETECTION logic in a test — it does not exempt the error paths,
# and an untested fail-open path is how a gate goes quietly inert.

# harness — the baseline copy does not parse, so it never reached an assertion.
HREPO="$(setup_git_temp_repo "guard-harness")"
(
    cd "$HREPO"
    mkdir -p scripts tests; : > scripts/doctor.sh
    "$GIT" add -A && "$GIT" commit -q -m baseline
    "$GIT" checkout -q -b feature
    printf 'changed\n' > scripts/doctor.sh
    # Deliberately unparseable: `bash -n` fails, so _negctl_baseline_parses is false.
    printf '#!/usr/bin/env bash\n# [SPEC-1] never parses\nif [[ 1 -eq 1 ]; then :; fi\n' \
        > tests/guard-bad-test.sh
    chmod +x tests/guard-bad-test.sh
    "$GIT" add -A && "$GIT" commit -q -m feature
)
_run_gate "$HREPO" "$_DESIGN_MD"
if grep -q "GUARD_REGRESSED_AT_BASELINE SPEC-1" <<< "$VIOL"; then
    assert_fail "[SPEC-9] an unparseable baseline copy SKIPs (harness), never fails the design" "$VIOL"
else
    assert_pass "[SPEC-9] an unparseable baseline copy SKIPs (harness), never fails the design"
fi
assert_contains "[SPEC-9] and the harness skip is recorded, not silent" \
    "$(jq -rc '.guard_precheck.skipped // []' <<< "$RESULT")" "harness"

# timeout — the baseline run is killed, so pass/fail is unknown (infrastructure).
TREPO="$(setup_git_temp_repo "guard-timeout")"
(
    cd "$TREPO"
    mkdir -p scripts tests; : > scripts/doctor.sh
    "$GIT" add -A && "$GIT" commit -q -m baseline
    "$GIT" checkout -q -b feature
    printf 'changed\n' > scripts/doctor.sh
    printf '#!/usr/bin/env bash\n# [SPEC-1] outlives the timeout\nsleep 30\n' \
        > tests/guard-bad-test.sh
    chmod +x tests/guard-bad-test.sh
    "$GIT" add -A && "$GIT" commit -q -m feature
)
ZBUILD_NEGCTL_TIMEOUT=1 _run_gate "$TREPO" "$_DESIGN_MD"
if grep -q "GUARD_REGRESSED_AT_BASELINE SPEC-1" <<< "$VIOL"; then
    assert_fail "[SPEC-10] a killed baseline run SKIPs (timeout), never fails the design" "$VIOL"
else
    assert_pass "[SPEC-10] a killed baseline run SKIPs (timeout), never fails the design"
fi
assert_contains "[SPEC-10] and the timeout skip is recorded, not silent" \
    "$(jq -rc '.guard_precheck.skipped // []' <<< "$RESULT")" "timeout"

# worktree_failed — the baseline worktree cannot be created at all. Driven by a
# read-only TMPDIR: mktemp -d fails, so the worktree path is empty and
# `git worktree add` cannot succeed. No git stub, no mocking of the code under test.
WREPO="$(setup_git_temp_repo "guard-wtfail")"
(
    cd "$WREPO"
    mkdir -p scripts tests; : > scripts/doctor.sh
    printf '#!/usr/bin/env bash\n# [SPEC-1] holds\nexit 0\n' > tests/guard-bad-test.sh
    chmod +x tests/guard-bad-test.sh
    "$GIT" add -A && "$GIT" commit -q -m baseline
    "$GIT" checkout -q -b feature
    printf 'changed\n' > scripts/doctor.sh
    "$GIT" add -A && "$GIT" commit -q -m feature
)
RO_TMP="$TEST_TEMP_DIR/ro-tmp"; mkdir -p "$RO_TMP"; chmod 500 "$RO_TMP"
TMPDIR="$RO_TMP" _run_gate "$WREPO" "$_DESIGN_MD"
chmod 700 "$RO_TMP"
if grep -q "GUARD_REGRESSED_AT_BASELINE" <<< "$VIOL"; then
    assert_fail "[SPEC-11] an uncreatable baseline worktree SKIPs, never fails the design" "$VIOL"
else
    assert_pass "[SPEC-11] an uncreatable baseline worktree SKIPs, never fails the design"
fi
assert_contains "[SPEC-11] and the worktree failure is recorded, not silent" \
    "$(jq -rc '.guard_precheck.skipped // []' <<< "$RESULT")" "worktree_failed"

# ─── 7. A guard-less design keeps today's exact artifact shape ───────────────
_NOGUARD_MD='# Design

```scope
scripts/doctor.sh
```

```acceptance
SPEC-1[change]: the warn line is gone
TESTFILES:
SPEC-1: tests/guard-bad-test.sh
WIRING: scripts/doctor.sh
```
'
_run_gate "$REPO" "$_NOGUARD_MD"
assert_eq "[SPEC-8] a design declaring no [guard] SPEC carries no guard_precheck key" \
    "false" "$(jq -r 'has("guard_precheck")' <<< "$RESULT")"

print_test_results
exit $((FAIL > 0))
