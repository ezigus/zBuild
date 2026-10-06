#!/usr/bin/env bash
# tests/unit/acceptance-negctl-status-test.sh — the acceptance check reads each
# requirement's status (#2304, ADR-069 §3, §4).
#
# Why: a requirement that is already done, or that needs no code, has nothing
# on the old code to fail. Running its test there only ever produced the
# [guard] failures that caught no regression in 1,831 requirements. A code
# requirement keeps the rule it always had.
#
# N1 a [done] requirement is not run: NEGCTL SKIP <id> already_done
# N2 a [no-code] requirement is not run: NEGCTL SKIP <id> no_code
# N3 the tag-coverage check does not ask a [done] or [no-code] requirement for
#    a tagged assertion; a [code] one still must have one
# N4 [code], the old [change], and an untagged requirement are still checked on
#    the old and new code; an old [guard] reads as done (never "guard_spec")
# N5 the gate's pass reason says how many requirements were checked on the old
#    and new code, how many were already done, and how many need no code
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

print_test_header "the acceptance check reads requirement status (#2304, ADR-069 §3, §4)"
setup_test_env "acceptance-negctl-status"
unset ZBUILD_ISSUE 2>/dev/null || true

GIT="$(command -v git)"
REPO="$(setup_git_temp_repo negctl-status)"
MARK="$TEST_TEMP_DIR/ran"; mkdir -p "$MARK"

