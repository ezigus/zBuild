#!/usr/bin/env bash
# tests/lib/claim-runner-fixture.sh — the real runner on a one-stage template,
# for the cross-machine claim tests (ADR-005 §1). Sourced after test-helpers.sh
# and setup_test_env.
#
#   claim_fixture_setup                 the repo, the plugins root, the stage
#   claim_fixture_real_coordinator      the github-labels plugin, on the local-fs store
#   claim_fixture_stub_coordinator <reply> [claim body]
#                                       a stub coordinator; every hook call is a line
#                                       ("claim <issue>", "release <issue>") in $CLAIM_CALLS
#   claim_fixture_stage <body>          the outcome stage: <body>, then a pass result
#   claim_fixture_run <case> <args...>  the runner in the foreground → $CLAIM_RC,
#                                       $TEST_TEMP_DIR/<case>.out, claim_fixture_events <case>
#   claim_fixture_start <case> <args...> the same in the background → $CLAIM_PID
#   claim_fixture_wait_for <file>       wait (bounded) for a marker a process writes
#   claim_fixture_wait_gone <pid>       wait (bounded) for a process to end, then reap it

claim_fixture_setup() {
    RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
    PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
    export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
    export ZBUILD_CONTRACT_VALIDATOR=warn ZBUILD_CYCLES_ENABLED=0 ZBUILD_SCOPE_OVERRIDE=1
    export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
    export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
    export ZBUILD_NO_WORKTREE=1 ZBUILD_NO_ISSUE_LOCK=1
    export ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/claim-store"
    CLAIM_CALLS="$TEST_TEMP_DIR/claim-calls"; : > "$CLAIM_CALLS"
    mkdir -p "$HOME/.zbuild" "$ZBUILD_CLAIM_STORE"
    printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
    CLAIM_REPO="$(setup_git_temp_repo claim-runner)"
    mkdir -p "$CLAIM_REPO/.zbuild/templates"
    cat > "$CLAIM_REPO/.zbuild/templates/claim-test.yaml" <<'EOF'
id: claim-test
extends: simple
flow:
  - outcome
always_run: []
outcome:
  gate: auto
EOF
    (cd "$CLAIM_REPO" && git add .zbuild && git commit -qm "claim-test template") >/dev/null 2>&1
    mock_plugin_factory outcome agent 0 >/dev/null
}

claim_fixture_real_coordinator() {
    rm -rf "$PLUGINS_ROOT/claim-coordinator"; mkdir -p "$PLUGINS_ROOT/claim-coordinator"
    cp -R "$REPO_ROOT/plugins/claim-coordinator/github-labels" "$PLUGINS_ROOT/claim-coordinator/"
    rm -rf "$PLUGINS_ROOT/claim-coordinator/github-labels/tests"
    export ZBUILD_CLAIM_BACKEND=local-fs
    unset NO_GITHUB
}

claim_fixture_stub_coordinator() {
    local dir="$PLUGINS_ROOT/claim-coordinator/stub"
    rm -rf "$PLUGINS_ROOT/claim-coordinator"; mkdir -p "$dir"
    printf '%s\n' "$1" > "$dir/reply"
    cat > "$dir/manifest.yaml" <<'EOF'
id: claim-coordinator-stub
name: Stub claim coordinator
kind: claim-coordinator
version: 0.1.0
hooks:
  claim: stub_claim
  release: stub_release
  heartbeat: stub_heartbeat
  list_claims: stub_list
provides:
  role: claim-coordinator
  alias: stub
EOF
    cat > "$dir/plugin.sh" <<EOF
stub_claim() { printf 'claim %s\n' "\$1" >> "$CLAIM_CALLS"; cat "$dir/reply"; ${2:-:}; return 0; }
stub_release() { printf 'release %s\n' "\$1" >> "$CLAIM_CALLS"; return 0; }
stub_heartbeat() { return 0; }
stub_list() { printf '[]\n'; }
EOF
    : > "$CLAIM_CALLS"
}

claim_fixture_stage() {
    cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() {
    $1
    local _art; _art="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\$2")/artifacts}"; mkdir -p "\$_art"
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    stage_result_write "\$_art/outcome-result.json" "pass" "claim fixture"
    return 0
}
PLUG
}

_claim_fixture_prep() {
    local d="$TEST_TEMP_DIR/case-$1"
    rm -rf "$d"; mkdir -p "$d/state" "$d/events"
    export ZBUILD_STATE_DIR="$d/state" ZBUILD_EVENTS_DIR="$d/events" ZBUILD_EVENTS_JSONL="$d/events/events.jsonl"
}
claim_fixture_events() { printf '%s' "$TEST_TEMP_DIR/case-$1/events/events.jsonl"; }

claim_fixture_run() {
    local c="$1"; shift
    _claim_fixture_prep "$c"
    CLAIM_RC=0
    ( cd "$CLAIM_REPO" && exec bash "$RUNNER" --no-resume --template claim-test "$@" ) \
        > "$TEST_TEMP_DIR/$c.out" 2>&1 || CLAIM_RC=$?
}

claim_fixture_start() {
    local c="$1"; shift
    _claim_fixture_prep "$c"
    ( cd "$CLAIM_REPO" && exec bash "$RUNNER" --no-resume --template claim-test "$@" ) \
        > "$TEST_TEMP_DIR/$c.out" 2>&1 &
    CLAIM_PID=$!
}

claim_fixture_wait_for() {
    local _
    for _ in $(seq 1 600); do [[ -e "$1" ]] && return 0; sleep 0.05; done
    return 1
}

claim_fixture_wait_gone() {
    local _ rc=0
    for _ in $(seq 1 600); do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done
    kill -KILL "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || rc=$?
    CLAIM_RC=$rc
}
