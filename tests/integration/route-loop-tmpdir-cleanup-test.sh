#!/usr/bin/env bash
# Integration: route_to_model_loop leaves no zb-loop-iters.* tmpdir behind
# on any post-mktemp exit path (#628).
#
# route_to_model_loop has SIX post-mktemp return points:
#   1. SIGINT propagation       → return 130 (had manual cleanup)
#   2. 3 consecutive timeouts   → return 2   (LEAKED pre-#628)
#   3. capture_diff fails       → return 2   (LEAKED pre-#628)
#   4. done_sentinel (success)  → return 0   (had manual cleanup)
#   5. no_progress (#613)       → return 0   (had manual cleanup)
#   6. max_iterations exhausted → return 1   (had manual cleanup)
#
# This test drives the loop down (2), (4), and (6) — each via a stub claude
# whose behaviour differs by env var. (1) is covered by the existing
# sigint-aborts-pipeline test; (3) is hard to provoke without breaking the
# repo mid-iter and the trap covers it identically. After each invocation
# we assert TMPDIR has no zb-loop-iters.* directory left.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: route_to_model_loop tmpdir self-cleanup (#628)"
setup_test_env "route-loop-tmpdir-cleanup"

# Pin TMPDIR to a known location so we can scan deterministically.
ISOLATED_TMP="$TEST_TEMP_DIR/iso-tmp"
mkdir -p "$ISOLATED_TMP"
export TMPDIR="$ISOLATED_TMP"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="loop-tmpdir-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Minimal fixture repo.
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# Stub claude. Behaviour switched by ZB_STUB_MODE:
#   sentinel    — print LOOP_COMPLETE on iter 1, exit 0.
#   maxiter     — print useless text every iter, never sentinel, exit 0.
#   timeout3    — exit 124 every call (mimics gtimeout SIGALRM rc).
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
case "${ZB_STUB_MODE:-sentinel}" in
    sentinel)
        jq -n --arg r $'all done\nLOOP_COMPLETE' \
            '{result:$r, usage:{input_tokens:1, output_tokens:1}}'
        exit 0
        ;;
    maxiter)
        jq -n --arg r $'still thinking' \
            '{result:$r, usage:{input_tokens:1, output_tokens:1}}'
        exit 0
        ;;
    timeout3)
        exit 124
        ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# Minimal template so stage-io banner doesn't barf.
cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
      tail_lines: 5
YAML

PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "loop tmpdir cleanup fixture" > "$PROMPT_FILE"

_count_leaked() {
    local n=0
    for d in "$TMPDIR"/zb-loop-iters.*; do
        [[ -e "$d" ]] || continue
        n=$(( n + 1 ))
    done
    printf '%s' "$n"
}

_drive_loop() {
    local mode="$1" max_iters="$2"
    local driver="$TEST_TEMP_DIR/driver.sh"
    local rc_out="$TEST_TEMP_DIR/rc.txt"
    cat > "$driver" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"

export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"
export TMPDIR="$TMPDIR"
export ZB_STUB_MODE="$mode"
# Cap per-call timeout low so the 124 path resolves fast.
export ZBUILD_ROUTER_TIMEOUT=2

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" "$max_iters"
rc=\$?
set -e
printf '%s' "\$rc" > "$rc_out"
EOF
    bash "$driver" >/dev/null 2>&1 || true
    cat "$rc_out" 2>/dev/null || echo missing
}

# ───────────────────────────────────────────────────────────────────────────
print_test_section "1. done_sentinel return path (rc=0, iter=1)"
# ───────────────────────────────────────────────────────────────────────────
RC="$(_drive_loop sentinel 5)"
assert_eq "sentinel: route_to_model_loop returned 0" "0" "$RC"
assert_eq "sentinel: no zb-loop-iters.* leaked" "0" "$(_count_leaked)"

# ───────────────────────────────────────────────────────────────────────────
print_test_section "2. max_iterations / no_progress return path (rc=0 or 1)"
# ───────────────────────────────────────────────────────────────────────────
# maxiter stub never emits sentinel and never edits the repo, so the loop
# either auto-terminates at no_progress (#613, after 2 empty iters → rc=0)
# or hits max_iterations (rc=1). Both paths previously cleaned up; both
# remain covered by the new RETURN trap.
RC="$(_drive_loop maxiter 2)"
assert_contains "maxiter: rc is 0 or 1" "0 1" "$RC"
assert_eq "maxiter: no zb-loop-iters.* leaked" "0" "$(_count_leaked)"

# ───────────────────────────────────────────────────────────────────────────
print_test_section "3. 3-consecutive-timeouts fatal return path (rc=2)"
# ───────────────────────────────────────────────────────────────────────────
# This is the path that LEAKED pre-#628 — three rc=124 iters in a row,
# fatal error, manual cleanup was missing, RETURN trap now reclaims.
RC="$(_drive_loop timeout3 5)"
assert_eq "timeout3: route_to_model_loop returned 2 (fatal)" "2" "$RC"
assert_eq "timeout3: no zb-loop-iters.* leaked" "0" "$(_count_leaked)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