# Feature branch: impl.sh is new; each test file records that it ran.
(
    cd "$REPO" || exit 1
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    # load-bearing: fails without impl.sh
    cat > tests/new-test.sh <<EOF
#!/usr/bin/env bash
: > "$MARK/new"
[[ -f "\$(dirname "\$0")/../impl.sh" ]] && echo "✓ [SPEC-1] works" || { echo "✗ [SPEC-1] works"; exit 1; }
EOF
    # tautology: passes on both sides
    cat > tests/same-test.sh <<EOF
#!/usr/bin/env bash
: > "$MARK/same"
echo "✓ [SPEC-2] same"
EOF
    # would fail everywhere — only a done or no-code status keeps it from being run
    cat > tests/done-test.sh <<EOF
#!/usr/bin/env bash
: > "$MARK/done"
echo "✗ [SPEC-3] x"; exit 1
EOF
    cat > tests/nocode-test.sh <<EOF
#!/usr/bin/env bash
: > "$MARK/nocode"
echo "✗ [SPEC-4] x"; exit 1
EOF
    chmod +x tests/*.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feature"
) >/dev/null 2>&1

DM="$REPO/design.md"
cat > "$DM" <<'EOF'
```acceptance
SPEC-1[code]: the feature works
SPEC-2[code]: something that is already true
SPEC-3[done]: the old behaviour stays evidence: impl.sh
SPEC-4[no-code]: the docs explain the feature
TESTFILES:
SPEC-1: tests/new-test.sh
SPEC-2: tests/same-test.sh
SPEC-3: tests/done-test.sh
SPEC-4: tests/nocode-test.sh
WIRING: none
```
EOF
OUT="$(acceptance_negctl_check "$DM" "$REPO" 2>&1)"; RC=$?

print_test_section "N1: an already-done requirement is not run"
assert_eq "[N1] a [done] requirement → NEGCTL SKIP SPEC-3 already_done" \
    "NEGCTL SKIP SPEC-3 already_done" "$(grep 'SPEC-3' <<< "$OUT" || true)"
assert_eq "[N1] ...and its test file never ran" "absent" \
    "$([[ -e "$MARK/done" ]] && echo present || echo absent)"

print_test_section "N2: a no-code requirement is not run"
assert_eq "[N2] a [no-code] requirement → NEGCTL SKIP SPEC-4 no_code" \
    "NEGCTL SKIP SPEC-4 no_code" "$(grep 'SPEC-4' <<< "$OUT" || true)"
assert_eq "[N2] ...and its test file never ran" "absent" \
    "$([[ -e "$MARK/nocode" ]] && echo present || echo absent)"

print_test_section "N4: code requirements keep the old-and-new-code check"
assert_eq "[N4] a load-bearing [code] requirement passes" \
    "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<< "$OUT" || true)"
assert_eq "[N4] a [code] requirement whose test passes on the old code fails as before" \
    "NEGCTL FAIL SPEC-2 tautology" "$(grep 'SPEC-2' <<< "$OUT" || true)"
assert_eq "[N4] ...so the check returns 1" "1" "$RC"

cat > "$DM" <<'EOF'
```acceptance
SPEC-1[change]: the feature works
SPEC-2: something that is already true
SPEC-3[guard]: an old guard
TESTFILES:
SPEC-1: tests/new-test.sh
SPEC-2: tests/same-test.sh
SPEC-3: tests/done-test.sh
WIRING: none
```
EOF
rm -f "$MARK"/*
OUT4="$(acceptance_negctl_check "$DM" "$REPO" 2>&1)"
assert_eq "[N4] an old [change] requirement is checked as code" \
    "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<< "$OUT4" || true)"
assert_eq "[N4] an untagged requirement is checked as code" \
    "NEGCTL FAIL SPEC-2 tautology" "$(grep 'SPEC-2' <<< "$OUT4" || true)"
assert_eq "[N4] an old [guard] reads as already done" \
    "NEGCTL SKIP SPEC-3 already_done" "$(grep 'SPEC-3' <<< "$OUT4" || true)"
assert_eq "[N4] ...and is not run" "absent" \
    "$([[ -e "$MARK/done" ]] && echo present || echo absent)"
assert_eq "[N4] no line says guard_spec any more" "" \
    "$(grep -F 'guard_spec' <<< "$OUT4" || true)"

print_test_section "N3: tag coverage asks only code requirements for a tagged assertion"
CV="$TEST_TEMP_DIR/cov"; mkdir -p "$CV/tests"
printf 'echo "[SPEC-1] tagged"\n' > "$CV/tests/a-test.sh"
cat > "$CV/design.md" <<'EOF'
```acceptance
SPEC-1[code]: tagged
SPEC-2[code]: not tagged anywhere
SPEC-3[done]: not tagged either evidence: tests/a-test.sh
SPEC-4[no-code]: not tagged either
TESTFILES:
tests/a-test.sh
```
EOF
COV="$(acceptance_coverage_check "$CV/design.md" "$CV" 2>&1 || true)"
assert_eq "[N3] only the untagged [code] requirement is reported" "UNTAGGED SPEC-2" "$COV"

print_test_section "N5: the pass reason states the counts"
R5="$(setup_git_temp_repo negctl-status-gate)"
(
    cd "$R5" || exit 1
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    cat > tests/new-test.sh <<'EOF'
#!/usr/bin/env bash
[[ -f "$(dirname "$0")/../impl.sh" ]] && echo "✓ [SPEC-1] works" || { echo "✗ [SPEC-1] works"; exit 1; }
EOF
    chmod +x tests/new-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feature"
) >/dev/null 2>&1
cat > "$R5/design.md" <<'EOF'
```acceptance
SPEC-1[code]: the feature works
SPEC-2[done]: the old flag still parses evidence: impl.sh
SPEC-3[no-code]: the docs explain the feature
TESTFILES:
SPEC-1: tests/new-test.sh
WIRING: none
```
EOF
ST5="$R5/.zbuild-state"; mkdir -p "$ST5/artifacts" "$ST5/events"
cp "$R5/design.md" "$ST5/artifacts/design.md"
printf '{"inputs":{"design":"%s"}}\n' "$ST5/artifacts/design.md" > "$ST5/stage-inputs.json"
( cd "$R5" || exit 1
  export ZBUILD_EVENTS_DIR="$ST5/events" ZBUILD_EVENTS_JSONL="$ST5/events/events.jsonl"
  export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
  export ZBUILD_STAGE_INPUTS="$ST5/stage-inputs.json" ZBUILD_NEGCTL_TIMEOUT=60
  unset _ZBUILD_ACCEPTANCE_GATE_LOADED
  source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
      && acceptance_gate_run "acceptance-gate" "$ST5/pipeline-state.json" ) >/dev/null 2>&1 || true
RES5="$ST5/artifacts/acceptance-gate-result.json"
REASON5="$(jq -r '.reason // empty' "$RES5" 2>/dev/null)"
assert_eq "[N5] the gate passes" "pass" "$(jq -r '.verdict // empty' "$RES5" 2>/dev/null)"
assert_contains "[N5] the reason counts the requirements checked on the old and new code" \
    "$REASON5" "1 checked on the old and new code"
assert_contains "[N5] ...the ones already done" "$REASON5" "1 already done"
assert_contains "[N5] ...and the ones that need no code" "$REASON5" "1 no code"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
