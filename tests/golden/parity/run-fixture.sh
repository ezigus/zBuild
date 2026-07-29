#!/usr/bin/env bash
# Fixture helper for parity-local-vs-ci-test.sh
# NOT a test itself — runs runner.sh with mocked binaries and fixed env vars.
#
# Issue #359: drives a multi-stage pipeline (intake -> plan -> build -> test -> pr)
# so the parity check exercises the same engine paths that run in production CI.
# (#979: the old `review` stage was retired with the compound-quality lattice.)
#
# Required env vars (set by parity-local-vs-ci-test.sh before invoking):
#   FIXTURE_STATE_DIR  — directory for state/events output
#   FIXTURE_BIN_DIR    — directory for mock binaries (prepended to PATH)
#
# Additional env vars may be set by the caller to simulate CI or local mode
# (e.g. GITHUB_ACTIONS=true, GITHUB_STEP_SUMMARY, etc.).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Require caller-supplied dirs
: "${FIXTURE_STATE_DIR:?FIXTURE_STATE_DIR must be set by the calling test}"
: "${FIXTURE_BIN_DIR:?FIXTURE_BIN_DIR must be set by the calling test}"

# ── Stage-aware mock claude binary ────────────────────────────────────────────
# route_to_model invokes: claude -p "<prompt>" --print --model <id>
# The mock scans the prompt for stage-specific markers and returns a canned
# response. All responses are deterministic so the goldens are reproducible.
cat > "$FIXTURE_BIN_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
# Extract the prompt: argv pattern is `-p <prompt> --print --model <id>`.
prompt=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) prompt="${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done

# #476: plan, review, security-lens now ALL run in JSON envelope mode
# (ADR-018 Pattern 1 decision #8). Wrap every Pattern 1 response in the
# result envelope so the router's .result extraction finds the payload.
# Build (Pattern 2) already wraps, since route_to_model_loop drives it.
if printf '%s' "$prompt" | grep -q "LOOP_COMPLETE"; then
    # build stage (#467 Pattern 2) — edit the fixture file directly in $PWD
    # (route_to_model_loop runs claude with cwd=$ZBUILD_REPO_ROOT) and emit a
    # result envelope with .result containing the DONE sentinel as the
    # final line.
    mkdir -p "$PWD/tests/fixtures"
    printf 'parity-fixture\n' > "$PWD/tests/fixtures/parity-fixture.txt"
    jq -n --arg r $'Created fixture file.\nLOOP_COMPLETE' \
       '{result:$r, usage:{input_tokens:5, output_tokens:3}}'
else
    # plan stage (default — wrapped per #476)
    jq -n --arg r '{"schema_version":1,"issue":359,"title":"parity fixture","goal":"parity fixture goal","steps":[{"id":"step-1","description":"add parity fixture file","files":["tests/fixtures/parity-fixture.txt"],"estimated_lines":1}],"estimated_total_lines":1,"notes":""}' \
       '{type:"result",subtype:"success",result:$r,usage:{input_tokens:0,output_tokens:0},tool_uses:[]}'
fi
exit 0
MOCK
chmod +x "$FIXTURE_BIN_DIR/claude"

# ── Mock gh binary — returns a fixed PR URL on `gh pr create` ────────────────
cat > "$FIXTURE_BIN_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    pr)
        case "${2:-}" in
            create) echo "https://github.com/testuser/testrepo/pull/359" ;;
            *)      echo "" ;;
        esac
        ;;
    *) echo "" ;;
esac
exit 0
MOCK
chmod +x "$FIXTURE_BIN_DIR/gh"

# ── Mock git binary — accepts all operations; returns deterministic values ───
# pr-open needs: rev-parse --abbrev-ref HEAD (current branch), checkout, push.
# build/test stages need: apply / -C <dir> apply.
cat > "$FIXTURE_BIN_DIR/git" <<'MOCK'
#!/usr/bin/env bash
# Real git binary for delegation (#467 needs git diff/add/init to work).
_real_git=""
for _candidate in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
    [[ -x "$_candidate" ]] && _real_git="$_candidate" && break
done
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--abbrev-ref" ]]; then
            echo "zbuild/issue-359"
        elif [[ "${2:-}" == "--show-toplevel" ]]; then
            echo "/tmp/mock-repo"
        else
            echo "/tmp/mock-repo"
        fi
        ;;
    remote)   echo "https://github.com/testuser/testrepo.git" ;;
    apply)    exit 0 ;;
    push)     exit 0 ;;
    checkout) exit 0 ;;
    -C)
        # #467 Pattern 2: delegate diff / add / status to real git inside the
        # build's repo; intercept apply/push/checkout as before.
        _subcmd="${3:-}"
        case "$_subcmd" in
            diff|add|status|init|config|commit|log)
                [[ -n "$_real_git" ]] && exec "$_real_git" "$@"
                exit 0
                ;;
            *)
                shift; shift; exit 0
                ;;
        esac
        ;;
    *) echo "" ;;
esac
exit 0
MOCK
chmod +x "$FIXTURE_BIN_DIR/git"

# ── Mock rsync — delegates to cp so the test stage's repo-copy path works ────
cat > "$FIXTURE_BIN_DIR/rsync" <<'MOCK'
#!/usr/bin/env bash
src="${@: -2:1}"
dst="${@: -1}"
cp -r "$src/." "$dst/" 2>/dev/null || true
exit 0
MOCK
chmod +x "$FIXTURE_BIN_DIR/rsync"

