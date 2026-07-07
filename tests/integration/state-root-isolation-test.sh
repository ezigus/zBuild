#!/usr/bin/env bash
# Integration (#1127): general nested-run STATE/EVENT isolation via the
# ZBUILD_STATE_ROOT engine indirection.
#
# Root cause: the in-pipeline `test` stage spawns the suite in a fresh-user
# shell (scripts/lib/env-scrub.sh) that scrubs the whole ZBUILD_* / _TPL_*
# namespace but PRESERVES HOME (ADR-024). A nested `runner.sh` inside that
# suite therefore re-roots to the DEFAULT $HOME/.zbuild/state under the REAL
# home and clobbers the parent's shared artifacts — the `latest` symlink
# repoint and the --no-resume global event clear.
#
# Fix: introduce `${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}` and thread it
# through every live state/event root site, then fence the test stage by
# exporting ZBUILD_STATE_ROOT to a throwaway temp AFTER the scrub. A nested
# runner then roots its ENTIRE tree (state, events, runs/<id>/, latest,
# global-clear) inside the fence, never the parent's real state.
#
# Contract:
#   A latest-not-clobbered: parent `latest` symlink survives a nested run.
#   B parent-state-untouched: parent pipeline-state.json byte-identical;
#     nested state lands under the fence.
#   C events-not-polluted: parent flat events.jsonl untouched under
#     --no-resume (global-clear now targets the fence).
#   D nested-run-still-functions: nested run produces a valid state file +
#     terminal status + events, all under the fence.
#   E production-default-preserved: with ZBUILD_STATE_ROOT UNSET the runner
#     roots at $HOME/.zbuild/state, and `zbuild --resume-latest` reads the
#     resolved root (fenced when set) — guards the indirection default.
#   F end-to-end test-stage fence (issue DoD): a `test` stage whose suite
#     spawns a bare `runner.sh` leaves the real $HOME/.zbuild/state unchanged.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# Assertions must never abort the run: a sourced lib may leave errexit on, and
# assert_fail returns nonzero when called without a detail arg. Keep -u/pipefail.
set +e

print_test_header "state-root isolation (#1127)"
setup_test_env "state-root-isolation-1127"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"

# Minimal two-leaf roster (intake → build); the isolation contract is not
# stage-count dependent, so drive the cheap fixture (same pattern as
# per-run-state-isolation-test.sh). #1268: stage the fixture under
# TEST_TEMP_DIR via ZBUILD_TEMPLATES_DIR (install_template_fixture) — reaped by
# the master trap, never written into the tracked config/templates/. Section F
# below relies on the test-plugin propagating ZBUILD_TEMPLATES_DIR through its
# fresh-shell scrub so the nested runner still resolves this fixture (SPEC-7).
install_template_fixture runner-state-dir-minimal
mock_plugin_factory "intake" "agent" 0 "" "" >/dev/null
mock_plugin_factory "build"  "agent" 0 "" "" >/dev/null

# The "real" user home whose default root is the parent tree we must protect.
HOME_DIR="$TEST_TEMP_DIR/home"; mkdir -p "$HOME_DIR/.zbuild"
PARENT_ROOT="$HOME_DIR/.zbuild/state"
FENCE="$TEST_TEMP_DIR/fence-state"; mkdir -p "$FENCE"

# ─── Seed the parent tree: a live run + latest pointer + flat events ─────────
PARENT_RUN_DIR="$PARENT_ROOT/runs/PARENT"; mkdir -p "$PARENT_RUN_DIR"
PARENT_STATE="$PARENT_RUN_DIR/pipeline-state.json"
cat > "$PARENT_STATE" <<'JSON'
{"run_id":"PARENT","status":"running","stages":["intake","build"],"seeded":true}
JSON
ln -sfn "$PARENT_RUN_DIR" "$PARENT_ROOT/latest"
PARENT_EVENTS="$PARENT_ROOT/events.jsonl"
printf '{"event":"parent-1"}\n{"event":"parent-2"}\n{"event":"parent-3"}\n' > "$PARENT_EVENTS"

