#!/usr/bin/env bash
# Tests: the run-status comment end to end through the REAL runner (#2131,
# ADR-064). A mock-stage `simple` run with a recording `gh`: exactly one POST,
# PATCHes after it, the final header names the outcome, rows newest-first,
# and — the acceptance line that matters — a GitHub that fails every call
# leaves the runner's exit status exactly where it was.
#
# Scaffolding (the mock roster for `simple`) is lifted from
# cycle-rate-limit-aborts-run-test.sh with a passing build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "#2131: one live status comment per run, through the runner"
setup_test_env "run-status-comment-runner"

_ZB_REPO="$(zb_test_repo rsc-runner)"
_ZB_ISSUE="$(zb_test_issue)"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

_make_plugin() {
    local id="$1" role="${2:-}" rc="${3:-0}"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    local fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: agent
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
${role:+provides:
  role: $role}
EOF
    cat > "$dir/plugin.sh" <<PLUG
${fn}() { return $rc; }
PLUG
}

_make_design_plugin() {
    local dir="$PLUGINS_ROOT/agent/design"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: design
name: Test design
kind: agent
version: 0.0.1
hooks:
  run: design_run
requires:
  core:
    - redaction
provides:
  role: designer
outputs:
  - id: design_out
    path: ${artifact_dir}/design.md
    type: text/markdown
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
design_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '# Design\n```scope\nf.txt\n```\n' > "$state_dir/artifacts/design.md"
    return 0
}
PLUG
}

_make_impact_plugin() {
    local dir="$PLUGINS_ROOT/agent/impact"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: impact
name: Test impact
kind: agent
version: 0.0.1
hooks:
  run: impact_run
requires:
  core:
    - redaction
provides:
  role: impact_analyzer
outputs:
  - id: impact_out
    path: ${artifact_dir}/impact.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
impact_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}' \
        > "$state_dir/artifacts/impact.json"
    return 0
}
PLUG
}

_make_plan_plugin() {
    local dir="$PLUGINS_ROOT/agent/plan"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: plan
name: Test plan
kind: agent
version: 0.0.1
hooks:
  run: plan_run
requires:
  core:
    - redaction
provides:
  role: planner
outputs:
  - id: plan_out
    path: ${artifact_dir}/plan.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
plan_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["f.txt"],"estimated_lines":1}],"estimated_total_lines":1,"notes":""}' \
        > "$state_dir/artifacts/plan.json"
    return 0
}
PLUG
}

# acceptance-gate stub: writes the gate_result with a configurable failure entry
# (via ZBUILD_TEST_GATE_FAILURE) and returns rc=1 (the real gate does this for
# EVERY fail class). An empty failure → verdict=pass, rc=0.
_make_acceptance_gate_plugin() {
    local dir="$PLUGINS_ROOT/agent/acceptance-gate"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: acceptance-gate
name: Test acceptance-gate
kind: agent
version: 0.0.1
hooks:
  run: acceptance_gate_run
requires:
  core:
    - redaction
provides:
  role: acceptance_gate
outputs:
  - id: gate_result
    path: ${artifact_dir}/acceptance-gate-result.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
acceptance_gate_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    local f="${ZBUILD_TEST_GATE_FAILURE:-}"
    if [[ -z "$f" ]]; then
        printf '{"verdict":"pass","disposition":"none","failures":[]}' \
            > "$state_dir/artifacts/acceptance-gate-result.json"
        return 0
    fi
    # Mirror the real gate's class→disposition mapping (ADR-021 / ADR-036): the
    # engine reads ONLY this generic disposition field, not the failure class.
    local disp
    case "$f" in
        untagged_spec:*)                        disp="recoverable" ;;
        negctl_error:* | reachability_error:*)  disp="advisory" ;;
        *)                                      disp="terminal" ;;
    esac
    printf '{"verdict":"fail","disposition":"%s","failures":["%s"]}' "$disp" "$f" \
        > "$state_dir/artifacts/acceptance-gate-result.json"
    return 1
}
PLUG
}

# design-gate stub: always passes so design_verify_cycle converges on iter 1
# (this test's subject is the build_test_cycle acceptance-gate, not design).
_make_design_gate_plugin() {
    local dir="$PLUGINS_ROOT/agent/design-gate"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: design-gate
name: Test design-gate
kind: agent
version: 0.0.1
hooks:
  run: design_gate_run
requires:
  core:
    - redaction
provides:
  role: design_gate
outputs:
  - id: design_gate_out
    path: ${artifact_dir}/design-gate.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
design_gate_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"pass","summary":"ok"}' \
        > "$state_dir/artifacts/design-gate.json"
    return 0
}
PLUG
}

