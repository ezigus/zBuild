#!/usr/bin/env bash
# tests/unit/persona-agent-delivery-test.sh — every stage that calls a model
# runs as a persona, and the provider decides how the persona reaches the model
# (ADR-051, amended 2026-10-12).
#
# The persona is found the way ADR-051 §4/§5 says — the stage's pin, then the
# template default, then generic; the target repository's
# .zbuild/plugins/persona/<id> before the install's — and delivered by the
# provider that calls the model: for Anthropic, `--agents <json> --agent <id>`.
# A provider that cannot take an agent gets the persona as its own first section
# of the prompt. No stage frames a persona itself.
#
#   PA1 [change]: the Anthropic provider turns a persona into --agents/--agent
#   PA2 [change]: a dispatched stage's model call carries --agent <its persona>,
#                 with that persona's perspective as the agent's prompt; the
#                 perspective is not in the prompt text
#   PA3 [change]: the stage's template pin picks the persona
#   PA4 [guard] : the target repository's own persona wins over the install's;
#                 with no persona of that id anywhere, generic is used
#   PA5 [change]: a provider that cannot take an agent gets the persona as the
#                 prompt's first section, "## Who you are"
#   PA6 [guard] : a model call made outside any stage carries no agent
#   PA7 [change]: the model loop carries the agent on every call
#   PA8 [change]: a map element runs as the persona the template names for it,
#                 never one guessed from its name
#   PA9 [change]: the shipped templates pin the personas the stages used to
#                 choose in their own code (plan, design, build)
#   PA10 [change]: the persona given to the provider has been through the
#                 scope redaction like every other model-bound text, before the
#                 prompt's own (its redaction.applied stays last before the call);
#                 with a scope manifest but no redaction to run, it is not sent
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"
    else assert_pass "$1"; fi
}

print_test_header "personas reach the model through the provider (ADR-051)"
setup_test_env "persona-agent-delivery"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="persona-agent-$$"
: > "$ZBUILD_EVENTS_JSONL"
unset ZBUILD_SCOPE_MANIFEST ZBUILD_STAGE_INPUTS 2>/dev/null || true

# A mock claude that records its arguments and the prompt it was given.
CAP="$TEST_TEMP_DIR/cap"; mkdir -p "$CAP"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
n=\$(ls "$CAP" | /usr/bin/grep -c '^args-' || true); n=\$((n + 1))
printf '%s\n' "\$@" > "$CAP/args-\$n"
cat > "$CAP/prompt-\$n"
printf '%s\n' '{"type":"result","result":"done\nLOOP_COMPLETE","usage":{"input_tokens":1,"output_tokens":1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
_last() { local n; n="$(ls "$CAP" | /usr/bin/grep -c '^args-' || true)"; cat "$CAP/$1-$n" 2>/dev/null; }
_reset_cap() { rm -f "$CAP"/args-* "$CAP"/prompt-*; }
# The value that follows --agent in captured args, exactly (assert_contains
# would match each line of a two-line needle on its own).
_agent_of() { awk 'p { print; exit } $0 == "--agent" { p = 1 }' <<< "$1"; }

# A target repository with its own persona, and a dispatched agent stage.
TGT="$TEST_TEMP_DIR/target"; mkdir -p "$TGT/.zbuild/plugins/persona/architect"
cat > "$TGT/.zbuild/plugins/persona/architect/manifest.yaml" <<'EOF'
id: architect
name: Architect (this repository)
kind: persona
version: 0.1.0
summary: This repository's architect.
persona:
  role: a software architect
  perspective: "REPO-ARCHITECT-PERSPECTIVE: keep this repository's boundaries."
EOF
export ZBUILD_REPO_ROOT="$TGT"
PD="$TEST_TEMP_DIR/plugins/agent/pa-agent"; mkdir -p "$PD"
cat > "$PD/manifest.yaml" <<'EOF'
id: pa-agent
name: pa-agent
kind: agent
version: 0.1.0
hooks:
  run: x_run
outputs:
  - id: pa_agent_result
    path: ${artifact_dir}/pa-agent-result.json
    type: json
    required: true
    primary: true
EOF
STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE/artifacts"
printf '{"schema_version":1}\n' > "$STATE/pipeline-state.json"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
PROMPT="$(stage_prompt_compose_parts "$(printf '## What you own\nOWN\n## What you judge against\nJUDGE\n## What you must not do\nLIMITS\n')")"

