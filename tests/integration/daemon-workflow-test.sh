#!/usr/bin/env bash
# Integration test: .github/workflows/zbuild-daemon.yml — structural validation
#
# Validates that the daemon workflow YAML contains the required triggers,
# permissions, jobs, and steps mandated by issue #92.
# Uses yq for YAML parsing (already available in CI and locally).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/zbuild-daemon.yml"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild-daemon.yml — structural YAML validation"

# ─── Prerequisite: workflow file must exist ───────────────────────────────────
print_test_section "0. File presence"

if [[ -f "$WORKFLOW" ]]; then
    assert_pass "zbuild-daemon.yml exists at .github/workflows/zbuild-daemon.yml"
else
    assert_fail "zbuild-daemon.yml exists" "file not found: $WORKFLOW"
    print_test_results
    exit 1
fi

# ─── Helper: run yq query and return value ────────────────────────────────────
yq_get() {
    yq e "$1" "$WORKFLOW" 2>/dev/null || echo ""
}

# ─── Test 1: Trigger — issues event with labeled type ────────────────────────
print_test_section "1. Trigger: on.issues with labeled activity type"

issues_types="$(yq_get '.on.issues.types[]' 2>/dev/null || echo "")"
if echo "$issues_types" | grep -q "labeled"; then
    assert_pass "trigger: on.issues.types contains 'labeled'"
else
    assert_fail "trigger: on.issues.types contains 'labeled'" \
        "got: $issues_types"
fi

# ─── Test 2: Label filter env var present ────────────────────────────────────
print_test_section "2. Configurable label via env"

# The workflow must define ZBUILD_TRIGGER_LABEL in env (configurable label approach)
env_label="$(yq_get '.env.ZBUILD_TRIGGER_LABEL' 2>/dev/null || echo "")"
if [[ "$env_label" == "zbuild-run" ]]; then
    assert_pass "env.ZBUILD_TRIGGER_LABEL is 'zbuild-run'"
else
    assert_fail "env.ZBUILD_TRIGGER_LABEL is 'zbuild-run'" "got: '$env_label'"
fi

# ─── Test 3: Permissions block ────────────────────────────────────────────────
print_test_section "3. Permissions block"

perm_issues="$(yq_get '.permissions.issues' 2>/dev/null || echo "")"
perm_contents="$(yq_get '.permissions.contents' 2>/dev/null || echo "")"
perm_pr="$(yq_get '.permissions.pull-requests' 2>/dev/null || echo "")"

if [[ "$perm_issues" == "write" ]]; then
    assert_pass "permissions.issues: write"
else
    assert_fail "permissions.issues: write" "got: '$perm_issues'"
fi

if [[ "$perm_contents" == "read" ]]; then
    assert_pass "permissions.contents: read"
else
    assert_fail "permissions.contents: read" "got: '$perm_contents'"
fi

if [[ "$perm_pr" == "write" ]]; then
    assert_pass "permissions.pull-requests: write"
else
    assert_fail "permissions.pull-requests: write" "got: '$perm_pr'"
fi

# ─── Test 4: Trigger job exists ──────────────────────────────────────────────
print_test_section "4. Job: trigger"

trigger_job="$(yq_get '.jobs.trigger' 2>/dev/null || echo "")"
if [[ -n "$trigger_job" ]] && [[ "$trigger_job" != "null" ]]; then
    assert_pass "jobs.trigger exists"
else
    assert_fail "jobs.trigger exists" "job not found in YAML"
fi

# ─── Test 5: trigger job has label-filter condition ──────────────────────────
print_test_section "5. Label filter condition on trigger job"

trigger_if="$(yq_get '.jobs.trigger.if' 2>/dev/null || echo "")"
if echo "$trigger_if" | grep -q "zbuild-run\|ZBUILD_TRIGGER_LABEL"; then
    assert_pass "jobs.trigger.if references zbuild-run label"
else
    assert_fail "jobs.trigger.if references zbuild-run label" \
        "got: '$trigger_if'"
fi

# ─── Test 6: pipeline job exists and uses the reusable workflow ───────────────
print_test_section "6. Job: pipeline via workflow_call"

