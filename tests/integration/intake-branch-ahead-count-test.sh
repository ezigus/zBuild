#!/usr/bin/env bash
# Tests: intake ahead_count uses resolved default branch, not hardcoded 'main'
# SPEC-1: reused path ahead_count correct when default branch is 'master'
# SPEC-2: adopted path ahead_count correct when default branch is 'master'
# Also exercises the unresolvable fallback → ahead_count=unknown
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "intake ahead_count default-branch resolution (#1648)"

setup_test_env "intake-ahead-count"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../plugins/agent/intake/plugin.sh
source "$REPO_ROOT/plugins/agent/intake/plugin.sh"

unset CI CI_MODE

_reset_events() { : > "$ZBUILD_EVENTS_JSONL"; }
_last_event_field() {
    local event_type="$1" field="$2"
    grep "\"$event_type\"" "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
        | tail -1 \
        | jq -r ".data.$field // empty" 2>/dev/null \
        || true
}

# _make_master_repo <label>
# Creates a bare origin repo with 'master' as default branch, then clones it.
# Prints the path to the working clone. The clone has origin/HEAD → origin/master.
_make_master_repo() {
    local label="$1"
    local bare="$TEST_TEMP_DIR/bare-${label}.git"
    local work="$TEST_TEMP_DIR/work-${label}"
    local tmp_init="$TEST_TEMP_DIR/init-${label}"

    # Create bare repo; set HEAD → master regardless of git's default.
    git init --bare "$bare" >/dev/null 2>&1
    git -C "$bare" symbolic-ref HEAD "refs/heads/master" 2>/dev/null

    # Seed bare via a throwaway clone: add an initial commit and push.
    # The subshell's rc is checked — a silently-failed seed would otherwise leave
    # an empty bare repo, and the failure would surface much later as a baffling
    # assertion mismatch instead of "setup failed".
    git clone "$bare" "$tmp_init" >/dev/null 2>&1
    (
        set -e
        cd "$tmp_init"
        git config user.email "test@zbuild.local"
        git config user.name "zbuild-test"
        git config commit.gpgsign false
        # Unborn HEAD: -b names the branch regardless of init.defaultBranch.
        git checkout -q -b master 2>/dev/null || git symbolic-ref HEAD refs/heads/master
        echo "seed" > seed.txt
        git add seed.txt
        git commit -q -m "seed"
        git push -q origin HEAD:"refs/heads/master"
    ) >/dev/null 2>&1 || { printf '' ; return 1; }
    rm -rf "$tmp_init"

    # The bare repo MUST now carry master; a bare `.git` check downstream cannot
    # tell "seeded" from "empty", and an unborn HEAD makes `checkout master` a no-op.
    git -C "$bare" show-ref --verify --quiet refs/heads/master || { printf ''; return 1; }

    # Clone for the test; git sets origin/HEAD → origin/master automatically.
    git clone "$bare" "$work" >/dev/null 2>&1 || { printf ''; return 1; }
    (
        cd "$work"
        git config user.email "test@zbuild.local"
        git config user.name "zbuild-test"
        git config commit.gpgsign false
    ) >/dev/null 2>&1

    printf '%s\n' "$work"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SPEC-1: reused path — ahead_count uses resolved default ('master'), not 'main'
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "SPEC-1: reused path ahead_count with master default branch"

REPO_A="$(_make_master_repo "a")"
if [[ -z "$REPO_A" || ! -d "$REPO_A/.git" ]]; then
    assert_fail "repo-a setup" "no .git at ${REPO_A:-<empty>}"
    cleanup_test_env
    print_test_results
    exit 1
fi

cd "$REPO_A"
# Two commits ahead of master on a feature branch.
git checkout -q master 2>/dev/null || true
git checkout -q -b zbuild/issue-1648-reused
echo "change1" > change1.txt && git add change1.txt && git commit -q -m "change 1"
echo "change2" > change2.txt && git add change2.txt && git commit -q -m "change 2"
# Switch back so the reused path is exercised on next call.
git checkout -q master

_reset_events
_intake_checkout_branch "zbuild/issue-1648-reused" >/dev/null 2>&1

reused_count="$(grep -c '"intake.branch.reused"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
assert_gt "[SPEC-1] intake.branch.reused emitted on feature branch re-checkout" \
    "$reused_count" "0"

ahead_val="$(_last_event_field "intake.branch.reused" "ahead_count")"
assert_eq "[SPEC-1] ahead_count=2 when default branch is 'master' (not hardcoded 'main')" \
    "2" "$ahead_val"

# ═══════════════════════════════════════════════════════════════════════════════
# SPEC-2: adopted path — ahead_count uses resolved default ('master'), not 'main'
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "SPEC-2: adopted path ahead_count with master default branch"

REPO_B="$(_make_master_repo "b")"
if [[ -z "$REPO_B" || ! -d "$REPO_B/.git" ]]; then
    assert_fail "repo-b setup" "no .git at ${REPO_B:-<empty>}"
    cleanup_test_env
    print_test_results
    exit 1
fi

cd "$REPO_B"
git checkout -q master 2>/dev/null || true
# Create remote-only branch: 2 commits ahead of master, pushed then deleted locally.
git checkout -q -b zbuild/issue-1648-adopted
echo "ra1" > ra1.txt && git add ra1.txt && git commit -q -m "remote commit 1"
echo "ra2" > ra2.txt && git add ra2.txt && git commit -q -m "remote commit 2"
git push -q origin zbuild/issue-1648-adopted
git checkout -q master
git branch -D zbuild/issue-1648-adopted

_reset_events
_intake_checkout_branch "zbuild/issue-1648-adopted" >/dev/null 2>&1

adopted_count="$(grep -c '"intake.branch.adopted"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
assert_gt "[SPEC-2] intake.branch.adopted emitted for remote-only branch" \
    "$adopted_count" "0"

adopted_ahead="$(_last_event_field "intake.branch.adopted" "ahead_count")"
assert_eq "[SPEC-2] ahead_count=2 on adopted branch (master-default repo)" \
    "2" "$adopted_ahead"

# ═══════════════════════════════════════════════════════════════════════════════
# Unresolvable default branch → ahead_count=unknown
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "unresolvable default branch → ahead_count=unknown"

REPO_C="$TEST_TEMP_DIR/work-c"
mkdir -p "$REPO_C"
(
    cd "$REPO_C"
    git init -q
    git config user.email "test@zbuild.local"
    git config user.name "zbuild-test"
    git config commit.gpgsign false
    # Name the branch on the UNBORN HEAD, before the first commit: no main/master
    # ref is ever created, so the helper's local fallback has nothing to match and
    # must return empty. Doing this up front makes the fixture independent of the
    # host's init.defaultBranch — the earlier conditional-rename dance was not.
    git checkout -q -b customdev 2>/dev/null || git symbolic-ref HEAD refs/heads/customdev
    echo "seed" > seed.txt && git add seed.txt && git commit -q -m "seed"
    # Feature branch 1 commit ahead.
    git checkout -q -b zbuild/issue-1648-unresolvable
    echo "x" > x.txt && git add x.txt && git commit -q -m "x"
    git checkout -q customdev
) >/dev/null 2>&1

cd "$REPO_C"
_reset_events
_intake_checkout_branch "zbuild/issue-1648-unresolvable" >/dev/null 2>&1

reused_c="$(grep -c '"intake.branch.reused"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
assert_gt "unresolvable: intake.branch.reused emitted" "$reused_c" "0"

unknown_ahead="$(_last_event_field "intake.branch.reused" "ahead_count")"
assert_eq "ahead_count=unknown when default branch is unresolvable" \
    "unknown" "$unknown_ahead"

# ─── Cleanup ────────────────────────────────────────────────────────────────
cd "$REPO_ROOT" || true
cleanup_test_env
print_test_results
exit $((FAIL > 0))