# ─── PA1 ─────────────────────────────────────────────────────────────────────
print_test_section "PA1: the Anthropic provider's agent arguments"
_route_provider_load anthropic
mapfile -t _pa1 < <(provider_anthropic_persona_args "developer" "A developer." "PERSPECTIVE-TEXT" 2>/dev/null)
assert_eq "[PA1] --agents, its JSON, --agent, the name" "--agents|--agent|developer" \
    "${_pa1[0]:-}|${_pa1[2]:-}|${_pa1[3]:-}"
assert_eq "[PA1] the agent's prompt is the perspective" "PERSPECTIVE-TEXT" \
    "$(jq -r '.developer.prompt // empty' <<< "${_pa1[1]:-}" 2>/dev/null)"
assert_eq "[PA1] …with its description" "A developer." \
    "$(jq -r '.developer.description // empty' <<< "${_pa1[1]:-}" 2>/dev/null)"

# ─── PA2 / PA4: a stage call, its persona from the repository ────────────────
print_test_section "PA2/PA4: a dispatched stage runs as its persona"
_reset_cap
( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=pa-agent \
         ZBUILD_PA_AGENT_PERSONA=architect
  route_to_model T2 "$PROMPT" >/dev/null 2>&1 )
_args="$(_last args)"
assert_eq "[PA2] the call names its agent" "architect" "$(_agent_of "$_args")"
_json="$(awk 'p { print; exit } $0 == "--agents" { p = 1 }' <<< "$_args")"
assert_contains "[PA4] the repository's own persona is the one used" \
    "$(jq -r '.architect.prompt // empty' <<< "$_json" 2>/dev/null)" "REPO-ARCHITECT-PERSPECTIVE"
assert_not_contains "[PA2] the perspective is not in the prompt text" "$(_last prompt)" "REPO-ARCHITECT-PERSPECTIVE"
_reset_cap
( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=pa-agent \
         ZBUILD_PA_AGENT_PERSONA=no-such-persona
  route_to_model T2 "$PROMPT" >/dev/null 2>&1 )
assert_eq "[PA4] no persona of that id anywhere → generic" "generic" "$(_agent_of "$(_last args)")"

# ─── PA3: the template pin ───────────────────────────────────────────────────
print_test_section "PA3: the stage's template pin picks the persona"
cat > "$TEST_TEMP_DIR/tpl.yaml" <<'EOF'
id: pa
flow:
  - pa-agent
pa-agent:
  persona: developer
EOF
_reset_cap
( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=pa-agent
  _TPL_SOURCE_FILE="$TEST_TEMP_DIR/tpl.yaml"
  route_to_model T2 "$PROMPT" >/dev/null 2>&1 )
assert_eq "[PA3] the pinned persona is the agent" "developer" "$(_agent_of "$(_last args)")"

# ─── PA5: a provider that cannot take an agent ───────────────────────────────
print_test_section "PA5: no agent support → the persona is the prompt's first section"
_reset_cap
( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=pa-agent \
         ZBUILD_PA_AGENT_PERSONA=architect
  unset -f provider_anthropic_persona_args
  provider_anthropic_persona_args() { return 1; }
  route_to_model T2 "$PROMPT" >/dev/null 2>&1 )
_p5="$(_last prompt)"
assert_not_contains "[PA5] no --agent is passed" "$(_last args)" "--agent"
assert_eq "[PA5] the prompt opens with Who you are" "## Who you are" "${_p5%%$'\n'*}"
assert_contains "[PA5] …holding the perspective" "$_p5" "REPO-ARCHITECT-PERSPECTIVE"
assert_contains "[PA5] …and the contract follows it" "$_p5" "## From the repo"

# ─── PA6: outside any stage ──────────────────────────────────────────────────
print_test_section "PA6: a call outside any stage"
_reset_cap
( unset ZBUILD_PLUGIN_DIR; route_to_model T2 "a plain task" >/dev/null 2>&1 )
assert_not_contains "[PA6] no agent outside a stage" "$(_last args)" "--agent"

# ─── PA7: the loop ───────────────────────────────────────────────────────────
print_test_section "PA7: every call of the loop runs as the persona"
_reset_cap
printf '%s\n' "$PROMPT" > "$TEST_TEMP_DIR/loop-prompt.txt"
( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=pa-agent \
         ZBUILD_PA_AGENT_PERSONA=architect
  route_to_model_loop T2 "$TEST_TEMP_DIR/loop-prompt.txt" "$TGT" >/dev/null 2>&1 )
