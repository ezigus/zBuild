#!/usr/bin/env bash
# Tests: core/output/stage-io.sh — kind=cycle per-iter cycle boundary banners
# (issue #833, ADR-015 §G). Cycles have NO template io: block, so the kind=cycle
# arm forces dests=stdout (fd-2 only; never file, never gh_comment). INPUT is a
# feedback-edge digest, OUTPUT is the termination-predicate eval + velocity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGE_IO_SH="$REPO_ROOT/core/output/stage-io.sh"
ORCH_SH="$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/output/stage-io — kind=cycle banners (#833, ADR-015 §G)"
setup_test_env "stage-io-cycle-kind"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="test-run-cycle-kind"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$STAGE_IO_SH"
# shellcheck disable=SC1090
source "$ORCH_SH"

# Cycles have NO io: block — template_stage_io_dests returns empty for them.
# Mock it accordingly: empty for a cycle id, so the kind=cycle dest-override is
# the only thing that can produce a banner (proves SPEC-5 by construction).
template_stage_io_dests()      { printf ''; }
template_stage_io_tail_lines() { printf ''; }
template_stage_io_redact()     { printf ''; }

# ─── [SPEC-1] stage_io_begin --kind cycle → rc=0 ─────────────────────────────
# Call DIRECTLY (NOT in $()) so the assoc-array seq-reservation persists in this
# shell — the capture_stage_io idiom. Read the reserved seq from
# _STAGE_IO_LAST_SEQ. (A $() begin would lose the pending-state mutation and
# orphan the matching end — exactly the bug the idiom prevents.)
set +e
ZBUILD_STAGE_IO_FD=2 stage_io_begin --kind cycle --stage build_test_cycle \
    --seq-label "1" --input "(no feedback — first iteration)" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-1] stage_io_begin --kind cycle returns rc=0" "0" "$rc"
seq1="$_STAGE_IO_LAST_SEQ"

# ─── [SPEC-2] kind=cycle record passes stage_io_end validator (rc=0) ─────────
set +e
ZBUILD_STAGE_IO_FD=2 stage_io_end --stage build_test_cycle --kind cycle --seq "$seq1" \
    --output "exit_when stage=test_assessment field=verdict op=eq value=pass → NOT MATCHED (got=fail)
velocity=-3 failure_count=3" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-2] kind=cycle record passes stage_io_end validator" "0" "$rc"

# ─── [SPEC-3] INPUT banner contains feedback to_field / 'no feedback' iter1 ──
# Banner routes to fd 2 (default). Capture stderr only; stdout (the reserved
# seq) is discarded. A $()-wrapped begin loses pending state but we only assert
# the rendered banner here.
# iter1 → "no feedback"
in_iter1="$(ZBUILD_STAGE_IO_FD=2 stage_io_begin --kind cycle --stage build_test_cycle \
    --seq-label "1" --input "(no feedback — first iteration)" 2>&1 1>/dev/null)"
assert_contains "[SPEC-3] iter1 INPUT shows no-feedback" "$in_iter1" "no feedback"
# consumed feedback to_field appears
in_iterN="$(ZBUILD_STAGE_IO_FD=2 stage_io_begin --kind cycle --stage build_test_cycle \
    --seq-label "2" --input "prior_test_assessment(fail, 3 changes)" 2>&1 1>/dev/null)"
assert_contains "[SPEC-3] iterN INPUT shows consumed feedback to_field" \
    "$in_iterN" "prior_test_assessment"

# ─── [SPEC-4] OUTPUT banner contains predicate restatement + NOT MATCHED + velocity
# Pair a begin directly (persist pending state) so end has a matching record;
# capture the end banner from fd 2 (stderr).
ZBUILD_STAGE_IO_FD=2 stage_io_begin --kind cycle --stage build_test_cycle \
    --seq-label "1" --input "(no feedback — first iteration)" >/dev/null 2>&1
seq4="$_STAGE_IO_LAST_SEQ"
out4="$(ZBUILD_STAGE_IO_FD=2 stage_io_end --stage build_test_cycle --kind cycle --seq "$seq4" \
    --output "exit_when stage=test_assessment field=verdict op=eq value=pass → NOT MATCHED (got=fail)
velocity=-3 failure_count=3" 2>&1 1>/dev/null)"
assert_contains "[SPEC-4] OUTPUT restates exit_when predicate" "$out4" "exit_when stage=test_assessment field=verdict op=eq value=pass"
assert_contains "[SPEC-4] OUTPUT shows NOT MATCHED (got=...)" "$out4" "NOT MATCHED (got=fail)"
assert_contains "[SPEC-4] OUTPUT shows velocity=" "$out4" "velocity="