# gate-aggregator stub: rolls the acceptance-gate result into the cycle's
# convergence verdict. A TERMINAL acceptance disposition is hard-halted by the
# orchestrator BEFORE the aggregator (rc=8), so this only governs the
# non-terminal cases: for pass / recoverable / advisory it emits verdict=pass so
# build_test_cycle converges (and status=success WITHOUT the retired review
# rescue). This mirrors the real gate-aggregator, which never blocks on an
# advisory/recoverable member.
_make_gate_aggregator_plugin() {
    local dir="$PLUGINS_ROOT/agent/gate-aggregator"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: gate-aggregator
name: Test gate-aggregator
kind: agent
version: 0.0.1
hooks:
  run: gate_aggregator_run
requires:
  core:
    - redaction
provides:
  role: gate_aggregator
outputs:
  - id: gate_aggregator_out
    path: ${artifact_dir}/gate-aggregator.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
gate_aggregator_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"pass","summary":"ok","gates":[]}' \
        > "$state_dir/artifacts/gate-aggregator.json"
    return 0
}
PLUG
}

# ─── Build common plugin stubs (rc=0 unless overridden below) ─────────────────
# #979: standard.yaml retired → drive the shipped default simple.yaml. The
# acceptance-gate is a member of simple.yaml's build_test_cycle; its
# disposition→terminal/recoverable/advisory mechanic (the subject) is unchanged.
# For a non-terminal disposition the gate-aggregator passes → the cycle converges
# normally → status=success WITHOUT relying on the retired review-stage rescue
# path (see the T2/T3 #979 notes below). A terminal disposition hard-halts (rc=8).
# #1074: hydrate is the FIRST stage in simple.yaml. This test enumerates the
# roster, and the runner's resolvability preflight refuses to start when any
# leaf has no plugin — so without this stub the pipeline aborts before intake
# and every assertion below fails for a reason unrelated to what it tests.

# build: the router hit the account's rate limit. The stage says so in its v2
# result the way build/lib/summary.sh does after #2111 — disposition
# unavailable, the reset text under data.rate_limit — and returns 1.
_make_build_plugin() {
    local dir="$PLUGINS_ROOT/agent/build"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'MANIFEST'
id: build
name: Test build (passing)
kind: agent
version: 0.0.1
hooks:
  run: build_run
requires:
  core:
    - redaction
provides:
  role: builder
  result_contract: 2
outputs:
  - id: build_summary
    path: ${artifact_dir}/build-summary.json
    type: json
    required: true
    primary: true
MANIFEST
    cat > "$dir/plugin.sh" <<'PLUG'
build_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '%s\n' '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"","data":{}}' \
        > "$state_dir/artifacts/build-summary.json"
    return 0
}
PLUG
}
_make_test_plugin() {
    local dir="$PLUGINS_ROOT/agent/test"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'MANIFEST'
id: test
name: Test test (passing)
kind: agent
version: 0.0.1
hooks:
  run: test_run
requires:
  core:
    - redaction
provides:
  role: tester
MANIFEST
    cat > "$dir/plugin.sh" <<'PLUG'
test_run() { return 0; }
PLUG
}

