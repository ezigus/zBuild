#!/usr/bin/env bash
# Tests: stage-io stdout vs stderr channel split (regression for #449)
#
# This test exists because the existing stage-io integration tests are
# same-shell sourced-function tests that happen to use `2>/dev/null` and
# `$()` — patterns which mask the exact bug we shipped in #438/#440 and
# the user only caught in real pipeline runs.
#
# A *real* integration test for the stdout destination must:
#   (a) fork a subprocess boundary (so `set -e`, file descriptors, and
#       `bash work-unit.sh > stdout-file 2> stderr-file` semantics match
#       the orch local engine's actual plugin-dispatch path);
#   (b) capture fd 1 and fd 2 of the subprocess SEPARATELY;
#   (c) assert that `$()` callers of `route_to_model` see only the LLM
#       response on stdout while the operator's terminal still gets the
#       stage-io banner on stderr.
#
# Calling route_to_model inside a sourced function with `2>/dev/null` —
# which is what tests/integration/stage-io-capture-test.sh does — passes
# whether the banner goes to fd 1, fd 2, or fd 27. This file closes that
# coverage gap at the integration tier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io stdout/stderr channel split (subprocess integration)"
setup_test_env "stage-io-channel-split"

# ─── Set up isolated state + mock claude on PATH ─────────────────────────────
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="channel-split-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

# Operator override token so route_to_model accepts --skip-precondition
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "$ZBUILD_RUN_ID" > "$HOME/.zbuild/scope-override-token"
assert_contains "[SPEC-1] RUN_ID includes process id" "$ZBUILD_RUN_ID" "$$"
assert_eq "[SPEC-3] scope-override-token matches RUN_ID" "$ZBUILD_RUN_ID" "$(cat "$HOME/.zbuild/scope-override-token")"
export ZBUILD_SCOPE_OVERRIDE=1

# Mock claude — emits a known response on stdout
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "LLM_RESPONSE_PAYLOAD"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# Make a minimal template that turns on stdout for the plan stage
cat > "$TEST_TEMP_DIR/state/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file, stdout]
      tail_lines: 5
YAML

# ─── Subprocess harness — this is the key test design ───────────────────────
# Each case runs the production code path (route_to_model + capture_stage_io)
# in a forked subprocess, with stdout and stderr DIRECTED TO SEPARATE FILES.
# We can then assert exactly what each channel saw — no merging via `2>&1`
# and no $() capture that would conflate the streams.

run_in_subprocess() {
    # $1 = path to script body
    # Sets globals: $SUBPROC_STDOUT (file), $SUBPROC_STDERR (file), $SUBPROC_RC
    SUBPROC_STDOUT="$TEST_TEMP_DIR/subproc.stdout"
    SUBPROC_STDERR="$TEST_TEMP_DIR/subproc.stderr"
    SUBPROC_FD3="$TEST_TEMP_DIR/subproc.fd3"
    rm -f "$SUBPROC_STDOUT" "$SUBPROC_STDERR" "$SUBPROC_FD3"
    # Allocate fd 3 the way the runner does (exec 3>&2). For the test we
    # redirect fd 3 to a file so we can inspect it independently.
    set +e
    ZBUILD_STAGE_IO_FD=3 bash "$1" >"$SUBPROC_STDOUT" 2>"$SUBPROC_STDERR" 3>"$SUBPROC_FD3"
    SUBPROC_RC=$?
    set -e
}

# ─── Case 1: stdout destination — banner must NOT pollute fd 1 ──────────────
# This replicates what the plan plugin does at plugins/agent/plan/plugin.sh:163:
#     raw_response="$(route_to_model "$tier" "$prompt" 2>/dev/null)"
# We instead capture fd 1 and fd 2 separately to inspect what each got.

cat > "$TEST_TEMP_DIR/case1.sh" <<EOF
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
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"

load_template "$TEST_TEMP_DIR/state/template.yaml"
export ZBUILD_CURRENT_STAGE=plan
route_to_model T2 "the prompt body" --skip-precondition
EOF

run_in_subprocess "$TEST_TEMP_DIR/case1.sh"
case1_stdout="$(cat "$SUBPROC_STDOUT")"
case1_stderr="$(cat "$SUBPROC_STDERR")"
case1_fd3="$(cat "$SUBPROC_FD3")"