# ─── [SPEC-5] kind=cycle → fd2 only; NO file artifact; NO gh_comment ─────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
: > "$ZBUILD_EVENTS_JSONL"
# Stdout must be empty (banner goes to fd 2). Use a gh shim to detect any call.
ghdir="$TEST_TEMP_DIR/gh-spec5"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
echo "GH_CALLED" >> "$ghdir/calls.log"
exit 0
EOF
chmod +x "$ghdir/gh"
export ZBUILD_ISSUE="999"
spec5_stdout_file="$TEST_TEMP_DIR/spec5.stdout"
spec5_stderr_file="$TEST_TEMP_DIR/spec5.stderr"
saved_path="$PATH"; PATH="$ghdir:$PATH"
set +e
ZBUILD_STAGE_IO_FD=2 stage_io_begin --kind cycle --stage build_test_cycle \
    --seq-label "1" --input "(no feedback — first iteration)" >/dev/null 2>&1
seq5="$_STAGE_IO_LAST_SEQ"
ZBUILD_STAGE_IO_FD=2 stage_io_end --stage build_test_cycle --kind cycle --seq "$seq5" \
    --output "exit_when stage=test_assessment field=verdict op=eq value=pass → NOT MATCHED (got=fail)
velocity=-3 failure_count=3" \
    >"$spec5_stdout_file" 2>"$spec5_stderr_file"
rc=$?
set -e
PATH="$saved_path"
unset ZBUILD_ISSUE
assert_eq "[SPEC-5] cycle end rc=0" "0" "$rc"
spec5_stdout="$(cat "$spec5_stdout_file")"
if [[ -z "$spec5_stdout" ]]; then
    assert_pass "[SPEC-5] cycle banner does NOT write to caller stdout"
else
    assert_fail "[SPEC-5] cycle banner does NOT write to caller stdout" "got on stdout: ${spec5_stdout:0:80}"
fi
assert_file_not_exists "[SPEC-5] no file artifact for kind=cycle" \
    "$ZBUILD_STATE_DIR/artifacts/stage-io/build_test_cycle-1.json"
spec5_count=0
if [[ -d "$ZBUILD_STATE_DIR/artifacts/stage-io" ]]; then
    # shellcheck disable=SC2012
    spec5_count=$(ls -1 "$ZBUILD_STATE_DIR/artifacts/stage-io" 2>/dev/null | wc -l | tr -d ' ')
fi
assert_eq "[SPEC-5] stage-io dir empty after kind=cycle capture" "0" "$spec5_count"
if [[ -s "$ghdir/calls.log" ]]; then
    assert_fail "[SPEC-5] gh_comment NOT called for kind=cycle" "calls.log non-empty"
else
    assert_pass "[SPEC-5] gh_comment NOT called for kind=cycle"
fi

# ─── [SPEC-6] unknown --kind=foo still → rc=2 (guard intact) ─────────────────
set +e
stage_io_begin --kind foo --stage some_cycle --input "x" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-6] unknown --kind=foo returns rc=2" "2" "$rc"

# ─── [SPEC-3b] _cycle_render_feedback_digest derives per-cycle digest ────────
# iter1 → no-feedback string.
_CYCLE_TRAP_CYCLE_ID="build_test_cycle"
_CYCLE_FEEDBACK=( "test_assessment:summary|build:prior_test_assessment:false" )
dig1="$(_cycle_render_feedback_digest 1 "$ZBUILD_STATE_DIR" 2>/dev/null)"
assert_contains "[SPEC-3b] digest iter1 → no feedback" "$dig1" "no feedback"
# iterN with present artifact → to_field name + digest.
fbdir="$ZBUILD_STATE_DIR/cycle-build_test_cycle/iter-2/feedback"
mkdir -p "$fbdir"
printf 'fail diagnostics here' > "$fbdir/prior_test_assessment.txt"
dig2="$(_cycle_render_feedback_digest 2 "$ZBUILD_STATE_DIR" 2>/dev/null)"
assert_contains "[SPEC-3b] digest iterN names the consumed to_field" "$dig2" "prior_test_assessment"
# required + missing → MISSING marker.
_CYCLE_FEEDBACK=( "test_assessment:summary|build:prior_test_assessment:true" )
rm -rf "$ZBUILD_STATE_DIR/cycle-build_test_cycle/iter-3"
mkdir -p "$ZBUILD_STATE_DIR/cycle-build_test_cycle/iter-3/feedback"
dig3="$(_cycle_render_feedback_digest 3 "$ZBUILD_STATE_DIR" 2>/dev/null)"
assert_contains "[SPEC-3b] digest required+missing → MISSING" "$dig3" "MISSING"

