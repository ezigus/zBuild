#!/usr/bin/env bash
# tests/unit/private-paths-test.sh — every stage sees every file except private
# ones (#2379, ADR-004, ADR-043, ADR-058).
#
# Why: the router wrapped every path outside the run's scope in an out-of-scope
# marker. That only labelled the path (a model could still read the file), it
# wrapped the very files the engine tells a stage to write, and with CI's `+ ./`
# it allowed everything anyway. What must stay away from a model is a private
# file — keys, credentials, secrets — and that is a property of the repository,
# not of a stage.
#
#   P1 [change] the engine's own private paths apply to every repository
#   P2 [change] the template and the repository's .zbuild/ add to them; a
#               repository cannot remove an engine default
#   P3 [change] a private path is taken out of a prompt; any other path — in
#               the repository or the run's artifacts — is left as it is, with
#               no out-of-scope marker
#   P4 [change] every model call is denied reading and editing a private path
#   P5 [change] the router redacts every prompt, with or without a scope manifest
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every stage sees every file except private ones (#2379)"
setup_test_env "private-paths"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../scripts/lib/private-paths.sh
source "$REPO_ROOT/scripts/lib/private-paths.sh" 2>/dev/null || true
# shellcheck source=../../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/.zbuild" "$R/src"
TPL="$TEST_TEMP_DIR/template.yaml"
printf 'private_paths:\n  - vault/\n' > "$TPL"
printf 'internal/payroll/\n# a comment\n!.env\n' > "$R/.zbuild/private-paths"

print_test_section "P1/P2: the list"
_list="$(_TPL_SOURCE_FILE="$TPL" private_paths_list "$R" 2>/dev/null)"
for _d in .zbuild/secrets/ .env '.env.*' '*.pem' '*.key' 'id_rsa*' 'id_ed25519*' .aws/credentials .npmrc .netrc .git/; do
    if grep -qxF -- "$_d" <<< "$_list"; then assert_pass "[P1] engine default: $_d"
    else assert_fail "[P1] engine default: $_d" "missing from: $(tr '\n' ' ' <<< "$_list")"; fi
done
assert_contains "[P2] the template adds a location" "$_list" "vault/"
assert_contains "[P2] .zbuild/ adds a location" "$_list" "internal/payroll/"
assert_eq "[P2] a repository cannot remove an engine default" "0" "$(grep -c '^!' <<< "$_list" || true)"

print_test_section "P3: what a prompt keeps"
IN="$TEST_TEMP_DIR/in.txt"; OUT="$TEST_TEMP_DIR/out.txt"; M="$TEST_TEMP_DIR/scope.md"
printf '+ src/\n' > "$M"
cat > "$IN" <<EOF
Read src/app.sh and docs/guide.md.
Write your notes to $TEST_TEMP_DIR/state/artifacts/notes/plan.md
The key is in config/server.pem and .zbuild/secrets/token.txt, also vault/db.txt
EOF
( export ZBUILD_REPO_ROOT="$R" _TPL_SOURCE_FILE="$TPL"; apply_scope_redaction "$IN" "$OUT" "$M" "" 0 >/dev/null 2>&1 )
_o="$(cat "$OUT" 2>/dev/null)"
assert_contains "[P3] a repository path outside the old scope is kept" "$_o" "docs/guide.md"
assert_contains "[P3] the stage's own artifacts path is kept" "$_o" "$TEST_TEMP_DIR/state/artifacts/notes/plan.md"
assert_eq "[P3] no out-of-scope marker" "0" "$(grep -c 'out-of-scope-context' <<< "$_o" || true)"
for _p in config/server.pem .zbuild/secrets/token.txt vault/db.txt; do
    assert_eq "[P3] a private path is taken out: $_p" "0" "$(grep -cF -- "$_p" <<< "$_o" || true)"
done

print_test_section "P4: reading and editing a private path are denied"
# shellcheck source=../../core/router/permissions.sh
source "$REPO_ROOT/core/router/permissions.sh"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"; mkdir -p "$ZBUILD_STAGE_SCRATCH"
( export ZBUILD_REPO_ROOT="$R" _TPL_SOURCE_FILE="$TPL"; _zbuild_build_permissions_settings >/dev/null 2>&1 )
_deny="$(jq -r '.permissions.deny[]' "$ZBUILD_STAGE_SCRATCH/claude-settings.json" 2>/dev/null)"
assert_contains "[P4] reading a key file anywhere is denied" "$_deny" "Read(/$R/**/*.pem)"
assert_contains "[P4] editing it is denied" "$_deny" "Edit(/$R/**/*.pem)"
assert_contains "[P4] reading a private folder is denied" "$_deny" "Read(/$R/.zbuild/secrets/**)"
assert_contains "[P4] a template location is denied" "$_deny" "Read(/$R/vault/**)"
assert_contains "[P4] a .zbuild/ location is denied" "$_deny" "Read(/$R/internal/payroll/**)"

print_test_section "P6: safe under set -e with no .zbuild/private-paths"
_r6="$(bash -c 'set -euo pipefail; source "$1/scripts/lib/private-paths.sh"; private_paths_list "$2" >/dev/null; echo ok' _ "$REPO_ROOT" "$TEST_TEMP_DIR/no-zbuild" 2>&1)"
assert_eq "[P6] a repository without .zbuild/private-paths does not stop a set -e caller" "ok" "$_r6"

print_test_section "P5: the router takes private paths out of every prompt"
# Before #2379 a run with no scope manifest skipped redaction altogether.
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" >/dev/null 2>&1
printf 'Read config/server.pem and src/app.sh\n' > "$IN"
( unset ZBUILD_SCOPE_MANIFEST ZBUILD_PLUGIN_DIR; export ZBUILD_REPO_ROOT="$R"
  _route_redact_prompt "$IN" "$OUT" 0 "" >/dev/null 2>&1 )
assert_eq "[P5] no scope manifest: a private path is still taken out" "0" "$(grep -c 'server.pem' "$OUT" 2>/dev/null || true)"
assert_contains "[P5] ...and other paths are kept" "$(cat "$OUT" 2>/dev/null)" "src/app.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