# Acceptance — these are the assertions that catch the production bug:
assert_eq "Case 1 subprocess rc=0" "0" "$SUBPROC_RC"

# fd 1 must contain ONLY the LLM response (route_to_model's contract). The
# stage-io banner — if it leaks here — would corrupt every caller using $().
assert_contains "Case 1 stdout contains the LLM response" "$case1_stdout" "LLM_RESPONSE_PAYLOAD"

if echo "$case1_stdout" | grep -q "stage-io: plan"; then
    assert_fail "Case 1 stdout must NOT contain the stage-io banner" "got banner on fd 1 — \$() callers would see it as part of raw_response"
else
    assert_pass "Case 1 stdout must NOT contain the stage-io banner"
fi

# fd 3 (the runner-allocated stage-io channel) must contain the banner so
# the operator's terminal still gets it even when the plugin suppresses
# stderr via 2>/dev/null. This is the property that fd 2 alone could not
# satisfy and what the new ZBUILD_STAGE_IO_FD convention solves.
assert_contains "Case 1 fd 3 contains the stage-io banner" "$case1_fd3" "stage-io: plan"
assert_contains "Case 1 fd 3 banner has end marker" "$case1_fd3" "end stage-io: plan"

# ─── Case 2: $()-capture purity — what the plan plugin actually does ────────
# Replicate plugins/agent/plan/plugin.sh:163 exactly:
#     raw_response="$(route_to_model "$tier" "$prompt" 2>/dev/null)"
# The captured raw_response must equal the LLM payload and ONLY the LLM
# payload — no banner contamination — even though stdout destination is on.

cat > "$TEST_TEMP_DIR/case2.sh" <<EOF
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
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"

load_template "$TEST_TEMP_DIR/state/template.yaml"
export ZBUILD_CURRENT_STAGE=plan

# Exactly the plan plugin's idiom:
raw_response="\$(route_to_model T2 "the prompt body" --skip-precondition 2>/dev/null)"
# Print to stdout so the parent can see what the plugin would have captured:
printf 'CAPTURED:%s\n' "\$raw_response"
EOF

run_in_subprocess "$TEST_TEMP_DIR/case2.sh"
case2_stdout="$(cat "$SUBPROC_STDOUT")"
case2_fd3="$(cat "$SUBPROC_FD3")"

assert_eq "Case 2 subprocess rc=0" "0" "$SUBPROC_RC"
assert_contains "Case 2 captured response contains the LLM payload" "$case2_stdout" "CAPTURED:LLM_RESPONSE_PAYLOAD"

# THE assertion that the production bug would have failed: the captured
# raw_response must NOT contain banner fragments. If `── stage-io:` leaks
# into the captured string, every downstream JSON parser (plan validator,
# build diff extractor) breaks.
if echo "$case2_stdout" | grep -q "stage-io: plan"; then
    assert_fail "Case 2 captured response must NOT contain banner" "got banner inside \$() — would corrupt every JSON-parsing caller"
else
    assert_pass "Case 2 captured response must NOT contain banner"
fi

# AND fd 3 still gets the banner even though the plugin's idiom suppresses
# fd 2 (the `2>/dev/null` inside the $(...)). This is the property the
# production user saw fail before this PR.
assert_contains "Case 2 fd 3 contains banner despite plugin's 2>/dev/null" "$case2_fd3" "stage-io: plan"

# ─── Case 3: artifact still written despite the channel split ───────────────
# The banner went to stderr; the file destination is independent. Confirm
# the JSON artifact still landed on disk — this is the same property we
# already tested in the existing integration test, here as a regression
# guard so a future "send everything to stderr" overcorrection doesn't
# break the file destination.

# Case 1 ran the plan stage; expect plan-1.json
if [[ -f "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json" ]]; then
    assert_pass "Case 3 file artifact written despite channel split"
else
    # Case 2's run produced plan-2.json
    if ls "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-"*.json >/dev/null 2>&1; then
        assert_pass "Case 3 file artifact written despite channel split"
    else
        assert_fail "Case 3 file artifact written despite channel split" "no plan-*.json found"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
