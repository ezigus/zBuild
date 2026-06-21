#!/usr/bin/env bash
# Unit test (Wave 11B, #646): the build plugin's post-loop discrepancy warn
# ("build: LLM signaled success but numstat shows 0 files changed") MUST land
# INSIDE the final LLM iter's stage-io banner pair on fd 2, not in the
# inter-stage gap after `── end stage-io: build ✓ ──`.
#
# Drives a real route_to_model_loop + a mock claude that emits LOOP_COMPLETE
# without touching the working tree (so numstat is 0/0/0), then invokes
# _build_emit_changed_files_summary the way plugin.sh now does — after the
# loop returns but BEFORE _route_loop_close_final_banner flushes the deferred
# close. Captures fd 2 (where stage-io banners and `warn` both write) and
# asserts the line ordering.
#
# Pinned contract (Wave 11B):
#   - route_to_model_loop --defer-final-banner-close exposes the final iter's
#     banner-close parameters via _ROUTE_LOOP_FINAL_* globals.
#   - On the done_sentinel exit path, the last iter's banner stays OPEN until
#     the caller flushes via _route_loop_close_final_banner.
#   - Anything emitted between loop return and the flush appears INSIDE the
#     banner pair (between the `seq=N input` / `seq=N output` headers and the
#     `── end stage-io: ... ──` trailer).
#   - The discrepancy warn fires for terminated_reason=done_sentinel AND
#     numstat=0/0/0 AND scope_violation=false (preserved from #587).
#   - build.discrepancy.detected + build.diff.empty_after_done_sentinel events
#     still fire on the bus (event contract NOT regressed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build discrepancy warn — inside banner pair (Wave 11B, #646)"
setup_test_env "build-discrepancy-warn-inside-banner"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-warn-banner-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

# Operator override so per-iteration redaction stub satisfies C6 in route_loop.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ── Throwaway git repo for the loop to diff against. ─────────────────────────
# Critical: the mock claude below does NOT mutate the tree, so `git diff HEAD`
# is empty → files_count=0 → discrepancy condition triggers.
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# ── Static prompt (large enough that route_loop doesn't error). ─────────────
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
{
    echo "BUILD STATIC PROMPT — Wave 11B #646 banner-warn ordering test"
    for i in $(seq 1 20); do
        echo "Line $i: lorem ipsum dolor sit amet, consectetur adipiscing elit."
    done
} > "$PROMPT_FILE"

# ── Mock claude that emits LOOP_COMPLETE on call 1 and writes NOTHING to disk.
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Do NOT touch $PWD — leave numstat at 0/0/0.
jq -n --arg r $'all done\nLOOP_COMPLETE' \
    '{type:"result",result:$r,usage:{input_tokens:5,output_tokens:3}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# ── Template: build stage with stdout destination so banner emits. ──────────
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
      destinations: [file, stdout]
      tail_lines: 5
YAML

# ── Subprocess driver: real route_to_model_loop + real build helper.
#
# route.sh:758's stage_io_begin call is wrapped with `>/dev/null 2>&1`, which
# means the banner emit's `>&"${ZBUILD_STAGE_IO_FD:-2}"` resolves to /dev/null
# when ZBUILD_STAGE_IO_FD defaults to 2. The production runner sidesteps this
# by opening fd 3 BEFORE the suppression and exporting ZBUILD_STAGE_IO_FD=3.
# We mirror that: banners route to fd 3 (which we redirect to BANNER_LOG), and
# `warn` lines flow to fd 2 (redirected to FD2_LOG). We then INTERLEAVE the
# two streams in order via a single combined capture: route both streams to
# the SAME file from the outer redirect.
DRIVER="$TEST_TEMP_DIR/driver.sh"
FD2_LOG="$TEST_TEMP_DIR/combined.log"

cat > "$DRIVER" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"
# Route banners to fd 3 (mirrors production runner). The outer redirect
# below merges fd 3 → fd 2 so both streams interleave into the combined log.
export ZBUILD_STAGE_IO_FD=3

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build

# Run the loop with the new defer flag. Mock claude returns LOOP_COMPLETE on
# call 1 so we exit via done_sentinel and the final banner is deferred.
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 3 --defer-final-banner-close

