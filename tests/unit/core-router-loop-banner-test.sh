#!/usr/bin/env bash
# Unit test (#505): route_to_model_loop banner dedupe + --persist-input
# divergence.
#
# Locks the contract from ADR-018 §Pattern 2.5:
#   - The LLM's `claude -p <prompt>` argv MUST contain the FULL static prompt
#     on every iteration (no dedupe applied to the actual model payload).
#   - The stage_io BANNER input on iter ≥2 MUST be the deduped pointer form
#     ("[static prompt: same as iter 1, ...] ... [diff: see ── changed-files ──
#      summary below ...]") — operator scrollback noise reduction only.
#   - The artifact `.input` field MUST contain the FULL static prompt on every
#     iteration (via the new stage_io_begin --persist-input <path> flag), so
#     postmortem fidelity is preserved.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core-router-loop-banner — dedupe + persist-input (#505)"
setup_test_env "core-router-loop-banner"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="loop-banner-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

# Operator override so per-iteration redaction.applied stub satisfies C6.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ── Throwaway git repo for the loop to diff against. ─────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# ── Static prompt: large enough to exceed the dedupe minimum (≥500 chars). ──
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
{
    echo "BUILD STATIC PROMPT — UNIQUE TOKEN: ZB505_STATIC_BODY_SENTINEL"
    # Pad to comfortably exceed the 500-char dedupe minimum.
    for i in $(seq 1 20); do
        echo "Line $i: lorem ipsum dolor sit amet, consectetur adipiscing elit."
    done
} > "$PROMPT_FILE"

# ── Rotating mock claude: records argv + -p prompt per call, emits
# LOOP_COMPLETE on call 3. Edits a file each call so git diff has content.
mkdir -p "$TEST_TEMP_DIR/bin"
ARGV_DIR="$TEST_TEMP_DIR/argv-by-call"
PROMPT_DIR="$TEST_TEMP_DIR/prompt-by-call"
COUNTER="$TEST_TEMP_DIR/call-counter"
mkdir -p "$ARGV_DIR" "$PROMPT_DIR"
: > "$COUNTER"

cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Increment per-call counter.
n=$(( $(wc -l < "$COUNTER" 2>/dev/null | tr -d ' ') + 1 ))
echo "x" >> "$COUNTER"

# Record full argv (NUL-delimited for fidelity) and -p prompt to per-call files.
for a in "$@"; do printf '%s\0' "$a"; done > "$ARGV_DIR/call-${n}.argv"
prompt_text=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) prompt_text="${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done
printf '%s' "$prompt_text" > "$PROMPT_DIR/call-${n}.prompt"

# Mutate working tree so subsequent iterations have non-empty git diff.
printf 'iter-%d\n' "$n" >> "$PWD/work.txt"

# On call 3 emit LOOP_COMPLETE to terminate; earlier calls continue.
if [[ "$n" -ge 3 ]]; then
    jq -n --arg r $'done\nLOOP_COMPLETE' \
        '{type:"result",result:$r,usage:{input_tokens:5,output_tokens:3}}'
else
    jq -n --arg r "iter ${n} progress" \
        '{type:"result",result:$r,usage:{input_tokens:5,output_tokens:3}}'
fi
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export ARGV_DIR PROMPT_DIR COUNTER

# ── Template: build stage with file+stdout destinations. ────────────────────
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

# ── Subprocess driver: real route_to_model_loop with fd 3 capture. ─────────
DRIVER="$TEST_TEMP_DIR/driver.sh"
BANNER_FD3="$TEST_TEMP_DIR/banner-fd3.txt"

cat > "$DRIVER" <<EOF
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
export ARGV_DIR="$ARGV_DIR"
export PROMPT_DIR="$PROMPT_DIR"
export COUNTER="$COUNTER"

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 5
EOF

ZBUILD_STAGE_IO_FD=3 bash "$DRIVER" >/dev/null 2>/dev/null 3>"$BANNER_FD3" || true

# ─── Assertions ──────────────────────────────────────────────────────────────

# (0) Sanity: mock invoked 3 times.
call_count="$(wc -l < "$COUNTER" | tr -d ' ')"
assert_eq "mock claude invoked exactly 3 times" "3" "$call_count"

# Helper: read -p prompt for a given call number from PROMPT_DIR.
_read_prompt() { cat "$PROMPT_DIR/call-$1.prompt" 2>/dev/null || true; }

# (1) LLM payload on EVERY iteration contains the full static prompt sentinel.
#     (Dedupe must NOT touch what claude actually receives.)
for n in 1 2 3; do
    p="$(_read_prompt "$n")"
    if [[ "$p" == *"ZB505_STATIC_BODY_SENTINEL"* ]]; then
        assert_pass "call $n: claude -p prompt contains full static body sentinel"
    else
        assert_fail "call $n: claude -p prompt contains full static body sentinel" \
            "head=$(printf '%s' "$p" | head -c 120)"
    fi
done

# (2) Iter ≥2 banner input MUST be the deduped pointer form. Use the file
#     artifact's "head" snippet rendered into the banner; the begin banner
#     includes a head of the input on stdout. We grep fd 3 for the marker.
banner="$(cat "$BANNER_FD3" 2>/dev/null || echo '')"

# Extract just the banner block for seq=2 input through seq=2 output.
_extract_seq_input_block() {
    local s="$1"
    awk -v s="$s" '
        $0 ~ ("seq="s" input")  { capture=1 }
        capture { print }
        $0 ~ ("seq="s" output") { if (capture) exit }
    ' <<< "$banner"
}

for s in 2 3; do
    blk="$(_extract_seq_input_block "$s")"
    if [[ "$blk" == *"[static prompt: same as iter 1"* ]]; then
        assert_pass "seq=$s banner input contains '[static prompt: same as iter 1' pointer"
    else
        assert_fail "seq=$s banner input contains '[static prompt: same as iter 1' pointer" \
            "blk_head=$(printf '%s' "$blk" | head -c 200)"
    fi

    if [[ "$blk" == *"[diff: "* ]]; then
        assert_pass "seq=$s banner input contains '[diff: ...]' pointer"
    else
        assert_fail "seq=$s banner input contains '[diff: ...]' pointer" \
            "blk_head=$(printf '%s' "$blk" | head -c 200)"
    fi

    # Negative: the full static body sentinel MUST NOT appear in iter ≥2 banner.
    if [[ "$blk" == *"ZB505_STATIC_BODY_SENTINEL"* ]]; then
        assert_fail "seq=$s banner input is deduped (no full static body)" \
            "blk_head=$(printf '%s' "$blk" | head -c 200)"
    else
        assert_pass "seq=$s banner input is deduped (no full static body)"
    fi
done

# (3) Artifact file `.input` on EVERY iteration MUST contain the full static
#     prompt sentinel — postmortem fidelity guarded by --persist-input.
for s in 1 2 3; do
    art="$ZBUILD_STATE_DIR/artifacts/stage-io/build-${s}.json"
    assert_file_exists "build-${s}.json artifact written" "$art"
    if [[ -f "$art" ]]; then
        in_field="$(jq -r '.input' "$art" 2>/dev/null || true)"
        if [[ "$in_field" == *"ZB505_STATIC_BODY_SENTINEL"* ]]; then
            assert_pass "build-${s}.json .input contains full static prompt (persist-input)"
        else
            assert_fail "build-${s}.json .input contains full static prompt (persist-input)" \
                "in_head=$(printf '%s' "$in_field" | head -c 120)"
        fi
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