# ── Write fixture template (Wave B full pipeline) ────────────────────────────
# The runner resolves per-repo template overrides from $PWD/.zbuild/templates/<id>.yaml
# (ADR-016; runner.sh passes $PWD). #1270: stage this fixture-specific template as
# a per-repo overlay in a private throwaway temp repo and run the runner with CWD
# there — instead of writing into the tracked config/templates/ (which leaked the
# fixture into the repo on an interrupted parity run). The repo is OUTSIDE
# FIXTURE_STATE_DIR so it never enters the artifact-path golden snapshot; an EXIT
# trap reaps it (the repo is never touched regardless). extends: simple → merged
# over the shipped base, the loader treats it as old-shape and honors only these
# stages. (No roles → runner resolves by stage id via _find_plugin_for_stage,
# matching the plugin manifest id field.)
_FIXTURE_TPL_REPO="$(mktemp -d "${TMPDIR:-/tmp}/zbuild-parity-tpl.XXXXXX")"
trap 'rm -rf "$_FIXTURE_TPL_REPO"' EXIT
mkdir -p "$_FIXTURE_TPL_REPO/.zbuild/templates"
FIXTURE_TEMPLATE="$_FIXTURE_TPL_REPO/.zbuild/templates/wave-b-parity-fixture.yaml"
cat > "$FIXTURE_TEMPLATE" <<'TPL'
id: wave-b-parity-fixture
name: Wave B Parity Fixture Pipeline
extends: simple
defaults:
  strategy: fanout

stages:
  - id: intake
    gate: auto
  - id: plan
    gate: auto
  - id: build
    gate: auto
  - id: test
    gate: auto
  # #979: the retired `review` stage is replaced by `review-aggregator` (a KEEP
  # stage). The old single `review` stage resolved to no plugin and aborted the
  # run at LOAD under the resolvability preflight. review-aggregator is the live
  # advisory review-family stage in production simple.yaml (review_lenses ->
  # review-aggregator -> pr); with no lens group it degrades to an empty advisory
  # review-report.json (no LLM call) and returns 0 — which also gives the pr
  # stage the review signal its ADR-001 fail-closed guard requires.
  - id: review-aggregator
    gate: auto
  - id: pr
    gate: auto
    # #756: dispatch the pr stage by role so it resolves to the pr-delivery
    # agent (id: pr-delivery) and not the pr-open tool (id: pr), mirroring
    # the production shipped template. Other stages still resolve by stage id.
    roles: [pr_delivery]
TPL

# ── Mock repo for the test stage to copy and apply diffs against ─────────────
# #467: build now needs a real git repo so `git diff HEAD` works (not just a
# bare .git dir). Use the system git binary BEFORE we shadow it on PATH below.
MOCK_REPO="$FIXTURE_STATE_DIR/mock-repo"
mkdir -p "$MOCK_REPO"
(
    cd "$MOCK_REPO"
    /usr/bin/env git init -q
    /usr/bin/env git config user.email parity@zbuild
    /usr/bin/env git config user.name parity-fixture
    echo seed > seed.txt
    /usr/bin/env git add seed.txt
    /usr/bin/env git commit -q -m "parity seed"
) >/dev/null 2>&1

# ── Wire up environment ───────────────────────────────────────────────────────
export PATH="$FIXTURE_BIN_DIR:$PATH"
export ZBUILD_STATE_DIR="$FIXTURE_STATE_DIR"
export ZBUILD_EVENTS_DIR="$FIXTURE_STATE_DIR/events"
export ZBUILD_EVENTS_JSONL="$FIXTURE_STATE_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"          # exclude SQLite — JSONL only for diff
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="parity-fixture-run-001"  # fixed run_id — prevents non-determinism
export NO_GITHUB=true
export ZBUILD_OUTPUT_GH_COMMENT=0
export ZBUILD_OUTPUT_GH_CHECK_RUN=0
export ZBUILD_PLATFORM_OVERRIDE=generic       # prevent platform-detection divergence

# Wave B inputs
export ZBUILD_GOAL="parity fixture goal"
export ZBUILD_REPO_ROOT="$MOCK_REPO"
export ZBUILD_TEST_CMD="true"                 # test stage runs this in tmp dir
# Issue #484: intake's new branch path needs a real git repo; this fixture
# stubs git on PATH so we can't run real symbolic-ref/checkout. The parity
# test is about engine env-agnosticism, not branch behavior — skip it here.
# Dedicated branch tests cover the new code path.
export ZBUILD_INTAKE_SKIP_BRANCH=1
# ADR-052 (#1640): same reasoning one step earlier. The engine acquires a per-run
# worktree before the first stage, and `git worktree add` cannot work against the
# PATH shim above — it exits 0 without creating anything. This fixture asserts the
# engine is environmentally agnostic, not that worktrees work, so opt out the way
# an operator would. Worktree behavior is covered by worktree-run-isolation-test.sh.
export ZBUILD_NO_WORKTREE=1

mkdir -p "$ZBUILD_EVENTS_DIR"

# #1270: CWD = the overlay repo so the resolver finds the fixture template.
( cd "$_FIXTURE_TPL_REPO" && bash "$REPO_ROOT/core/pipeline/runner.sh" \
    --issue 359 \
    --template wave-b-parity-fixture )