_make_slow_intake_plugin() {
    local dir="$PLUGINS_ROOT/agent/intake"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'MANIFEST'
id: intake
name: Test intake (optionally slow)
kind: agent
version: 0.0.1
hooks:
  run: intake_run
requires:
  core:
    - redaction
provides:
  role: intake
MANIFEST
    cat > "$dir/plugin.sh" <<'PLUG'
intake_run() {
    if [[ -n "${ZBUILD_TEST_SLOW_MARK:-}" ]]; then
        printf 'running\n' > "$ZBUILD_TEST_SLOW_MARK"
        sleep 20
    fi
    return 0
}
PLUG
}
_make_plugin "hydrate"         "hydrate"
_make_slow_intake_plugin
_make_plan_plugin
_make_design_plugin
_make_design_gate_plugin
_make_plugin "impact"          "impact_analyzer"
_make_build_plugin
_make_test_plugin
_make_plugin "shape-floor"     "shape_floor"
_make_acceptance_gate_plugin
_make_plugin "secret-scan"     "secret_scan"
_make_gate_aggregator_plugin
_make_plugin "review-lens"      "review_lens"
_make_plugin "review-aggregator" "review_aggregator"
_make_plugin "pr"              "pr"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ─── the recording gh ───────────────────────────────────────────────────────
GH_LOG="$TEST_TEMP_DIR/gh.log"; GH_BODIES="$TEST_TEMP_DIR/bodies"; mkdir -p "$GH_BODIES"
GH_MODE="$TEST_TEMP_DIR/gh.mode"; printf 'ok' > "$GH_MODE"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in *body=@*) f="\${args##*body=@}"; f="\${f%% *}"; n="\$(ls "$GH_BODIES" | wc -l | tr -d ' ')"; cp "\$f" "$GH_BODIES/body-\$((n+1)).txt" ;; esac
printf '%s\n' "\$args" >> "$GH_LOG"
mode="\$(cat "$GH_MODE")"
case "\$args" in
  "auth status"*) exit 0 ;;
  api*)
      [[ "\$mode" == "fail500" ]] && { echo "HTTP 500: boom" >&2; exit 1; }
      case "\$args" in
        *--paginate*) echo '[]' ;;
        *"-X PATCH"*) echo '{}' ;;
        *issues/*/comments*) echo 4242 ;;
        *) echo '{}' ;;
      esac
      exit 0 ;;
esac
echo ""; exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"
# The gate needs a github.com origin; zb_test_repo gave a local bare remote.
git -C "$_ZB_REPO" remote rename origin bare >/dev/null 2>&1
git -C "$_ZB_REPO" remote add origin https://github.com/testuser/testrepo.git

export ZBUILD_STATUS_COMMENT=1            # the harness pins 0; this test wants the real thing
export ZBUILD_STATUS_COMMENT_MIN_INTERVAL=0
export ZBUILD_STATUS_COMMENT_POLL=0.2
export ZBUILD_STATUS_COMMENT_REAP_TIMEOUT=10
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5
export ZBUILD_INTAKE_SKIP_BRANCH=1
export ZBUILD_NO_WORKTREE=1
unset NO_GITHUB

posts() { grep -c -E "^api repos/testuser/testrepo/issues/${_ZB_ISSUE}/comments" "$GH_LOG" 2>/dev/null || true; }
patches() { grep -c -- '-X PATCH' "$GH_LOG" 2>/dev/null || true; }
# Sort BASENAMES numerically: the temp path itself has dashes, so `sort -t-`
# on full paths keyed on the wrong field.
last_body() { local f; f="$(cd "$GH_BODIES" && ls body-*.txt 2>/dev/null | sort -t- -k2 -n | tail -1)"; [[ -n "$f" ]] && cat "$GH_BODIES/$f"; }
sidecars() { pgrep -f "run-status-comment.sh --events $EVENTS_JSONL" | wc -l | tr -d ' '; }

_reset() { : > "$EVENTS_JSONL"; : > "$GH_LOG"; rm -f "$GH_BODIES"/* "$STATE_DIR/status-comment.json" "$STATE_DIR/status-comment.log"; }
_run_pipeline() {
    _reset
    set +e
    ( cd "$_ZB_REPO" && bash "$REPO_ROOT/core/pipeline/runner.sh" \
        --issue "$_ZB_ISSUE" --template simple --no-resume \
        >"$TEST_TEMP_DIR/runner.stdout" 2>"$TEST_TEMP_DIR/runner.stderr" )
    _RUNNER_RC=$?
    set -e
}

# ─── SPEC-1: a healthy run — one POST, PATCHes, final header, order ────────
print_test_section "[SPEC-1] healthy run"
_run_pipeline
baseline_rc="$_RUNNER_RC"
assert_eq "[SPEC-1] exactly one POST for the run" "1" "$(posts)"
if [[ "$(patches)" -ge 1 ]]; then assert_pass "[SPEC-1] at least one PATCH ($(patches))"; else assert_fail "[SPEC-1] at least one PATCH" "none; log: $(cat "$STATE_DIR/status-comment.log" 2>/dev/null)"; fi
end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_contains "[SPEC-1] the final body's header carries the run's end status ($end_status)" "$(last_body)" "**${end_status}**"
assert_contains "[SPEC-1] the body is marked with the run id" "$(last_body)" 'zbuild-run-status run_id='
first_row="$(last_body | grep -E '^\*\*' | sed -n 1p)"
last_started="$(jq -r 'select(.type=="plugin.run.start" and .seq != null) | .seq' "$EVENTS_JSONL" | tail -1)"
assert_contains "[SPEC-1] the first row is the LAST dispatched stage (newest first: seq $last_started)" "$first_row" "**${last_started} "
assert_file_exists "[SPEC-1] status-comment.json persisted in the state dir" "$STATE_DIR/status-comment.json"
assert_eq "[SPEC-1] the persisted id is the one GitHub returned" "4242" "$(jq -r .comment_id "$STATE_DIR/status-comment.json")"
assert_eq "[SPEC-1] no sidecar left behind" "0" "$(sidecars)"
assert_eq "[SPEC-1] the sidecar wrote nothing into events.jsonl" "0" "$(jq -c 'select(.type|test("status"))' "$EVENTS_JSONL" | wc -l | tr -d ' ')"
row_count="$(last_body | grep -c -E '^\*\*[0-9]')"
if [[ "$row_count" -ge 3 ]]; then assert_pass "[SPEC-1] several stage rows rendered ($row_count)"; else assert_fail "[SPEC-1] several stage rows rendered" "got $row_count: $(last_body)"; fi

# ─── SPEC-2: GitHub down → the runner's exit status is unchanged ───────────
print_test_section "[SPEC-2] GitHub failing every call"
printf 'fail500' > "$GH_MODE"
_run_pipeline
assert_eq "[SPEC-2] runner rc unchanged with gh failing every api call" "$baseline_rc" "$_RUNNER_RC"
assert_contains "[SPEC-2] the failures are logged" "$(cat "$STATE_DIR/status-comment.log")" '500'
assert_file_not_exists "[SPEC-2] no id persisted" "$STATE_DIR/status-comment.json"
assert_eq "[SPEC-2] the run still ended normally (pipeline.end present)" "1" "$(jq -c 'select(.type=="pipeline.end")' "$EVENTS_JSONL" | wc -l | tr -d ' ')"
printf 'ok' > "$GH_MODE"

# ─── SPEC-3: kill switch and non-github origin → no gh call at all ─────────
print_test_section "[SPEC-3] gates"
ZBUILD_STATUS_COMMENT=0 _run_pipeline
assert_eq "[SPEC-3] ZBUILD_STATUS_COMMENT=0 → no comment API call" "0" "$(( $(posts) + $(patches) ))"
assert_eq "[SPEC-3] …and the run's rc is unchanged" "$baseline_rc" "$_RUNNER_RC"
git -C "$_ZB_REPO" remote set-url origin git@gitlab.com:x/y.git
_run_pipeline
assert_eq "[SPEC-3] non-github origin → no comment API call" "0" "$(( $(posts) + $(patches) ))"
git -C "$_ZB_REPO" remote set-url origin https://github.com/testuser/testrepo.git

# ─── SPEC-4: TERM mid-run — the running row keeps its start; final says why ─
# The slow stage is intake, a LINEAR stage: the runner's own trap answers a
# TERM there with exit 143 + pipeline.aborted reason=sigterm. (A TERM during
# a CYCLE member is answered by _cycle_on_signal, which emits cycle.aborted
# and returns 130 from the handler — the run then carries on; filed separately.)
print_test_section "[SPEC-4] SIGTERM mid-run"
export ZBUILD_TEST_SLOW_MARK="$TEST_TEMP_DIR/slow.mark"; rm -f "$ZBUILD_TEST_SLOW_MARK"
_reset
( cd "$_ZB_REPO" && exec bash "$REPO_ROOT/core/pipeline/runner.sh" --issue "$_ZB_ISSUE" --template simple --no-resume \
    >"$TEST_TEMP_DIR/runner4.stdout" 2>"$TEST_TEMP_DIR/runner4.stderr" ) &
RUNNER_PID=$!
if wait_for_event "$ZBUILD_TEST_SLOW_MARK" 'running' 600 0.1; then
    sleep 1
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    set +e; wait "$RUNNER_PID"; rc4=$?; set -e
    assert_eq "[SPEC-4] runner exits 143 on TERM" "143" "$rc4"
    intake_seq="$(jq -r 'select(.type=="plugin.run.start" and .stage=="intake") | .seq' "$EVENTS_JSONL" | tail -1)"
    assert_contains "[SPEC-4] the running intake row is in the final body" "$(last_body)" "**${intake_seq} intake**"
    assert_contains "[SPEC-4] …still marked running (it never ended)" "$(last_body | grep -F "**${intake_seq} intake**")" '→ running'
    assert_contains "[SPEC-4] the final header names the signal" "$(last_body)" 'sigterm'
    assert_eq "[SPEC-4] no sidecar left behind after TERM" "0" "$(sidecars)"
else
    assert_fail "[SPEC-4] the slow intake started" "marker never appeared; stderr: $(tail -5 "$TEST_TEMP_DIR/runner4.stderr")"
    kill -KILL "$RUNNER_PID" 2>/dev/null || true
fi
unset ZBUILD_TEST_SLOW_MARK

[[ -n "${RSC_DEBUG_KEEP:-}" ]] && cp -R "$TEST_TEMP_DIR" "$RSC_DEBUG_KEEP" 2>/dev/null
cleanup_test_env
print_test_results
exit $((FAIL > 0))