# ─── [SPEC-4b] _cycle_render_predicate_result formats predicate + velocity ───
_CYCLE_LAST_PREDICATE_KIND="exit_when"
_CYCLE_LAST_PREDICATE_STAGE="test_assessment"
_CYCLE_LAST_PREDICATE_FIELD="verdict"
_CYCLE_LAST_PREDICATE_OP="eq"
_CYCLE_LAST_PREDICATE_EXPECTED="pass"
_CYCLE_LAST_PREDICATE_ACTUAL="fail"
_CYCLE_LAST_PREDICATE_MATCH="false"
_CYCLE_LAST_FAILURE_COUNT=3
pr_out="$(_cycle_render_predicate_result 3 2>/dev/null)"
assert_contains "[SPEC-4b] predicate result restates exit_when" "$pr_out" "exit_when stage=test_assessment field=verdict op=eq value=pass"
assert_contains "[SPEC-4b] predicate result shows NOT MATCHED (got=fail)" "$pr_out" "NOT MATCHED (got=fail)"
assert_contains "[SPEC-4b] predicate result shows velocity + failure_count" "$pr_out" "velocity=-3 failure_count=3"

# ─── [SPEC-11 #1241] banner names the failing gate + reason from aggregator ──
# When state_dir is plumbed and a gate-aggregator-result.json records failed
# gates, a NOT MATCHED cycle OUTPUT banner appends "failed gates: <list>" so the
# operator sees WHICH gate blocked, not just "NOT MATCHED (got=fail)".
_CYCLE_LAST_PREDICATE_KIND="exit_when"
_CYCLE_LAST_PREDICATE_STAGE="gate-aggregator"
_CYCLE_LAST_PREDICATE_FIELD="verdict"
_CYCLE_LAST_PREDICATE_OP="eq"
_CYCLE_LAST_PREDICATE_EXPECTED="pass"
_CYCLE_LAST_PREDICATE_ACTUAL="fail"
_CYCLE_LAST_PREDICATE_MATCH="false"
_CYCLE_LAST_FAILURE_COUNT=10
_sd11="$ZBUILD_STATE_DIR/s11"
mkdir -p "$_sd11/artifacts"
printf '%s\n' '{"verdict":"fail","gates":{"test":"fail","acceptance-gate":"pass"},"failed":["test"]}' \
    > "$_sd11/artifacts/gate-aggregator-result.json"
pr11="$(_cycle_render_predicate_result 2 "$_sd11" 2>/dev/null)"
assert_contains "[SPEC-11] banner names the failing gate (failed gates: test)" "$pr11" "failed gates: test"
assert_contains "[SPEC-11] banner still restates exit_when predicate" "$pr11" "exit_when stage=gate-aggregator"

# [SPEC-11b] no state_dir arg → no failed-gates line (back-compat; renderer with
# only <iter> behaves exactly as before).
pr11b="$(_cycle_render_predicate_result 2 2>/dev/null)"
if grep -q "failed gates" <<< "$pr11b"; then
    assert_fail "[SPEC-11b] no state_dir → must NOT append failed-gates line" "got: $pr11b"
else
    assert_pass "[SPEC-11b] no state_dir → no failed-gates line"
fi

# [SPEC-11c] MATCHED (converged) → no failed-gates line even if a stale artifact
# lingers (a pass must never be annotated with failures).
_CYCLE_LAST_PREDICATE_MATCH="true"
_CYCLE_LAST_PREDICATE_ACTUAL="pass"
pr11c="$(_cycle_render_predicate_result 2 "$_sd11" 2>/dev/null)"
if grep -q "failed gates" <<< "$pr11c"; then
    assert_fail "[SPEC-11c] MATCHED must NOT append failed-gates line" "got: $pr11c"
else
    assert_pass "[SPEC-11c] MATCHED → no failed-gates line"
fi
# Restore the NOT-MATCHED stash for the specs that follow.
_CYCLE_LAST_PREDICATE_KIND="exit_when"
_CYCLE_LAST_PREDICATE_STAGE="test_assessment"
_CYCLE_LAST_PREDICATE_ACTUAL="fail"
_CYCLE_LAST_PREDICATE_MATCH="false"
_CYCLE_LAST_FAILURE_COUNT=3

