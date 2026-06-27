#!/usr/bin/env bash
# Tests: scripts/lib/plan-context.sh — durable plan-context cache + envelope
# recovery (#1052, EPIC #966 Phase 1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/plan-context.sh
source "$REPO_ROOT/scripts/lib/plan-context.sh"

print_test_header "plan-context lib (#1052)"

setup_test_env "zb-plan-context"
export ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/plan-context"
export ZBUILD_RUN_ID="run-test-0001"
export ZBUILD_PLAN_RESUME=1
export ZBUILD_PLAN_CONTEXT_GC=1

REPO_ID="$(plan_context_repo_id)"

# ─── [SPEC-1] write produces namespaced json+md; status round-trips ──────────
GOAL="implement the resumable plan context cache"
GH="$(plan_context_goal_hash "$GOAL")"
SCOPE_KEY="1052"
SCOPE_REF="abc123scoperef"

out_json="$(plan_context_write "$GH" "$SCOPE_KEY" "complete" 7 "explored core/plan" "$SCOPE_REF")"
json_path="$(plan_context_path "$REPO_ID" "$SCOPE_KEY" "$GH")"
md_path="$(plan_context_md_path "$REPO_ID" "$SCOPE_KEY" "$GH")"

assert_file_exists "[SPEC-1] write creates namespaced json" "$json_path"
assert_file_exists "[SPEC-1] write creates namespaced md" "$md_path"
assert_contains "[SPEC-1] write echoes json to stdout" "$out_json" '"schema_version": 1'
assert_json_key "[SPEC-1] json goal_hash field" "$(cat "$json_path")" ".goal_hash" "$GH"
assert_json_key "[SPEC-1] json status round-trips" "$(cat "$json_path")" ".status" "complete"
assert_json_key "[SPEC-1] json num_turns is int" "$(cat "$json_path")" ".num_turns" "7"
assert_json_key "[SPEC-1] json scope_manifest_ref" "$(cat "$json_path")" ".scope_manifest_ref" "$SCOPE_REF"
assert_json_key "[SPEC-1] json repo_id embedded" "$(cat "$json_path")" ".repo_id" "$REPO_ID"
assert_json_key "[SPEC-1] json run_id embedded" "$(cat "$json_path")" ".run_id" "$ZBUILD_RUN_ID"
assert_json_key "[SPEC-1] complete → candidate_split false" "$(cat "$json_path")" ".candidate_split" "false"
assert_contains "[SPEC-1] md banner has accumulated exploration" "$(cat "$md_path")" "Accumulated exploration"
assert_contains "[SPEC-1] md banner carries reasoning" "$(cat "$md_path")" "explored core/plan"

# scope_too_large → candidate_split true, num_turns null when non-numeric
out2="$(plan_context_write "$GH" "stl-key" "scope_too_large" "" "ran out of turns" "$SCOPE_REF")"
assert_json_key "[SPEC-1] scope_too_large → candidate_split true" "$out2" ".candidate_split" "true"
assert_json_key "[SPEC-1] non-numeric num_turns → null" "$out2" ".num_turns" "null"
assert_json_key "[SPEC-1] scope_too_large status round-trips" "$out2" ".status" "scope_too_large"

# ─── [SPEC-2] read_for_resume match / refusals ──────────────────────────────
# Seed an incomplete (resumable) context.
plan_context_write "$GH" "$SCOPE_KEY" "scope_too_large" 12 "PRIOR-EXPLORATION-TOKEN" "$SCOPE_REF" >/dev/null

set +e
resume_out="$(plan_context_read_for_resume "$REPO_ID" "$SCOPE_KEY" "$GH" "$SCOPE_REF")"; resume_rc=$?
set -e
assert_eq "[SPEC-2] resume returns rc=0 on full match" "0" "$resume_rc"
assert_contains "[SPEC-2] resume returns prior reasoning" "$resume_out" "PRIOR-EXPLORATION-TOKEN"

# goal_hash mismatch
set +e
plan_context_read_for_resume "$REPO_ID" "$SCOPE_KEY" "deadbeefnope" "$SCOPE_REF" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-2] refuse on goal_hash mismatch" "1" "$rc"

# repo_id mismatch
set +e
plan_context_read_for_resume "OTHER_REPO_ID" "$SCOPE_KEY" "$GH" "$SCOPE_REF" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-2] refuse on repo_id mismatch" "1" "$rc"

