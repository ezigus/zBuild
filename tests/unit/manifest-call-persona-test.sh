#!/usr/bin/env bash
# tests/unit/manifest-call-persona-test.sh — each model call runs as the persona
# its stage's manifest names for it (ADR-051 §2, §5, amended 2026-11-14).
#
# Why: the persona was resolved per stage, so a judging call inside a stage ran
# as the stage's own persona — design's coverage check as the architect who
# wrote the design, test-author's check of its assertions as the test strategist
# who wrote them. A judge should not see the work as its writer does. The
# manifest already names every model call (`calls:`, ADR-017 §12); it names
# each call's persona beside it (`personas:`).
#
# MP1 [change] manifest_call_persona_v gives the persona the manifest names for
#              a call, and nothing for a call it names none for
# MP2 [change] validate_manifest refuses a `personas:` entry for a call the
#              manifest does not list, and an entry that is not a persona id
# MP3 [change] resolve_persona: the call's persona from the manifest
#              (ZBUILD_ROUTE_CALL, `main` when unset); a template's stage pin
#              is the `main` call's only; a call with neither runs as generic
# MP4 [change] two calls of one stage, in one shell, each reach the model as
#              their own persona (the router's persona is worked out per call)
# MP5 [change] the startup preflight refuses a persona a manifest names that
#              exists nowhere
# MP6 [change] the shipped manifests name each call's persona; the shipped
#              templates pin no stage's persona (a review lens's element still
#              names its own)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "each model call runs as the persona its manifest names (ADR-051)"
setup_test_env "manifest-call-persona"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="mcp-$$"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
unset ZBUILD_SCOPE_MANIFEST ZBUILD_STAGE_INPUTS ZBUILD_ROUTE_CALL 2>/dev/null || true

# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
# shellcheck source=../../scripts/lib/persona-resolve.sh
source "$REPO_ROOT/scripts/lib/persona-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
set +e

TGT="$TEST_TEMP_DIR/target"; mkdir -p "$TGT"
export ZBUILD_REPO_ROOT="$TGT"

PD="$TEST_TEMP_DIR/plugins/agent/mp-agent"; mkdir -p "$PD"
cat > "$PD/manifest.yaml" <<'EOF'
id: mp-agent
name: mp-agent
kind: agent
version: 0.1.0
hooks:
  run: x_run
calls:
  main: [read-files, edit-files]
  check: [read-files]
  other: [read-files]
personas:
  main: developer
  check: quality-assurance
outputs:
  - id: mp_agent_result
    path: ${artifact_dir}/mp-agent-result.json
    type: json
    required: true
    primary: true
EOF

# ─── MP1 ─────────────────────────────────────────────────────────────────────
print_test_section "MP1: the manifest names a persona per call"
_v=""; manifest_call_persona_v _v "$PD/manifest.yaml" main
assert_eq "[MP1] main → developer" "developer" "$_v"
_v=""; manifest_call_persona_v _v "$PD/manifest.yaml" check
assert_eq "[MP1] check → quality-assurance" "quality-assurance" "$_v"
_v="x"; manifest_call_persona_v _v "$PD/manifest.yaml" other
assert_eq "[MP1] a call it names none for → empty" "" "$_v"

# ─── MP2 ─────────────────────────────────────────────────────────────────────
print_test_section "MP2: a personas: entry the manifest cannot hold is refused"
BAD="$TEST_TEMP_DIR/plugins/agent/mp-bad"; mkdir -p "$BAD"
awk '{ sub(/^id: mp-agent/, "id: mp-bad"); sub(/^name: mp-agent/, "name: mp-bad") }
     /^  check: quality-assurance/ { print "  coverage: quality-assurance"; print "  main: Not A Persona!"; next }
     { print }' "$PD/manifest.yaml" > "$BAD/manifest.yaml"
_rc=0; _out="$(validate_manifest "$BAD/manifest.yaml" 2>&1)" || _rc=$?
assert_eq "[MP2] the manifest is refused" "1" "$(( _rc != 0 ))"
assert_contains "[MP2] ...naming the call it does not list" "$_out" "personas.coverage"
assert_contains "[MP2] ...and the entry that is no persona id" "$_out" "Not A Persona!"
_rc=0; _out="$(_manifest_validate_personas "$PD/manifest.yaml" 2>&1)" || _rc=$?
assert_eq "[MP2] personas that name the manifest's own calls pass" "0" "$_rc"

# ─── MP3 ─────────────────────────────────────────────────────────────────────
print_test_section "MP3: resolve_persona reads the call's persona"
_rp() { ( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_CURRENT_STAGE=mp-agent; [[ -n "$1" ]] && export ZBUILD_ROUTE_CALL="$1"
          [[ -n "${2:-}" ]] && export _TPL_SOURCE_FILE="$2"
          d="$(resolve_persona mp-agent 2>/dev/null)"; basename "$d" ); }
assert_eq "[MP3] no call named → main's persona" "developer" "$(_rp "")"
assert_eq "[MP3] the check call → its own persona" "quality-assurance" "$(_rp check)"
assert_eq "[MP3] a call with no persona → generic" "generic" "$(_rp other)"
cat > "$TEST_TEMP_DIR/tpl.yaml" <<'EOF'
id: mp
flow:
  - mp-agent