# ─── [SPEC-8] orphaned kind=cycle begin → finalizer writes NO .partial.json ──
# Sourcing stage-io into the runner's MAIN process arms _stage_io_orphan_finalizer
# for ALL kinds. A cycle that aborts BETWEEN the INPUT begin and the OUTPUT end
# leaves an unpaired pending key; the finalizer must emit the diagnostic event
# but MUST NOT write a file (SPEC-5 "NEVER file" must hold even on abnormal exit).
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
: > "$ZBUILD_EVENTS_JSONL"
# Begin directly (persist pending state) and intentionally NEVER pair an end.
ZBUILD_STAGE_IO_FD=2 stage_io_begin --kind cycle --stage build_test_cycle \
    --seq-label "1" --input "(orphaned — no end)" >/dev/null 2>&1
spec8_seq="$_STAGE_IO_LAST_SEQ"
# Invoke the finalizer directly (simulates the process EXIT trap firing).
_stage_io_orphan_finalizer 2>/dev/null || true
assert_file_not_exists "[SPEC-8] orphaned kind=cycle writes NO .partial.json" \
    "$ZBUILD_STATE_DIR/artifacts/stage-io/build_test_cycle-${spec8_seq}.partial.json"
spec8_count=0
if [[ -d "$ZBUILD_STATE_DIR/artifacts/stage-io" ]]; then
    # shellcheck disable=SC2012
    spec8_count=$(ls -1 "$ZBUILD_STATE_DIR/artifacts/stage-io" 2>/dev/null | wc -l | tr -d ' ')
fi
assert_eq "[SPEC-8] stage-io dir empty after orphaned kind=cycle finalize" "0" "$spec8_count"
# The diagnostic event still fires (forensics preserved; only the file is skipped).
assert_event_emitted "[SPEC-8] orphan finalizer still emits stage.io.error" \
    "$ZBUILD_EVENTS_JSONL" "stage.io.error"
# Clean the now-stale pending key so a later end-without-begin error can't leak.
unset '_STAGE_IO_PENDING[build_test_cycle:'"$spec8_seq"']' 2>/dev/null || true

# ─── [SPEC-9] non-matching abort_when leaves exit_when in the OUTPUT stash ────
# NOTE #2: on a normal/converged iter of a cycle with abort_when configured,
# the OUTPUT banner must show the exit_when evaluation, not abort_when's
# NOT MATCHED. _cycle_check_abort_when must only overwrite the stash on a match.
_CYCLE_TRAP_CYCLE_ID="build_test_cycle"
_CYCLE_TRAP_ITER=2
# Configure an abort_when that will NOT match this iter's verdicts.
export _TPL_CYCLE_ABORT_WHEN_STAGE_build_test_cycle="test_assessment"
export _TPL_CYCLE_ABORT_WHEN_FIELD_build_test_cycle="verdict"
export _TPL_CYCLE_ABORT_WHEN_OP_build_test_cycle="eq"
export _TPL_CYCLE_ABORT_WHEN_VALUE_build_test_cycle="corrupt_diff"
# Configure exit_when (the predicate that actually drives the iter).
_CYCLE_UNTIL_STAGE="test_assessment"
_CYCLE_UNTIL_FIELD="verdict"
_CYCLE_UNTIL_OP="eq"
_CYCLE_UNTIL_VALUE="pass"
spec9_blob='{"test_assessment":{"verdict":"fail","status":"failed"}}'
# Evaluate exit_when first (stashes exit_when NOT MATCHED got=fail), then
# abort_when (verdict=fail != corrupt_diff → NOT MATCHED → must NOT overwrite).
set +e
_cycle_check_until "$spec9_blob" >/dev/null 2>&1
_cycle_check_abort_when "$spec9_blob" >/dev/null 2>&1
set -e
assert_eq "[SPEC-9] non-matching abort_when leaves exit_when as stashed kind" \
    "exit_when" "$_CYCLE_LAST_PREDICATE_KIND"
assert_eq "[SPEC-9] stashed actual is exit_when's got=fail" \
    "fail" "$_CYCLE_LAST_PREDICATE_ACTUAL"
spec9_out="$(_cycle_render_predicate_result 2 2>/dev/null)"
assert_contains "[SPEC-9] OUTPUT renders exit_when (not abort_when)" "$spec9_out" "exit_when stage=test_assessment"
if grep -q "abort_when" <<< "$spec9_out"; then
    assert_fail "[SPEC-9] OUTPUT must NOT show abort_when on non-aborting iter" "got: $spec9_out"