# Golden copies for byte-identical comparison.
PARENT_STATE_GOLD="$TEST_TEMP_DIR/parent-state.gold"; cp "$PARENT_STATE" "$PARENT_STATE_GOLD"
PARENT_EVENTS_GOLD="$TEST_TEMP_DIR/parent-events.gold"; cp "$PARENT_EVENTS" "$PARENT_EVENTS_GOLD"
parent_latest_target="$(readlink "$PARENT_ROOT/latest")"

# run_nested <run_id> — a default-state runner fenced by ZBUILD_STATE_ROOT.
run_nested() {
    local run_id="$1"; shift
    set +e
    env -u ZBUILD_STATE_DIR -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL \
        -u ZBUILD_STATE_FILE -u ZBUILD_EVENTS_DB \
        ZBUILD_STATE_ROOT="$FENCE" \
        ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
        ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
        ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
        ZBUILD_RUN_ID="$run_id" HOME="$HOME_DIR" PATH="$PATH" "$@" \
        bash "$RUNNER" --issue 1127 --no-resume --template runner-state-dir-minimal >/dev/null 2>&1
    local rc=$?; return $rc
}

run_nested "nested-aaa"; assert_eq "nested run exits 0" "0" "$?"

# ─── SPEC-A: parent `latest` symlink not clobbered ──────────────────────────
now_latest="$(readlink "$PARENT_ROOT/latest" 2>/dev/null || echo MISSING)"
assert_eq "A: parent latest still → PARENT run dir" "$parent_latest_target" "$now_latest"
if [[ -L "$FENCE/latest" ]]; then
    ft="$(readlink "$FENCE/latest")"
    case "$ft" in
        *"/runs/nested-aaa") assert_pass "A: fenced latest → nested run" ;;
        *) assert_fail "A: fenced latest should point at nested-aaa" "got: $ft" ;;
    esac
else
    assert_fail "A: fenced latest symlink not created under FENCE"
fi

# ─── SPEC-B: parent state byte-identical; nested state under the fence ───────
if cmp -s "$PARENT_STATE" "$PARENT_STATE_GOLD"; then
    assert_pass "B: parent pipeline-state.json byte-identical"
else
    assert_fail "B: parent pipeline-state.json was modified"
fi
assert_file_exists "B: nested state under the fence" \
    "$FENCE/runs/nested-aaa/pipeline-state.json"
if [[ -e "$PARENT_ROOT/runs/nested-aaa" ]]; then
    assert_fail "B: nested run must NOT land under the parent root"
else
    assert_pass "B: nested run kept out of the parent root"
fi

# ─── SPEC-C: parent flat events.jsonl untouched under --no-resume ────────────
if cmp -s "$PARENT_EVENTS" "$PARENT_EVENTS_GOLD"; then
    assert_pass "C: parent events.jsonl untouched (global-clear targets fence)"
else
    assert_fail "C: parent events.jsonl was modified by nested --no-resume"
fi

# ─── SPEC-D: nested run still functions inside the fence ─────────────────────
nested_state="$FENCE/runs/nested-aaa/pipeline-state.json"
if [[ -f "$nested_state" ]]; then
    nrid="$(jq -r '.run_id // empty' "$nested_state" 2>/dev/null)"
    nstatus="$(jq -r '.status // empty' "$nested_state" 2>/dev/null)"
    assert_eq "D: nested state has its own run_id" "nested-aaa" "$nrid"
    case "$nstatus" in
        complete|completed|success|failed|error|incomplete)
            assert_pass "D: nested run reached a terminal status ($nstatus)" ;;
        *) assert_fail "D: nested run not terminal" "status=$nstatus" ;;
    esac
    assert_file_exists "D: nested events under the fence" \
        "$FENCE/runs/nested-aaa/events.jsonl"
else
    assert_fail "D: nested state file missing under fence"
fi

