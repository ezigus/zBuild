#!/usr/bin/env bash
# Tests: a prompt of any size reaches the model — the router never puts it on
# the command line.
#
# Run 36238164552 (#1849): all six review lenses failed with
# "route.sh: /usr/bin/timeout: Argument list too long". The prompt carried a
# 1,600-line diff and went to claude as `-p "$prompt"`; one argv string over
# 128 KiB (Linux MAX_ARG_STRLEN) cannot be exec'd, so every lens reviewed
# nothing and the report said "no findings".
#
#   SPEC-1 [change]: route_to_model delivers a 1.1 MB prompt to claude intact
#   SPEC-2 [change]: route_to_model_loop delivers it intact too (build and
#                    test-author call the model through the loop)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router: a prompt of any size reaches the model (#1849 lenses)"
setup_test_env "router-prompt-size"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_REPO_ROOT="$REPO_ROOT"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/scratch" "$TEST_TEMP_DIR/state" "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# The mock records the prompt it received — from its argv after -p when there
# is one, else from stdin — and answers like a finished model call.
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "-p" && \$# -gt 1 && "\$2" != --* ]]; then
        printf '%s' "\$2" > "$TEST_TEMP_DIR/received"; echo "OK LOOP_COMPLETE"; exit 0
    fi
    shift
done
cat > "$TEST_TEMP_DIR/received"   # byte-exact: no \$(…) newline stripping
echo "OK LOOP_COMPLETE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
set +e

BIG="$TEST_TEMP_DIR/big-prompt.txt"
awk 'BEGIN { for (i = 0; i < 18000; i++) printf "diff line %06d: a changed line of the PR under review.........\n", i }' > "$BIG"
BIG_BYTES="$(wc -c < "$BIG" | tr -d ' ')"

print_test_section "SPEC-1: route_to_model"
: > "$TEST_TEMP_DIR/received"
route_to_model "T2" "$(cat "$BIG")" --skip-precondition >/dev/null 2>"$TEST_TEMP_DIR/sync.err"
_rc=$?
assert_eq "[SPEC-1] the call succeeds (${BIG_BYTES}-byte prompt)" "0" "$_rc"
# route_to_model takes the prompt as a string, so $(…) has already dropped the
# file's trailing newline; that string is what must arrive, byte for byte.
assert_eq "[SPEC-1] claude received the whole prompt" "$(printf '%s' "$(cat "$BIG")" | cksum)" "$(cksum < "$TEST_TEMP_DIR/received")"

print_test_section "SPEC-2: route_to_model_loop"
: > "$TEST_TEMP_DIR/received"
(
    route_to_model_loop T2 "$BIG" "$TEST_TEMP_DIR" 1 >/dev/null 2>"$TEST_TEMP_DIR/loop.err"
)
# The loop frames the prompt (intent header, iteration banner), so the check is
# containment: the first and last lines both arrived, and nothing was cut.
_got2="$(wc -c < "$TEST_TEMP_DIR/received" | tr -d ' ')"
assert_eq "[SPEC-2] the loop's call carries the prompt's first line" "1" "$(grep -cF 'diff line 000000:' "$TEST_TEMP_DIR/received")"
assert_eq "[SPEC-2] …and its last line (nothing truncated)" "1" "$(grep -cF 'diff line 017999:' "$TEST_TEMP_DIR/received")"
if [[ "$_got2" -ge "$BIG_BYTES" ]]; then assert_pass "[SPEC-2] …and at least the prompt's ${BIG_BYTES} bytes"
else assert_fail "[SPEC-2] …and at least the prompt's ${BIG_BYTES} bytes" "got $_got2"; fi

print_test_results
exit $((FAIL > 0))