else
    assert_pass "[SPEC-9] OUTPUT must NOT show abort_when on non-aborting iter"
fi
unset _TPL_CYCLE_ABORT_WHEN_STAGE_build_test_cycle _TPL_CYCLE_ABORT_WHEN_FIELD_build_test_cycle \
      _TPL_CYCLE_ABORT_WHEN_OP_build_test_cycle _TPL_CYCLE_ABORT_WHEN_VALUE_build_test_cycle

# ─── [SPEC-10] orchestrator call-site fd contract — banner survives stdout-only
# This is the production call-site simulation: ZBUILD_STAGE_IO_FD UNSET (so the
# fallback fd 2 is used) and the call wrapped with `>/dev/null` ONLY (stdout
# suppressed so the reserved seq doesn't leak — read from _STAGE_IO_LAST_SEQ).
# fd 2 must NOT be redirected: the banner writes to fd 2 and MUST reach the
# operator. The old `>/dev/null 2>&1` form sent fd 2 to /dev/null too, swallowing
# the banner in production — this spec fails against that form.
unset ZBUILD_STAGE_IO_FD 2>/dev/null || true
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
spec10_in_stdout="$TEST_TEMP_DIR/spec10.in.stdout"
spec10_in_stderr="$TEST_TEMP_DIR/spec10.in.stderr"
# INPUT begin: stdout→file (assert empty of banner), stderr→file (assert banner
# present). Match the orchestrator EXACTLY: `>/dev/null` only — but redirect to
# capture files instead of /dev/null so we can assert both channels.
stage_io_begin --kind cycle --stage build_test_cycle --seq-label "1" \
    --input "prior_test_assessment(fail, 3 changes)" \
    >"$spec10_in_stdout" 2>"$spec10_in_stderr" || true
spec10_seq="$_STAGE_IO_LAST_SEQ"
spec10_in_stdout_content="$(cat "$spec10_in_stdout")"
spec10_in_stderr_content="$(cat "$spec10_in_stderr")"
# Banner reached fd 2 (the WHOLE POINT of #833).
assert_contains "[SPEC-10] INPUT banner reaches fd 2 (production fallback)" \
    "$spec10_in_stderr_content" "[cycle]"
assert_contains "[SPEC-10] INPUT banner fd 2 carries the input digest" \
    "$spec10_in_stderr_content" "prior_test_assessment"
# stdout carried only the reserved seq (no banner leak into runner stream).
if grep -q '\[cycle\]' <<< "$spec10_in_stdout_content"; then
    assert_fail "[SPEC-10] INPUT banner must NOT leak into stdout" "got on stdout: ${spec10_in_stdout_content:0:80}"
else
    assert_pass "[SPEC-10] INPUT banner does NOT leak into stdout (only seq)"
fi

# OUTPUT end: symmetric — stderr must carry the banner, stdout must be empty.
spec10_out_stdout="$TEST_TEMP_DIR/spec10.out.stdout"
spec10_out_stderr="$TEST_TEMP_DIR/spec10.out.stderr"
stage_io_end --stage build_test_cycle --kind cycle --seq "$spec10_seq" \
    --output "exit_when stage=test_assessment field=verdict op=eq value=pass → NOT MATCHED (got=fail)
velocity=-3 failure_count=3" \
    >"$spec10_out_stdout" 2>"$spec10_out_stderr" || true
spec10_out_stdout_content="$(cat "$spec10_out_stdout")"
spec10_out_stderr_content="$(cat "$spec10_out_stderr")"
assert_contains "[SPEC-10] OUTPUT banner reaches fd 2 (production fallback)" \
    "$spec10_out_stderr_content" "[cycle]"
assert_contains "[SPEC-10] OUTPUT banner fd 2 carries the predicate eval" \
    "$spec10_out_stderr_content" "NOT MATCHED (got=fail)"
if [[ -z "$spec10_out_stdout_content" ]]; then
    assert_pass "[SPEC-10] OUTPUT end writes nothing to stdout"
else
    assert_fail "[SPEC-10] OUTPUT end writes nothing to stdout" "got on stdout: ${spec10_out_stdout_content:0:80}"
fi
# SPEC-5 still holds under the production fd: NO file artifact written.
assert_file_not_exists "[SPEC-10] no file artifact under production fd path" \
    "$ZBUILD_STATE_DIR/artifacts/stage-io/build_test_cycle-${spec10_seq}.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