# ─── SPEC-E: production default preserved (ZBUILD_STATE_ROOT unset) ──────────
HOME_DIR2="$TEST_TEMP_DIR/home2"; mkdir -p "$HOME_DIR2/.zbuild"
set +e
env -u ZBUILD_STATE_DIR -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL \
    -u ZBUILD_STATE_FILE -u ZBUILD_EVENTS_DB -u ZBUILD_STATE_ROOT \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_RUN_ID="def-1" HOME="$HOME_DIR2" PATH="$PATH" \
    bash "$RUNNER" --issue 1127 --no-resume --template runner-state-dir-minimal >/dev/null 2>&1
e_rc=$?
assert_eq "E: default-root run exits 0" "0" "$e_rc"
assert_file_exists "E: unset root → state under \$HOME/.zbuild/state/runs/" \
    "$HOME_DIR2/.zbuild/state/runs/def-1/pipeline-state.json"

# E2: `zbuild --resume-latest` reads the resolved root. Point ZBUILD_STATE_ROOT
# at an EMPTY dir while HOME has a valid latest; a threaded CLI reads the fenced
# (empty) root and errors "no state file", proving it did NOT read the real
# HOME latest. RED at baseline (CLI reads HOME → resumes the parent).
EMPTY_ROOT="$TEST_TEMP_DIR/empty-root"; mkdir -p "$EMPTY_ROOT"
set +e
e2_out="$(env -u ZBUILD_STATE_DIR ZBUILD_STATE_ROOT="$EMPTY_ROOT" \
    HOME="$HOME_DIR" PATH="$PATH" \
    bash "$ZBUILD_CLI" --resume-latest 2>&1)"
e2_rc=$?
if [[ $e2_rc -ne 0 && "$e2_out" == *"$EMPTY_ROOT"* ]]; then
    assert_pass "E2: zbuild --resume-latest honors ZBUILD_STATE_ROOT (empty fence → no state)"
else
    assert_fail "E2: zbuild --resume-latest did not resolve the fenced root" \
        "rc=$e2_rc out=$e2_out"
fi

# ─── SPEC-F: end-to-end test-stage fence (issue DoD) ─────────────────────────
# Drive the real test plugin (_test_run_inner) with a suite command that spawns
# a bare default-state runner. The plugin scrubs the ZBUILD_* namespace (fresh
# user shell) then exports ZBUILD_STATE_ROOT to its throwaway $tmp. The nested
# runner must therefore land under that fence — NOT the real parent tree.
# Assert the parent's latest + state + events are unchanged after the stage.
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

# Isolate the stage's own event bus / artifacts away from the parent tree.
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/stage-events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
STAGE_ARTIFACTS="$TEST_TEMP_DIR/stage-artifacts"; mkdir -p "$STAGE_ARTIFACTS"
export ZBUILD_ARTIFACT_DIR="$STAGE_ARTIFACTS"

F_FIXTURE="$TEST_TEMP_DIR/f-repo"; mkdir -p "$F_FIXTURE"
git -C "$F_FIXTURE" init -q
git -C "$F_FIXTURE" config user.name t
git -C "$F_FIXTURE" config user.email t@t
printf 'hi\n' > "$F_FIXTURE/tracked.txt"
git -C "$F_FIXTURE" add tracked.txt
git -C "$F_FIXTURE" commit -q -m init
F_PATCH="$STAGE_ARTIFACTS/diff.patch"; : > "$F_PATCH"
F_OUT="$STAGE_ARTIFACTS/test-results.json"