# scope_ref mismatch
set +e
plan_context_read_for_resume "$REPO_ID" "$SCOPE_KEY" "$GH" "DIFFERENT_REF" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-2] refuse on scope_ref mismatch" "1" "$rc"

# status=complete refuses (re-seed as complete)
plan_context_write "$GH" "complete-key" "complete" 3 "done" "$SCOPE_REF" >/dev/null
set +e
plan_context_read_for_resume "$REPO_ID" "complete-key" "$GH" "$SCOPE_REF" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-2] refuse when status=complete" "1" "$rc"

# ZBUILD_PLAN_RESUME=0 disables resume
set +e
ZBUILD_PLAN_RESUME=0 plan_context_read_for_resume "$REPO_ID" "$SCOPE_KEY" "$GH" "$SCOPE_REF" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-2] refuse when ZBUILD_PLAN_RESUME=0" "1" "$rc"

# ─── [SPEC-4] _plan_recover_envelope_json ───────────────────────────────────
# Single schema-bearer amid prose → recovered.
single_raw='Here is my plan:
{"schema_version":1,"steps":["a","b"]}
Thanks!'
set +e
rec="$(_plan_recover_envelope_json "$single_raw")"; rc=$?
set -e
assert_eq "[SPEC-4] recover single schema-bearer rc=0" "0" "$rc"
assert_json_key "[SPEC-4] recovered object has steps" "$rec" ".steps | length" "2"

# Two schema-bearers → fail closed.
two_raw='Example: {"schema_version":1,"steps":["x"]}
Real: {"schema_version":1,"steps":["y","z"]}'
set +e
_plan_recover_envelope_json "$two_raw" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-4] fail closed on two schema-bearers" "1" "$rc"

# Missing steps[] → rejected.
nosteps_raw='{"schema_version":1,"notes":"no steps here"}'
set +e
_plan_recover_envelope_json "$nosteps_raw" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-4] reject object missing steps[]" "1" "$rc"

# Empty steps[] → rejected by schema gate.
emptysteps_raw='{"schema_version":1,"steps":[]}'
set +e
_plan_recover_envelope_json "$emptysteps_raw" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-4] reject empty steps[]" "1" "$rc"

# Schema predicate directly.
set +e
_plan_envelope_schema_ok '{"schema_version":1,"steps":["a"]}'; rc=$?
set -e
assert_eq "[SPEC-4] _plan_envelope_schema_ok accepts valid" "0" "$rc"
set +e
_plan_envelope_schema_ok '{"schema_version":2,"steps":["a"]}'; rc=$?
set -e
assert_eq "[SPEC-4] _plan_envelope_schema_ok rejects wrong version" "1" "$rc"

# ─── [SPEC-4] sidecar reasoning recovery ────────────────────────────────────
ART_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ART_DIR/stage-io"
cat > "$ART_DIR/stage-io/plan-sync-error.raw-claude-output.json" <<'JSON'
{"is_error":true,"subtype":"error_max_turns","num_turns":25,
 "result":"I explored the repo and started drafting steps",
 "tool_uses":[{"input":{"file_path":"core/plan/x.sh"}}]}
JSON
side="$(plan_context_recover_sidecar_reasoning plan "$ART_DIR")"
assert_contains "[SPEC-4] sidecar reasoning has num_turns" "$side" "num_turns: 25"
assert_contains "[SPEC-4] sidecar reasoning has partial result" "$side" "drafting steps"
assert_contains "[SPEC-4] sidecar reasoning lists explored file" "$side" "core/plan/x.sh"

# Absent sidecar → empty, rc=0.
empty_art="$TEST_TEMP_DIR/empty-artifacts"
mkdir -p "$empty_art/stage-io"
side_empty="$(plan_context_recover_sidecar_reasoning plan "$empty_art")"
assert_eq "[SPEC-4] absent sidecar → empty reasoning" "" "$side_empty"

# ─── [SPEC-5] collision: same goal_hash, different repo_id ──────────────────
SHARED_GOAL="byte identical issue text"
SGH="$(plan_context_goal_hash "$SHARED_GOAL")"
# Write under the real repo_id and under a synthetic foreign repo_id via path.
plan_context_write "$SGH" "9999" "scope_too_large" 5 "REPO-A-REASONING" "refA" >/dev/null
real_path="$(plan_context_path "$REPO_ID" "9999" "$SGH")"
foreign_path="$(plan_context_path "FOREIGN_REPO" "9999" "$SGH")"
# Manually seed a foreign-repo entry to prove paths never collide.
mkdir -p "$(dirname "$foreign_path")"
printf '%s\n' '{"schema_version":1,"goal_hash":"'"$SGH"'","scope_manifest_ref":"refA","status":"scope_too_large","repo_id":"FOREIGN_REPO","scope_key":"9999","partial_reasoning":"REPO-B-REASONING","num_turns":5,"candidate_split":true,"run_id":"x","branch":"y","created_at":"z"}' > "$foreign_path"