assert_eq "[PA7] the loop's call names the agent" "architect" "$(_agent_of "$(cat "$CAP"/args-1 2>/dev/null)")"

# ─── PA8: a map element runs as the persona the template names for it ────────
print_test_section "PA8: a map element's declared persona"
mkdir -p "$TGT/.zbuild/plugins/persona/security"
cat > "$TGT/.zbuild/plugins/persona/security/manifest.yaml" <<'EOF'
id: security
name: Security (this repository)
kind: persona
version: 0.1.0
summary: This repository's security reviewer.
persona:
  role: a security engineer
  perspective: "REPO-SECURITY-PERSPECTIVE: look for the hostile input."
EOF
cat > "$TEST_TEMP_DIR/tpl-map.yaml" <<'EOF'
id: pa-map
flow:
  - pa-agent
pa-agent:
  type: map
  over: lenses
  elements:
    - id: sec
      persona: security
    - id: architect
  roles: [pa_agent]
EOF
_pa8() {
    _reset_cap
    ( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=pa-agent \
             ZBUILD_MAP_ELEMENT="$1"
      _TPL_SOURCE_FILE="$TEST_TEMP_DIR/tpl-map.yaml"
      route_to_model T2 "$PROMPT" >/dev/null 2>&1 )
    _agent_of "$(_last args)"
}
assert_eq "[PA8] an element runs as the persona it names" "security" "$(_pa8 sec)"
assert_eq "[PA8] an element named like a persona but naming none runs as generic" "generic" "$(_pa8 architect)"

# ─── PA9: the templates pin what the stages used to hardcode ─────────────────
print_test_section "PA9: the shipped templates pin each stage's persona"
for _tpl in simple deployed; do
    for _pair in plan:product-owner design:architect build:developer; do
        _got="$( _TPL_SOURCE_FILE="$REPO_ROOT/config/templates/$_tpl.yaml" template_stage_router_persona "${_pair%%:*}" 2>/dev/null )"
        assert_eq "[PA9] $_tpl.yaml pins ${_pair%%:*} to ${_pair#*:}" "${_pair#*:}" "$_got"
    done
done

# ─── PA10: the agent's prompt is redacted ────────────────────────────────────
print_test_section "PA10: the persona passes through the scope redaction"
_reset_cap
printf 'scope\n' > "$TEST_TEMP_DIR/scope-manifest.txt"
: > "$TEST_TEMP_DIR/redaction-order"
( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=pa-agent \
         ZBUILD_PA_AGENT_PERSONA=architect ZBUILD_SCOPE_MANIFEST="$TEST_TEMP_DIR/scope-manifest.txt"
  apply_scope_redaction() {
      sed 's/REPO-ARCHITECT-PERSPECTIVE/[REDACTED]/g' "$1" > "$2"
      { head -c 20 "$1" | tr '\n' ' '; printf '\n'; } >> "$TEST_TEMP_DIR/redaction-order"
  }
  route_to_model T2 "$PROMPT" >/dev/null 2>&1 )
_json10="$(awk 'p { print; exit } $0 == "--agents" { p = 1 }' <<< "$(_last args)")"
_p10="$(jq -r '.architect.prompt // empty' <<< "$_json10" 2>/dev/null)"
assert_contains "[PA10] the agent's prompt is the redacted text" "$_p10" "[REDACTED]"
assert_not_contains "[PA10] the unredacted perspective is not sent" "$_p10" "REPO-ARCHITECT-PERSPECTIVE"
assert_contains "[PA10] the prompt's own redaction runs last" \
    "$(tail -n1 "$TEST_TEMP_DIR/redaction-order")" "## From the repo"

_reset_cap
( export ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=pa-agent \
         ZBUILD_PA_AGENT_PERSONA=architect ZBUILD_SCOPE_MANIFEST="$TEST_TEMP_DIR/scope-manifest.txt"
  _route_persona_prepare
  unset -f apply_scope_redaction
  _route_persona_redact "$ZBUILD_SCOPE_MANIFEST" "" 0
  printf '%s\n' "${_ROUTE_PERSONA_ARGS[@]+"${_ROUTE_PERSONA_ARGS[@]}"}" > "$CAP/args-1" )
assert_not_contains "[PA10] a persona that cannot be redacted is not sent" "$(cat "$CAP/args-1" 2>/dev/null)" "--agent"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