# This is the moment plugin.sh now exercises: post-loop summary + warn,
# THEN the deferred banner close. The warn MUST appear between the banner's
# begin and end on fd 2.
_BUILD_PLAN_FILES_CSV="" \
_build_emit_changed_files_summary \
    "$REPO" "done_sentinel" "false" ""

# Flush deferred banner close (mirrors plugin.sh post-warn flush).
_route_loop_close_final_banner
EOF

# Combined capture: stdout→/dev/null, fd 2 (warn) + fd 3 (banners) → FD2_LOG.
# Order: open fd 2 to log, redirect fd 3 to fd 2 so they interleave.
# Driver rc is intentionally swallowed — assertions run against the captured
# fd 2/3 log regardless of exit code (the assertions ARE the test).
bash "$DRIVER" >/dev/null 2>"$FD2_LOG" 3>&2 || true

fd2="$(cat "$FD2_LOG" 2>/dev/null || true)"

# ─── Assertions ──────────────────────────────────────────────────────────────

# (0) Sanity: we captured banner output AND the warn line.
if [[ "$fd2" == *"stage-io: build"* ]]; then
    assert_pass "fd2 contains build stage-io banner output"
else
    assert_fail "fd2 contains build stage-io banner output" \
        "head=$(printf '%s' "$fd2" | head -c 300)"
fi

if [[ "$fd2" == *"LLM signaled success but numstat shows 0 files changed"* ]]; then
    assert_pass "fd2 contains discrepancy warn line"
else
    assert_fail "fd2 contains discrepancy warn line" \
        "head=$(printf '%s' "$fd2" | head -c 500)"
fi

# (1) Core ordering invariant: the warn line MUST come BEFORE the
#     `── end stage-io: build ──` close-banner line. If the warn fired AFTER
#     the close (legacy bug), this assertion fails — that is exactly the
#     "stray stderr line in the inter-stage gap" regression Wave 11B fixes.
warn_lineno="$(printf '%s\n' "$fd2" \
    | grep -n -F "LLM signaled success but numstat shows 0 files changed" \
    | head -1 | cut -d: -f1)"
end_lineno="$(printf '%s\n' "$fd2" \
    | grep -n -F "── end stage-io: build" \
    | head -1 | cut -d: -f1)"

if [[ -n "$warn_lineno" && -n "$end_lineno" && "$warn_lineno" -lt "$end_lineno" ]]; then
    assert_pass "warn appears before close-banner (warn line $warn_lineno < end line $end_lineno)"
else
    assert_fail "warn appears before close-banner" \
        "warn_lineno=$warn_lineno end_lineno=$end_lineno"
fi

# (2) The warn ALSO must come AFTER the iter's `seq=N input` open-banner so
#     it's strictly between begin and end (not somewhere before begin entirely).
input_lineno="$(printf '%s\n' "$fd2" \
    | grep -nE "build \[(llm|computed|command)\] seq=[0-9]+ input" \
    | head -1 | cut -d: -f1)"
if [[ -n "$input_lineno" && -n "$warn_lineno" && "$input_lineno" -lt "$warn_lineno" ]]; then
    assert_pass "warn appears after open-banner (input line $input_lineno < warn line $warn_lineno)"
else
    assert_fail "warn appears after open-banner" \
        "input_lineno=$input_lineno warn_lineno=$warn_lineno"
fi

# (3) Event contract: build.discrepancy.detected fired.
det_count="$(jq -c --arg t "build.discrepancy.detected" \
    'select(.type==$t)' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$det_count" -ge 1 ]]; then
    assert_pass "build.discrepancy.detected event still fires (event contract preserved)"
else
    assert_fail "build.discrepancy.detected event still fires" "count=$det_count"
fi

# (4) Event contract: build.diff.empty_after_done_sentinel fired.
emp_count="$(jq -c --arg t "build.diff.empty_after_done_sentinel" \
    'select(.type==$t)' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$emp_count" -ge 1 ]]; then
    assert_pass "build.diff.empty_after_done_sentinel event still fires (event contract preserved)"
else
    assert_fail "build.diff.empty_after_done_sentinel event still fires" "count=$emp_count"
fi

# (5) No [computed] banner pair reintroduced (#587 contract).
if grep -q "build \[computed\]" <<< "$fd2"; then
    assert_fail "no [computed] banner pair (preserves #587 removal)" \
        "found build [computed] in fd2 capture"
else
    assert_pass "no [computed] banner pair (preserves #587 removal)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
