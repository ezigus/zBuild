#!/usr/bin/env bash
# Integration (#887): per-run state-directory isolation. Two concurrent
# `pipeline start` runs must NOT share a state dir / artifacts. Regression for
# dogfood run 20260614203820-82916 (#864), where a concurrent #846 run clobbered
# #864's plan.json because both defaulted to ~/.zbuild/state/.
#
# Contract:
#   T1: a default-state run roots state under $HOME/.zbuild/state/runs/<run_id>/.
#   T2: two runs with distinct run_ids land in distinct run dirs (no clobber).
#   T3: the `latest` symlink points at the most recent run.
#   T4: an explicit ZBUILD_STATE_DIR still wins (no runs/ re-root) — back-compat.
#   T5: the runner exports ZBUILD_EVENTS_DIR per-run (events don't interleave).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "per-run state isolation (#887)"
setup_test_env "per-run-state-isolation-887"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
# #921: standard roster single-sourced (was a hand-maintained for-loop).
register_standard_pipeline_stubs

HOME_DIR="$TEST_TEMP_DIR/home"; mkdir -p "$HOME_DIR/.zbuild"

# run_pipeline <run_id> [extra env KEY=VAL ...] — default-state run under HOME_DIR.
run_pipeline() {
    local run_id="$1"; shift
    set +e
    env -u ZBUILD_STATE_DIR -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL -u ZBUILD_STATE_FILE \
        ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
        ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
        ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
        ZBUILD_RUN_ID="$run_id" HOME="$HOME_DIR" PATH="$PATH" "$@" \
        bash "$RUNNER" --issue 887 --no-resume >/dev/null 2>&1
    local rc=$?; set -e; return $rc
}

# ─── T1 + T2: two distinct runs isolate ─────────────────────────────────────
run_pipeline "run-aaa"; assert_eq "T1: run-aaa exits 0" "0" "$?"
run_pipeline "run-bbb"; assert_eq "T2: run-bbb exits 0" "0" "$?"
assert_file_exists "T1: run-aaa state under runs/run-aaa/" "$HOME_DIR/.zbuild/state/runs/run-aaa/pipeline-state.json"
assert_file_exists "T2: run-bbb state under runs/run-bbb/" "$HOME_DIR/.zbuild/state/runs/run-bbb/pipeline-state.json"
a_run="$(jq -r '.run_id' "$HOME_DIR/.zbuild/state/runs/run-aaa/pipeline-state.json" 2>/dev/null)"
b_run="$(jq -r '.run_id' "$HOME_DIR/.zbuild/state/runs/run-bbb/pipeline-state.json" 2>/dev/null)"
assert_eq "T2: run-aaa state has its own run_id (no clobber)" "run-aaa" "$a_run"
assert_eq "T2: run-bbb state has its own run_id (no clobber)" "run-bbb" "$b_run"

# ─── T3: latest → most recent run ───────────────────────────────────────────
if [[ -L "$HOME_DIR/.zbuild/state/latest" ]]; then
    latest_target="$(readlink "$HOME_DIR/.zbuild/state/latest")"
    case "$latest_target" in
        *"/runs/run-bbb") assert_pass "T3: latest → run-bbb (most recent)" ;;
        *) assert_fail "T3: latest should point at run-bbb" "got: $latest_target" ;;
    esac
else
    assert_fail "T3: latest symlink not created"
fi

# ─── T4: explicit ZBUILD_STATE_DIR still wins (no runs/ re-root) ─────────────
EXPLICIT="$TEST_TEMP_DIR/explicit-state"; mkdir -p "$EXPLICIT"
set +e
env ZBUILD_STATE_DIR="$EXPLICIT" ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_RUN_ID="run-ccc" HOME="$HOME_DIR" PATH="$PATH" \
    bash "$RUNNER" --issue 887 --no-resume >/dev/null 2>&1
rc=$?; set -e
assert_eq "T4: explicit-state run exits 0" "0" "$rc"
assert_file_exists "T4: explicit ZBUILD_STATE_DIR used verbatim (no runs/)" "$EXPLICIT/pipeline-state.json"
if [[ -d "$EXPLICIT/runs" ]]; then
    assert_fail "T4: explicit state dir must NOT get a runs/ subdir"
else
    assert_pass "T4: explicit state dir not re-rooted"
fi

# ─── T5: events captured per-run (a build stub captures ZBUILD_EVENTS_DIR) ──
ENVCAP="$TEST_TEMP_DIR/envcap.txt"
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<EOF
build_run() { env | grep '^ZBUILD_EVENTS_DIR=' > "$ENVCAP" 2>/dev/null || true; return 0; }
EOF
run_pipeline "run-ddd"
ev="$(cat "$ENVCAP" 2>/dev/null || echo)"
case "$ev" in
    *"/runs/run-ddd"*) assert_pass "T5: ZBUILD_EVENTS_DIR is per-run (runs/run-ddd)" ;;
    *) assert_fail "T5: ZBUILD_EVENTS_DIR not per-run" "got: $ev" ;;
esac

# ─── T6: resume path (explicit STATE_FILE) → events still follow the per-run dir ─
# On `pipeline resume` the CLI sets ZBUILD_STATE_FILE to the run's per-run state
# file (so _state_is_default=false). Events must still follow that dir, not leak
# to the flat default (review finding #2).
RESUME_DIR="$HOME_DIR/.zbuild/state/runs/run-eee"; mkdir -p "$RESUME_DIR"
ENVCAP2="$TEST_TEMP_DIR/envcap2.txt"
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<EOF
build_run() { env | grep '^ZBUILD_EVENTS_DIR=' > "$ENVCAP2" 2>/dev/null || true; return 0; }
EOF
set +e
env -u ZBUILD_STATE_DIR -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL -u ZBUILD_EVENTS_DB \
    ZBUILD_STATE_FILE="$RESUME_DIR/pipeline-state.json" \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_RUN_ID="run-eee" HOME="$HOME_DIR" PATH="$PATH" \
    bash "$RUNNER" --issue 887 --no-resume >/dev/null 2>&1
set -e
ev2="$(cat "$ENVCAP2" 2>/dev/null || echo)"
case "$ev2" in
    *"/runs/run-eee"*) assert_pass "T6: explicit STATE_FILE → events follow its dir (not flat)" ;;
    *) assert_fail "T6: events did not follow STATE_FILE dir" "got: $ev2" ;;
esac

cleanup_test_env
print_test_results
exit $((FAIL > 0))