# The suite command: spawn a bare default-state runner. It relies on HOME
# (preserved by the scrub) — WITHOUT the fence it would re-root under
# $HOME_DIR/.zbuild/state and clobber the parent latest.
#
# #1268 SPEC-7: capture the nested runner's output to an inspectable absolute
# log, and (deferred-expansion) copy its resolved pipeline-state.json out of the
# plugin's throwaway fence ($ZBUILD_STATE_ROOT, set INSIDE the fresh shell)
# before the RETURN trap reaps it — so we can prove the nested runner actually
# resolved the temp-staged fixture and reached state-init, rather than the
# built-in fallback (which would make the parent-untouched assertions pass
# hollowly, #913).
NESTED_LOG="$TEST_TEMP_DIR/f-nested-runner.log"
NESTED_STATE_COPY="$TEST_TEMP_DIR/f-nested-state.json"
F_CMD="ZBUILD_PLUGINS_ROOT='$PLUGINS_ROOT' ZBUILD_EVENT_SCHEMA='$REPO_ROOT/config/event-schema.json' ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn ZBUILD_RUN_ID='nested-suite' bash '$RUNNER' --issue 1127 --no-resume --template runner-state-dir-minimal > '$NESTED_LOG' 2>&1 || true; cp \"\$ZBUILD_STATE_ROOT/runs/nested-suite/pipeline-state.json\" '$NESTED_STATE_COPY' 2>/dev/null || true; echo suite-ok"

set +e
# #1268: _test_run_inner is a shell FUNCTION — invoke it in a subshell with
# HOME/PATH exported. The prior `env HOME=… PATH=… _test_run_inner …` could
# never run it: `env` execs a PROGRAM named _test_run_inner, failed with
# "No such file or directory", and the whole section-F fence passed HOLLOWLY
# (parent untouched only because nothing ran, #913). The SPEC-7 assertions
# below now prove the nested run actually executes and reaches state-init.
(
    export HOME="$HOME_DIR" PATH="$PATH"
    _test_run_inner "$F_PATCH" "$F_FIXTURE" "$F_OUT" "$F_CMD"
) >/dev/null 2>&1
set -e

now_latest_f="$(readlink "$PARENT_ROOT/latest" 2>/dev/null || echo MISSING)"
assert_eq "F: parent latest unchanged after test-stage nested run" \
    "$parent_latest_target" "$now_latest_f"
if cmp -s "$PARENT_STATE" "$PARENT_STATE_GOLD"; then
    assert_pass "F: parent state byte-identical after test-stage nested run"
else
    assert_fail "F: parent state modified by test-stage nested run"
fi
if cmp -s "$PARENT_EVENTS" "$PARENT_EVENTS_GOLD"; then
    assert_pass "F: parent events unchanged after test-stage nested run"
else
    assert_fail "F: parent events modified by test-stage nested run"
fi
if [[ -e "$PARENT_ROOT/runs/nested-suite" ]]; then
    assert_fail "F: test-stage nested run leaked into the parent root"
else
    assert_pass "F: test-stage nested run stayed out of the parent root"
fi

# ─── SPEC-7 (#1268): the section-F fence is NOT hollow ───────────────────────
# The nested runner must have RESOLVED the temp-staged fixture (via the test
# plugin re-exporting ZBUILD_TEMPLATES_DIR after its scrub) and reached
# state-init — proving the parent-untouched assertions above exercised a real
# nested run, not a template-resolution fallback/abort.
if [[ -f "$NESTED_STATE_COPY" ]]; then
    assert_pass "[SPEC-7] nested runner reached state-init (persisted pipeline-state.json under the fence)"
    ns_stages="$(jq -r '.stage_statuses | keys | join(",")' "$NESTED_STATE_COPY" 2>/dev/null || echo)"
    case ",$ns_stages," in
        *",build,"*)
            assert_pass "[SPEC-7] nested run used the fixture roster (build ran; no built-in fallback)" ;;
        *)
            assert_fail "[SPEC-7] nested run used the fixture roster" \
                "stage_statuses keys=$ns_stages (expected the intake→build fixture, not the built-in fallback)" ;;
    esac
else
    assert_fail "[SPEC-7] nested runner reached state-init" \
        "no nested pipeline-state.json copied out — template-resolution abort/fallback? log head: $(head -c 300 "$NESTED_LOG" 2>/dev/null | tr '\n' '|')"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
