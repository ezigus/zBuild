#!/usr/bin/env bash
# tests/unit/router-effort-test.sh — how hard the model thinks is a router
# setting, medium unless a stage says otherwise (#2454, ADR-017 §11).
#
# Why: on #1805 (run 41452299475) one test-author thinking turn ran for seven
# minutes and stopped at the 32,000-token output limit, cut off mid-thought.
# The router passed no --effort, so every call ran at the CLI's default.
#
# E1 [change] validate_manifest accepts config.router.effort: low|medium|high|
#             xhigh|max and refuses any other word
# E2 [change] a single call passes --effort medium when the plugin declares
#             none, and the declared word when it declares one
# E3 [change] a loop call (build, test-author) passes it too
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the router passes --effort, medium by default (#2454)"
setup_test_env "router-effort"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/scratch" "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
unset ZBUILD_RUN_ID 2>/dev/null || true

# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

_mk_plugin() {  # <name> <router-block-body> → plugin dir
    local dir="$TEST_TEMP_DIR/plugins/agent/$1"
    mkdir -p "$dir"
    {
        printf 'id: %s\nname: Fixture\nkind: agent\nversion: 0.0.1\nsummary: fixture\n' "$1"
        printf 'hooks:\n  run: f_run\n'
        printf 'requires:\n  core:\n    - redaction\n'
        # #2507 (ADR-017 §12): a stage's model call is listed, or refused.
        printf 'calls:\n  main: [read-files, edit-files]\n'
        printf 'config:\n  router:\n%s' "$2"
    } > "$dir/manifest.yaml"
    printf '%s' "$dir"
}

print_test_section "E1: validate_manifest and config.router.effort"
_hi="$(_mk_plugin hi '    effort: high
')"
_valid() { validate_manifest "$1/manifest.yaml" >/dev/null 2>&1 && echo ok || echo refused; }
assert_eq "[E1] effort: high is accepted" "ok" "$(_valid "$_hi")"
for _w in low medium xhigh max; do
    assert_eq "[E1] effort: $_w is accepted" "ok" "$(_valid "$(_mk_plugin "w-$_w" "    effort: $_w
")")"
done
assert_eq "[E1] any other word is refused" "refused" "$(_valid "$(_mk_plugin huge '    effort: huge
')")"

cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/argv"
cat >/dev/null
jq -n '{type:"result", result:"done\nLOOP_COMPLETE", usage:{input_tokens:1, output_tokens:1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
_effort_in() { awk 'p { print; exit } $0 == "--effort" { p = 1 }' "$TEST_TEMP_DIR/argv" 2>/dev/null; }

print_test_section "E2: a single call"
_dflt="$(_mk_plugin dflt '    max_turns: 3
')"
rm -f "$TEST_TEMP_DIR/argv"
ZBUILD_PLUGIN_DIR="$_dflt" route_to_model T1 "ping" --skip-precondition >/dev/null 2>&1 || true
assert_eq "[E2] no effort declared → --effort medium" "medium" "$(_effort_in)"
rm -f "$TEST_TEMP_DIR/argv"
ZBUILD_PLUGIN_DIR="$_hi" route_to_model T1 "ping" --skip-precondition >/dev/null 2>&1 || true
assert_eq "[E2] effort: high declared → --effort high" "high" "$(_effort_in)"

print_test_section "E3: a loop call"
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null
# A stage's loop prompt is held to the contract order (ADR-067 §8), so compose one.
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
stage_prompt_compose_parts "$(printf '%s\ndo the thing\n%s\njudge it\n%s\nlimits\n' "$_ZB_SP_OWN" "$_ZB_SP_JUDGE" "$_ZB_SP_LIMITS")" > "$PROMPT_FILE"
rm -f "$TEST_TEMP_DIR/argv"
( cd "$REPO" && ZBUILD_PLUGIN_DIR="$_dflt" route_to_model_loop T2 "$PROMPT_FILE" "$REPO" ) >/dev/null 2>&1 || true
assert_contains "[E3] the loop call reached claude" "$(cat "$TEST_TEMP_DIR/argv" 2>/dev/null)" "--print"
assert_eq "[E3] a loop call passes --effort medium" "medium" "$(_effort_in)"
rm -f "$TEST_TEMP_DIR/argv"
( cd "$REPO" && ZBUILD_PLUGIN_DIR="$_hi" route_to_model_loop T2 "$PROMPT_FILE" "$REPO" ) >/dev/null 2>&1 || true
assert_eq "[E3] ...and the declared word" "high" "$(_effort_in)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