assert_eq "[SPEC-5] distinct repo_ids → distinct paths" "false" "$([[ "$real_path" == "$foreign_path" ]] && echo true || echo false)"
# Resume under real repo never returns the foreign reasoning.
res_real="$(plan_context_read_for_resume "$REPO_ID" "9999" "$SGH" "refA")"
assert_contains "[SPEC-5] real repo resumes own reasoning" "$res_real" "REPO-A-REASONING"
assert_eq "[SPEC-5] real repo never leaks foreign reasoning" "false" "$(grep -qF 'REPO-B-REASONING' <<<"$res_real" && echo true || echo false)"
# Foreign repo_id never resolves against the real entry.
set +e
plan_context_read_for_resume "FOREIGN_REPO" "9999" "$SGH" "refA" >/dev/null
# (matches the seeded foreign entry — that's fine; the point is cross-repo isolation)
plan_context_read_for_resume "REPO_NEVER_WRITTEN" "9999" "$SGH" "refA" >/dev/null; rc=$?
set -e
assert_eq "[SPEC-5] unknown repo_id → no resume" "1" "$rc"

# ─── [SPEC-5] atomic write leaves no torn temp ─────────────────────────────
plan_context_write "$GH" "atomic-key" "complete" 2 "atomic body" "refX" >/dev/null
atomic_json="$(plan_context_path "$REPO_ID" "atomic-key" "$GH")"
# No leftover PID/run-scoped temp files in the namespace dir.
leftover="$(find "$(dirname "$atomic_json")" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-5] no torn temp file left behind" "0" "$leftover"
assert_eq "[SPEC-5] final file is valid json" "0" "$(jq empty "$atomic_json" >/dev/null 2>&1 && echo 0 || echo 1)"

# ─── gc: retains scope_too_large, prunes old complete beyond max-entries ────
GC_DIR="$TEST_TEMP_DIR/gc-cache"
export ZBUILD_PLAN_CONTEXT_DIR="$GC_DIR"
GC_NS="$GC_DIR/$REPO_ID/gckey"
mkdir -p "$GC_NS"
# 3 complete + 1 scope_too_large; max-entries=1 should keep newest + the stl.
for i in 1 2 3; do
    printf '%s\n' '{"schema_version":1,"status":"complete","goal_hash":"g'"$i"'"}' > "$GC_NS/complete$i.json"
    printf 'md\n' > "$GC_NS/complete$i.md"
done
printf '%s\n' '{"schema_version":1,"status":"scope_too_large","goal_hash":"gstl"}' > "$GC_NS/stl.json"
printf 'md\n' > "$GC_NS/stl.md"
# Make complete1 oldest, complete3 newest via touch.
touch -t 202001010000 "$GC_NS/complete1.json"
touch -t 202001020000 "$GC_NS/complete2.json"
touch -t 202501010000 "$GC_NS/complete3.json"
touch -t 202501020000 "$GC_NS/stl.json"

ZBUILD_PLAN_CONTEXT_MAX_ENTRIES=1 ZBUILD_PLAN_CONTEXT_RETAIN_DAYS=99999 plan_context_gc

assert_file_exists "[SPEC-gc] retains scope_too_large past cap" "$GC_NS/stl.json"
assert_file_exists "[SPEC-gc] keeps newest complete (complete3)" "$GC_NS/complete3.json"
assert_file_not_exists "[SPEC-gc] prunes oldest complete (complete1)" "$GC_NS/complete1.json"

# gc disabled by ZBUILD_PLAN_CONTEXT_GC=0
printf '%s\n' '{"schema_version":1,"status":"complete"}' > "$GC_NS/extra.json"
touch -t 200001010000 "$GC_NS/extra.json"
ZBUILD_PLAN_CONTEXT_GC=0 ZBUILD_PLAN_CONTEXT_RETAIN_DAYS=0 plan_context_gc
assert_file_exists "[SPEC-gc] no-op when ZBUILD_PLAN_CONTEXT_GC=0" "$GC_NS/extra.json"

export ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/plan-context"

print_test_results
