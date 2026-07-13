#!/usr/bin/env bash
# Tests: route_to_model_cli — standalone CLI model calls redact BY CONSTRUCTION.
# Verifies the DOC-D2 (#1440) fix: instead of --skip-precondition + a manual
# redactor, route_to_model_cli provisions an EPHEMERAL run context (temp events
# log + concrete-dirs scope manifest) so route_to_model's normal
# _route_ensure_redaction/_route_redact_prompt path does REAL redaction.
#
# Assertions:
#   T1: with NO ZBUILD_RUN_ID, an out-of-scope absolute path (/etc/passwd) in the
#       prompt is wrapped in <out-of-scope-context> in the text sent to claude,
#       while an in-repo path (scripts/lib/foo.sh) passes through unwrapped.
#   T2: the ephemeral context emits redaction.applied with a REAL scope_hash
#       (NOT router-passthrough, NOT router.precondition.skipped).
#   T3: when already in a run (ZBUILD_RUN_ID + ZBUILD_EVENTS_JSONL set),
#       route_to_model_cli is a pass-through that leaves those vars untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "route_to_model_cli — CLI redaction-by-construction (#1440)"
setup_test_env "route-cli-redaction"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# ─── Recording claude mock ───────────────────────────────────────────────────
# Records the full argv (NUL-delimited) so the -p <prompt> value can be inspected.
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\0' "\$a"; done > "$TEST_TEMP_DIR/last_args"
echo "# OK response"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Return the recorded prompt (the token after -p) as a single string.
_recorded_prompt() {
    awk 'BEGIN{RS="\0"} prev=="-p"{print; exit} {prev=$0}' "$TEST_TEMP_DIR/last_args" 2>/dev/null || true
}

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# ─── T1: standalone call redacts out-of-scope paths, keeps in-repo paths ─────
# NO run context set → route_to_model_cli must provision an ephemeral one.
unset ZBUILD_RUN_ID ZBUILD_EVENTS_JSONL ZBUILD_SCOPE_MANIFEST ZBUILD_CURRENT_STAGE
# Point events at a temp file so the pre-existing-context branch is NOT taken and
# any stub-path emits land somewhere harmless if the code changes.
_prompt=$'document this: leaked /etc/passwd and ok scripts/lib/doc-generate.sh'

set +e
route_to_model_cli "T2" "$_prompt" >/dev/null 2>&1
t1_rc=$?
set -e
assert_eq "T1: route_to_model_cli returns rc=0 standalone" "0" "$t1_rc"

sent="$(_recorded_prompt)"
assert_contains "T1: out-of-scope /etc/passwd wrapped before reaching model" \
    "$sent" "<out-of-scope-context>/etc/passwd</out-of-scope-context>"
assert_contains "T1: in-repo path survives to the model unwrapped" \
    "$sent" "scripts/lib/doc-generate.sh"
inrepo_wrapped=0
grep -qF "<out-of-scope-context>scripts/lib/doc-generate.sh" <<< "$sent" && inrepo_wrapped=1
assert_eq "T1: in-repo path is NOT wrapped as out-of-scope" "0" "$inrepo_wrapped"

# ─── T2: helper provisions manifest+events context, NOT --skip-precondition ──
# claude runs with a scrubbed ZBUILD_* env by design (_zbuild_make_fresh_shell),
# so we cannot observe the manifest from the mock. Instead stub route_to_model
# (saving/restoring the real one) and capture exactly what route_to_model_cli
# hands it: an ephemeral ZBUILD_SCOPE_MANIFEST with concrete repo dirs (NOT
# universal `+ ./`), an ephemeral ZBUILD_EVENTS_JSONL, a synthetic
# ZBUILD_RUN_ID, and NO --skip-precondition flag (redaction stays by-construction).
_REAL_RTM="$(declare -f route_to_model)"     # save to restore before T3
_cap="$TEST_TEMP_DIR/rtm_capture"
route_to_model() {
    {
        printf 'RUN_ID=%s\n' "${ZBUILD_RUN_ID:-}"
        printf 'EVENTS=%s\n' "${ZBUILD_EVENTS_JSONL:-}"
        printf 'MANIFEST=%s\n' "${ZBUILD_SCOPE_MANIFEST:-}"
        [[ -f "${ZBUILD_SCOPE_MANIFEST:-/nope}" ]] && { printf 'MANIFEST_BODY<<\n'; cat "$ZBUILD_SCOPE_MANIFEST"; printf '>>\n'; }
        printf 'ARGS='; printf '%s ' "$@"; printf '\n'
    } > "$_cap"
    return 0
}
unset ZBUILD_RUN_ID ZBUILD_EVENTS_JSONL ZBUILD_SCOPE_MANIFEST
route_to_model_cli "T2" "prompt body" >/dev/null 2>&1
eval "$_REAL_RTM"   # restore the real route_to_model for T3

cap="$(cat "$_cap" 2>/dev/null || true)"
assert_contains "T2: helper set an ephemeral ZBUILD_RUN_ID (cli-*)" "$cap" "RUN_ID=cli-"
assert_contains "T2: helper set an ephemeral ZBUILD_EVENTS_JSONL" "$cap" "zb-cli-events"
assert_contains "T2: helper set an ephemeral ZBUILD_SCOPE_MANIFEST" "$cap" "zb-cli-scope"
assert_contains "T2: manifest allows concrete repo dirs (scripts/)" "$cap" "+ scripts/"
uses_universal=0
grep -qF "+ ./" <<< "$cap" && uses_universal=1
assert_eq "T2: manifest does NOT use universal-allow '+ ./'" "0" "$uses_universal"
passes_skip=0
grep -qF -- "--skip-precondition" <<< "$cap" && passes_skip=1
assert_eq "T2: route_to_model_cli does NOT pass --skip-precondition" "0" "$passes_skip"

# ─── T3: in-run pass-through leaves run context vars untouched ───────────────
_evlog="$TEST_TEMP_DIR/inrun-events.jsonl"
: > "$_evlog"
export ZBUILD_RUN_ID="existing-run-123"
export ZBUILD_EVENTS_JSONL="$_evlog"
# Pre-redact marker: with a run context + no manifest, route_to_model uses the
# passthrough stub (emits redaction.applied) and does NOT alter our env vars.
set +e
route_to_model_cli "T2" "in-run ping" >/dev/null 2>&1
t3_rc=$?
set -e
assert_eq "T3: in-run pass-through returns rc=0" "0" "$t3_rc"
assert_eq "T3: ZBUILD_RUN_ID preserved (pass-through, not overwritten)" \
    "existing-run-123" "${ZBUILD_RUN_ID:-}"
assert_eq "T3: ZBUILD_EVENTS_JSONL preserved" "$_evlog" "${ZBUILD_EVENTS_JSONL:-}"
unset ZBUILD_RUN_ID ZBUILD_EVENTS_JSONL

print_test_results