mp-agent:
  persona: architect
EOF
assert_eq "[MP3] a template's stage pin is the main call's" "architect" "$(_rp main "$TEST_TEMP_DIR/tpl.yaml")"
assert_eq "[MP3] ...and not the check call's" "quality-assurance" "$(_rp check "$TEST_TEMP_DIR/tpl.yaml")"

# ─── MP4 ─────────────────────────────────────────────────────────────────────
print_test_section "MP4: each call reaches the model as its own persona"
CAP="$TEST_TEMP_DIR/cap"; mkdir -p "$CAP"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
n=\$(ls "$CAP" | /usr/bin/grep -c '^args-' || true); n=\$((n + 1))
printf '%s\n' "\$@" > "$CAP/args-\$n"
cat > /dev/null
printf '%s\n' '{"type":"result","result":"done","usage":{"input_tokens":1,"output_tokens":1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
_agent_of() { awk 'p { print; exit } $0 == "--agent" { p = 1 }' "$1" 2>/dev/null; }
STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE/artifacts"
printf '{"schema_version":1}\n' > "$STATE/pipeline-state.json"
PROMPT="$(stage_prompt_compose_parts "$(printf '## What you own\nOWN\n## What you judge against\nJUDGE\n## What you must not do\nLIMITS\n')")"
( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=mp-agent
  route_to_model T2 "$PROMPT" >/dev/null 2>&1
  ZBUILD_ROUTE_CALL=check route_to_model T2 "$PROMPT" >/dev/null 2>&1
  route_to_model T2 "$PROMPT" >/dev/null 2>&1 )
assert_eq "[MP4] the main call runs as developer" "developer" "$(_agent_of "$CAP/args-1")"
assert_eq "[MP4] the check call after it, in the same shell, as quality-assurance" "quality-assurance" "$(_agent_of "$CAP/args-2")"
assert_eq "[MP4] ...and the main call after that as developer again" "developer" "$(_agent_of "$CAP/args-3")"

# ─── MP5 ─────────────────────────────────────────────────────────────────────
print_test_section "MP5: a manifest's persona that exists nowhere refuses at startup"
cat > "$TEST_TEMP_DIR/tpl.yaml" <<'EOF'
id: mp
flow:
  - design
EOF
load_template "$TEST_TEMP_DIR/tpl.yaml" >/dev/null 2>&1
_pf() { ( unset ZBUILD_CONTRACT_VALIDATOR; _runner_validate_startup_preflight 2>&1; printf 'rc=%s' "$?" ); }
assert_contains "[MP5] every persona the shipped manifests name exists → clean" "$(_pf)" "rc=0"
mkdir -p "$TGT/.zbuild/plugins/agent/mp-typo"
sed -e 's/^id: mp-agent/id: mp-typo/' -e 's/^name: mp-agent/name: mp-typo/' \
    -e 's/^  check: quality-assurance/  check: no-such-judge/' "$PD/manifest.yaml" \
    > "$TGT/.zbuild/plugins/agent/mp-typo/manifest.yaml"
_out="$(_pf)"
assert_contains "[MP5] a missing one refuses the run" "$_out" "no-such-judge"
_lacks_rc0=1; [[ "$_out" == *"rc=0" ]] && _lacks_rc0=0
assert_eq "[MP5] ...with a non-zero rc" "1" "$_lacks_rc0"
sed -i.bak 's/^  check: no-such-judge/  check: Quality-Assurance/' "$TGT/.zbuild/plugins/agent/mp-typo/manifest.yaml"
rm -f "$TGT/.zbuild/plugins/agent/mp-typo/manifest.yaml.bak"
assert_contains "[MP5] ...and so does one that is no persona id at all" "$(_pf)" "Quality-Assurance"
rm -rf "$TGT/.zbuild/plugins/agent/mp-typo"

# ─── MP6 ─────────────────────────────────────────────────────────────────────
print_test_section "MP6: the shipped manifests name each call's persona"
for _row in intake:main:product-owner intake:check:quality-assurance \
            design:main:architect design:coverage:quality-assurance \
            test-author:main:test-strategist test-author:check:quality-assurance \
            build:main:developer issue-acceptance:main:product-owner monitor:main:sre; do
    IFS=: read -r _st _call _want <<< "$_row"
    _v=""; manifest_call_persona_v _v "$REPO_ROOT/plugins/agent/$_st/manifest.yaml" "$_call"
    assert_eq "[MP6] $_st's $_call call runs as $_want" "$_want" "$_v"
done
for _tpl in simple deployed; do
    for _st in intake design test-author build issue-acceptance monitor; do
        _got="$( _TPL_SOURCE_FILE="$REPO_ROOT/config/templates/$_tpl.yaml" template_stage_router_persona "$_st" 2>/dev/null )"
        assert_eq "[MP6] $_tpl.yaml pins no persona for $_st" "" "$_got"
    done
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
