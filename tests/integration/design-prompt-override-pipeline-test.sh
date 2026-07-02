#!/usr/bin/env bash
# Integration: the REAL design plugin loads a per-repo prompt override and the
# override survives the REAL redaction chokepoint (ADR-032/ADR-004, #854). Runs
# design_run with real apply_scope_redaction; only the model call is mocked.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "integration: design per-repo override survives real redaction (#854)"
setup_test_env "design-prompt-override-pipeline-854"

# Event bus so the router's redaction (below) can emit redaction.applied.
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="design-ov-pipeline-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# ADR-043: redaction is owned by route_to_model_loop (via the router's shared
# _route_redact_prompt, reading ZBUILD_SCOPE_MANIFEST). We mock ONLY the model
# call, but the mock still runs that REAL redaction on the assembled prompt and
# writes design-prompt.redacted.txt — so this test keeps proving the override
# survives real redaction into the ROUTED prompt (the plugin no longer redacts).
route_to_model_loop() {
    local _prompt_file="$2"
    local _redacted; _redacted="$(dirname "$_prompt_file")/design-prompt.redacted.txt"
    _route_redact_prompt "$_prompt_file" "$_redacted" 0 "" >/dev/null 2>&1 \
        || cp "$_prompt_file" "$_redacted"
    [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" ]] && {
        mkdir -p "$(dirname "$MOCK_DESIGN_WRITE_PATH")"
        printf '# Design\n\n## Decision\nd\n\n```scope\nfoo.sh\n```\n\n```acceptance\nSPEC: placeholder test\nTESTFILES:\ntests/unit/placeholder-test.sh\n```\n' > "$MOCK_DESIGN_WRITE_PATH"
    }
    _ROUTE_LOOP_FINAL_OUTPUT="ok"; _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
# Atomic (temp+mv) so `cat design.md | atomic_write design.md` (plugin.sh:290)
# does not truncate the file before cat reads it.
atomic_write() { local dest="$1" tmp; tmp="$(mktemp)"; cat - > "$tmp"; mv "$tmp" "$dest"; }
_route_loop_close_final_banner() { return 0; }

_mk_repo() {
    local fix="$1"
    mkdir -p "$fix"
    git -C "$fix" init --quiet >/dev/null 2>&1
    git -C "$fix" config user.email 'test@example.com' >/dev/null
    git -C "$fix" config user.name 'test' >/dev/null
}

_run_design() {
    local fix="$1"
    local artifact_dir="$fix/state/artifacts"; mkdir -p "$artifact_dir"
    local scope_manifest="$fix/state/scope-manifest.md"; printf 'scope: all\n' > "$scope_manifest"
    # ADR-043: the runner exports this per-stage; the mocked loop's redaction
    # (via _route_redact_prompt) reads it. Export here to mirror the runner.
    export ZBUILD_SCOPE_MANIFEST="$scope_manifest"
    local plan_json="$artifact_dir/plan.json"
    cat > "$plan_json" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
    local output_md="$artifact_dir/design.md"
    ZBUILD_REPO_ROOT="$fix" MOCK_DESIGN_WRITE_PATH="$output_md" \
        _design_stage_run_inner "$scope_manifest" "$plan_json" "$output_md" "$artifact_dir" >/dev/null 2>&1
    local rc=$?
    printf '%s %d' "$artifact_dir" "$rc"
}

# ── E1: override reaches the REDACTED prompt end-to-end (real redaction) ─────
FIX="$TEST_TEMP_DIR/target"
_mk_repo "$FIX"
mkdir -p "$FIX/.zbuild/prompts"
printf '# overlay\nENUM_RULE_E2E: scope every roster-registering test\n' \
    > "$FIX/.zbuild/prompts/design-overrides.md"
read -r ART RC <<<"$(_run_design "$FIX")"
REDACTED="$ART/design-prompt.redacted.txt"

assert_eq "E1: design inner returns 0 with override present" "0" "$RC"
assert_file_exists "E1: redacted prompt written" "$REDACTED"
assert_contains "E1: override survives REAL redaction into routed prompt" \
    "$(cat "$REDACTED")" "ENUM_RULE_E2E"

# E2: delimiter present in the redacted (routed) prompt.
assert_contains "E2: override delimiter in redacted prompt" \
    "$(cat "$REDACTED")" "## Project-specific guidance (operator override)"

# E3: ordering invariant holds in the redacted prompt (override after contract).
hdr="$(grep -n '## Project-specific guidance (operator override)' "$REDACTED" | head -1 | cut -d: -f1)"
loop="$(grep -n 'LOOP_COMPLETE' "$REDACTED" | head -1 | cut -d: -f1)"
if [[ -n "$hdr" && -n "$loop" && "$hdr" -gt "$loop" ]]; then
    assert_pass "E3: override section after core contract in redacted prompt"
else
    assert_fail "E3: ordering invariant violated" "hdr=$hdr loop=$loop"
fi

# E4: design.md produced with a valid scope block — contract intact.
assert_file_exists "E4: design.md produced" "$ART/design.md"
if grep -q '^```scope' "$ART/design.md"; then
    assert_pass "E4: design.md has a scope block (contract intact)"
else
    assert_fail "E4: design.md missing scope block"
fi

# ── E5: no override file → clean run, no delimiter noise ─────────────────────
FIX2="$TEST_TEMP_DIR/target_noov"
_mk_repo "$FIX2"
read -r ART2 RC2 <<<"$(_run_design "$FIX2")"
REDACTED2="$ART2/design-prompt.redacted.txt"
assert_eq "E5: design inner returns 0 without override" "0" "$RC2"
if grep -q '## Project-specific guidance (operator override)' "$REDACTED2"; then
    assert_fail "E5: must not emit override delimiter when none present"
else
    assert_pass "E5: clean prompt, no override delimiter when absent"
fi
assert_contains "E5b: contract intact without override" "$(cat "$REDACTED2")" "LOOP_COMPLETE"

# ── E6: symlink-out override is refused (no leak), pipeline still completes ──
FIX3="$TEST_TEMP_DIR/target_symlink"
_mk_repo "$FIX3"
mkdir -p "$FIX3/.zbuild/prompts"
ln -s /etc/passwd "$FIX3/.zbuild/prompts/design-overrides.md"
read -r ART3 RC3 <<<"$(_run_design "$FIX3")"
REDACTED3="$ART3/design-prompt.redacted.txt"
assert_eq "E6: design inner returns 0 with symlink-out override" "0" "$RC3"
if grep -q 'root:' "$REDACTED3"; then
    assert_fail "E6: symlink-out override leaked /etc/passwd into prompt"
else
    assert_pass "E6: symlink-out override refused, no leak"
fi

# ── E7: redaction is a PATH-SCOPE gate, not a secret scrubber (documents the
# real ADR-004 contract — non-path override prose passes through verbatim). ──
FIX4="$TEST_TEMP_DIR/target_prose"
_mk_repo "$FIX4"
mkdir -p "$FIX4/.zbuild/prompts"
printf '# overlay\nNONPATH_PROSE_E7 a plain sentence with no slash tokens\n' \
    > "$FIX4/.zbuild/prompts/design-overrides.md"
read -r ART4 RC4 <<<"$(_run_design "$FIX4")"
REDACTED4="$ART4/design-prompt.redacted.txt"
assert_eq "E7: design inner returns 0" "0" "$RC4"
assert_contains "E7: non-path override prose survives redaction (path-scope gate)" \
    "$(cat "$REDACTED4")" "NONPATH_PROSE_E7"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