pipeline_uses="$(yq_get '.jobs.pipeline.uses' 2>/dev/null || echo "")"
if echo "$pipeline_uses" | grep -q "zbuild-pipeline.yml"; then
    assert_pass "jobs.pipeline.uses references zbuild-pipeline.yml"
else
    assert_fail "jobs.pipeline.uses references zbuild-pipeline.yml" \
        "got: '$pipeline_uses'"
fi

# ─── Test 7: issue_number passed to reusable workflow ────────────────────────
print_test_section "7. pipeline job passes issue_number"

pipeline_issue="$(yq_get '.jobs.pipeline.with.issue_number' 2>/dev/null || echo "")"
if echo "$pipeline_issue" | grep -q "issue.number\|issue_number"; then
    assert_pass "jobs.pipeline.with.issue_number is set"
else
    assert_fail "jobs.pipeline.with.issue_number is set" \
        "got: '$pipeline_issue'"
fi

# ─── Test 8: dry_run passed as false ─────────────────────────────────────────
print_test_section "8. pipeline job passes dry_run: false"

pipeline_dry_run="$(yq_get '.jobs.pipeline.with.dry_run' 2>/dev/null || echo "")"
if [[ "$pipeline_dry_run" == "false" ]]; then
    assert_pass "jobs.pipeline.with.dry_run is false"
else
    assert_fail "jobs.pipeline.with.dry_run is false" \
        "got: '$pipeline_dry_run'"
fi

# ─── Test 9: post-run job exists (label removal + comment) ───────────────────
print_test_section "9. Job: post-run (label removal and comment)"

post_job="$(yq_get '.jobs.post-run' 2>/dev/null || echo "")"
if [[ -n "$post_job" ]] && [[ "$post_job" != "null" ]]; then
    assert_pass "jobs.post-run exists"
else
    assert_fail "jobs.post-run exists" "job not found in YAML"
fi

# ─── Test 10: post-run job runs after pipeline ───────────────────────────────
print_test_section "10. post-run job depends on pipeline job"

# needs may be a scalar string or a sequence; check both forms
post_needs_raw="$(yq_get '.jobs.post-run.needs' 2>/dev/null || echo "")"
if echo "$post_needs_raw" | grep -q "pipeline"; then
    assert_pass "jobs.post-run.needs includes 'pipeline'"
else
    assert_fail "jobs.post-run.needs includes 'pipeline'" \
        "got: '$post_needs_raw'"
fi

# ─── Test 11: post-run job runs always (so label is removed even on failure) ─
print_test_section "11. post-run job has if: always()"

post_if="$(yq_get '.jobs.post-run.if' 2>/dev/null || echo "")"
if echo "$post_if" | grep -q "always"; then
    assert_pass "jobs.post-run.if uses always() condition"
else
    assert_fail "jobs.post-run.if uses always() condition" \
        "got: '$post_if'"
fi

# ─── Test 12: post-run job has a step that removes the label ─────────────────
print_test_section "12. post-run has a remove-label step"

step_names="$(yq_get '.jobs.post-run.steps[].name' 2>/dev/null || echo "")"
if echo "$step_names" | grep -qi "label\|remove"; then
    assert_pass "post-run steps include a label-removal step"
else
    assert_fail "post-run steps include a label-removal step" \
        "step names found: $step_names"
fi

# ─── Test 13: post-run job has a step that adds a comment ────────────────────
print_test_section "13. post-run has a comment step"

if echo "$step_names" | grep -qi "comment"; then
    assert_pass "post-run steps include a comment step"
else
    assert_fail "post-run steps include a comment step" \
        "step names found: $step_names"
fi

# ─── Test 14: YAML is parseable (no syntax errors) ────────────────────────────
print_test_section "14. YAML syntax is valid"

set +e
yq_err="$(yq e '.' "$WORKFLOW" 2>&1 1>/dev/null)"
yq_rc=$?
set -e

if [[ $yq_rc -eq 0 ]]; then
    assert_pass "YAML is syntactically valid (yq parse succeeded)"
else
    assert_fail "YAML is syntactically valid" "yq error: $yq_err"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
print_test_results
