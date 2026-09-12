#!/usr/bin/env bash
# Tests: scripts/lib/shape-floor.sh (ADR-040, issue #1134, EPIC #1129)
# The un-gameable shape-floor check (extracted from the retired ablation logic, #971).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/shape-floor.sh — un-gameable shape floor (#1134)"
setup_test_env "shape-floor"

_test_cleanup_hook() { cleanup_test_env; }

_SHAPE_FLOOR_SH="$REPO_ROOT/scripts/lib/shape-floor.sh"

# ─── SPEC-1: sources cleanly ──────────────────────────────────────────────────

set +e
# shellcheck source=../../scripts/lib/shape-floor.sh
source "$_SHAPE_FLOOR_SH"
_spec1_rc=$?
set -e

assert_eq "[SPEC-1] shape-floor.sh sources without error" "0" "$_spec1_rc"

# ─── Shape floor tests — minimal temp repo ───────────────────────────────────
# Minimal repo with a controlled shape-change-paths.txt + golden file.
# ZBUILD_DIFF_CMD mocks the git diff output so no real git ops are needed.

_sr="$TEST_TEMP_DIR/shape-repo"
mkdir -p "$_sr/config" "$_sr/tests/golden/mytest"
printf 'config/templates/*.yaml\n' > "$_sr/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr/tests/golden/mytest/event-sequence.golden"

# ─── SPEC-2: shape floor SKIP — no shape-change file in diff ──────────────────
# Diff has no file matching shape-change-paths.txt → SHAPE_FLOOR SKIP.

set +e
_spec2_out="$(ZBUILD_DIFF_CMD="printf 'scripts/lib/helpers.sh\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-2] non-shape file in diff → SHAPE_FLOOR SKIP" \
    "$_spec2_out" "SHAPE_FLOOR SKIP no_shape_change"

# ─── SPEC-3: shape floor FAIL — shape-change file in diff, golden absent ──────
# Shape-change file detected but event-sequence.golden NOT in diff → FAIL.

set +e
_spec3_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-3] shape change without golden in diff → SHAPE_FLOOR FAIL" \
    "$_spec3_out" "SHAPE_FLOOR FAIL missing_floor_files"

# ─── SPEC-4: shape floor PASS — shape-change file + golden both in diff ───────
# Both shape-change file and golden file in diff (no _TPL_STAGES[N] files in this
# minimal repo) → PASS.

set +e
_spec4_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\ntests/golden/mytest/event-sequence.golden\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-4] shape change + golden in diff → SHAPE_FLOOR PASS" \
    "$_spec4_out" "SHAPE_FLOOR PASS"

# ─── SPEC-5: append-only event-schema.json → SHAPE_FLOOR SKIP ────────────────
# When config/event-schema.json is the SOLE shape-change match AND the diff has
# no removed lines, shape-floor treats it as no shape change (SKIP).
# CHANGE: fails at baseline (before _sf_is_schema_append_only exemption is wired).

_sr2="$TEST_TEMP_DIR/schema-append-repo"
mkdir -p "$_sr2/config" "$_sr2/tests/golden/mytest"
printf 'config/event-schema.json\n' > "$_sr2/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr2/tests/golden/mytest/event-sequence.golden"

set +e
_spec5_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD="printf '+  \"shape_floor.new_event\",\n'" \
    _sf_shape_floor "$_sr2")"
set -e

assert_contains "[SPEC-5] append-only known_types addition → SHAPE_FLOOR SKIP" \
    "$_spec5_out" "SHAPE_FLOOR SKIP"

# ─── SPEC-6 (GUARD): non-append-only schema diff → SHAPE_FLOOR FAIL ──────────
# When the event-schema.json diff has removed lines, the exemption must NOT fire.
# Golden file absent → FAIL (same as without the exemption).

set +e
_spec6_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD="printf '-  \"old.event\",\n+  \"new.event\",\n'" \
    _sf_shape_floor "$_sr2")"
set -e

assert_contains "[SPEC-6] non-append-only event-schema diff → SHAPE_FLOOR FAIL (not SKIP)" \
    "$_spec6_out" "SHAPE_FLOOR FAIL"

# ─── SPEC-5b: END-of-array append → SHAPE_FLOOR SKIP ────────────────────────
# Appending an element to the END of a JSON array forces a separator comma onto
# the previous last element, so git reports that line as removed AND re-added.
# SPEC-5 above only covers a MID-array insert (added line, nothing removed), so
# the exemption was structurally unreachable for the end-of-array shape every
# real event-schema.json append actually has. #1809's dogfood failed on it.
# CHANGE: fails at baseline (the old predicate rejected on ANY removed line).

set +e
_spec5b_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD="printf -- '-    \"stage.cleanup.failed\"\n+    \"stage.cleanup.failed\",\n+    \"stage.write_boundary.violated\"\n'" \
    _sf_shape_floor "$_sr2")"
set -e

assert_contains "[SPEC-5b] end-of-array append (comma on prior line) → SHAPE_FLOOR SKIP" \
    "$_spec5b_out" "SHAPE_FLOOR SKIP"

# ─── SPEC-6b (GUARD): a genuine deletion is still gated ─────────────────────
# The comma-only tolerance must not let a real removal through: an element
# deleted outright has no added line matching "<removed text>,".

set +e
_spec6b_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD="printf -- '-    \"deleted.event\",\n+    \"added.event\",\n'" \
    _sf_shape_floor "$_sr2")"
set -e

assert_contains "[SPEC-6b] outright deletion → SHAPE_FLOOR FAIL (comma tolerance not a loophole)" \
    "$_spec6b_out" "SHAPE_FLOOR FAIL"

# ─── SPEC-7 (GUARD): multiple shape-change files → exemption does not apply ───
# When event-schema.json AND another shape-change file are both in the diff, the
# append-only exemption must not suppress the floor check.

_sr3="$TEST_TEMP_DIR/multi-shape-repo"
mkdir -p "$_sr3/config" "$_sr3/tests/golden/mytest"
printf 'config/event-schema.json\nconfig/templates/*.yaml\n' > "$_sr3/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr3/tests/golden/mytest/event-sequence.golden"

set +e
_spec7_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\nconfig/templates/simple.yaml\n'" \
    ZBUILD_SCHEMA_DIFF_CMD="printf '+  \"shape_floor.new_event\",\n'" \
    _sf_shape_floor "$_sr3")"
set -e

assert_contains "[SPEC-7] multiple shape-change files → SHAPE_FLOOR FAIL (exemption not applied)" \
    "$_spec7_out" "SHAPE_FLOOR FAIL"

# ─── SPEC-2 (plugin): out-of-scope escalation → route_target=design ──────────
# When shape_floor_run finds ALL missing floor files outside the build's scope,
# it must write route_target=design into shape-floor-result.json.
# CHANGE: fails at baseline (before route_target injection in shape_floor_run).

_sr_oos="$TEST_TEMP_DIR/oos-plugin-repo"
mkdir -p "$_sr_oos/config" "$_sr_oos/tests/golden/oosspec"
printf 'config/templates/*.yaml\n' > "$_sr_oos/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr_oos/tests/golden/oosspec/event-sequence.golden"

_sf_art_oos="$TEST_TEMP_DIR/sf-oos-artifacts"
mkdir -p "$_sf_art_oos"

# shellcheck source=../../plugins/tool/shape-floor/plugin.sh
source "$REPO_ROOT/plugins/tool/shape-floor/plugin.sh"

set +e
ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
ZBUILD_SCHEMA_DIFF_CMD="" \
ZBUILD_SHAPE_FLOOR_SCOPE="scripts/lib/helpers.sh" \
ZBUILD_REPO_ROOT="$_sr_oos" \
ZBUILD_ARTIFACT_DIR="$_sf_art_oos" \
    shape_floor_run "shape-floor" ""
set -e

_sf_oos_result="$_sf_art_oos/shape-floor-result.json"
_sf_oos_rt=""
[[ -f "$_sf_oos_result" ]] \
    && _sf_oos_rt="$(jq -r '.fault // empty' "$_sf_oos_result" 2>/dev/null)"

# #1987: the gate declares the KIND of fault — the boundary is wrong — and the
# template maps that class to a destination. It no longer names `design`, which
# would be meaningless in a flow without a design stage.
assert_eq "[SPEC-2] out-of-scope missing floor files → fault=scope in artifact" \
    "scope" "$_sf_oos_rt"

# ─── SPEC-8 (GUARD): additive but STRUCTURAL schema change → FAIL, not SKIP ──
# The append-only exemption covers known_types entries only. A diff that adds a
# new object KEY removes no lines, so a removals-only test would exempt it — but
# a structural schema addition can change pipeline shape and must stay gated.

set +e
_spec8_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD='printf "+  \"required_stages\": [\"build\",\"test\"],\n"' \
    _sf_shape_floor "$_sr2")"
set -e

assert_contains "[SPEC-8] additive structural schema key → SHAPE_FLOOR FAIL (exemption is known_types-only)" \
    "$_spec8_out" "SHAPE_FLOOR FAIL"

# ─── SPEC-10 (GUARD): one file matching TWO globs is still a sole match ─────
# _matched_files accumulates one entry per (pattern, file) hit. A single file
# matching two globs must not inflate the count and disable the exemption —
# "sole match" is about distinct files, not pattern hits.

_sr4="$TEST_TEMP_DIR/dup-pattern-repo"
mkdir -p "$_sr4/config" "$_sr4/tests/golden/mytest"
printf 'config/event-schema.json\nconfig/*.json\n' > "$_sr4/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr4/tests/golden/mytest/event-sequence.golden"

set +e
_spec10_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD='printf "+  \"shape_floor.new_event\",\n"' \
    _sf_shape_floor "$_sr4")"
set -e

assert_contains "[SPEC-10] one file matching two shape globs → SHAPE_FLOOR SKIP (dedup before counting)" \
    "$_spec10_out" "SHAPE_FLOOR SKIP"

# ─── SPEC-9 (GUARD): missing floor files IN scope → fail, NO route_target ────
# Escalation is for demands build cannot legally satisfy. When the missing floor
# file IS in build's scope, build owns the fix and the gate must stay a plain
# fail — routing back to design would rewind for work build can already do.
# (This is the design's SPEC-3; tagged SPEC-9 because [SPEC-3] is already taken
# in this file by an unrelated pre-existing assertion — see #1670.)

_sf_art_ins="$TEST_TEMP_DIR/sf-inscope-artifacts"
mkdir -p "$_sf_art_ins"

set +e
ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
ZBUILD_SCHEMA_DIFF_CMD="" \
ZBUILD_SHAPE_FLOOR_SCOPE="tests/golden/oosspec/event-sequence.golden" \
ZBUILD_REPO_ROOT="$_sr_oos" \
ZBUILD_ARTIFACT_DIR="$_sf_art_ins" \
    shape_floor_run "shape-floor" ""
set -e

_sf_ins_result="$_sf_art_ins/shape-floor-result.json"
_sf_ins_rt="absent"; _sf_ins_verdict=""
if [[ -f "$_sf_ins_result" ]]; then
    _sf_ins_verdict="$(jq -r '.verdict // empty' "$_sf_ins_result" 2>/dev/null)"
    _sf_ins_rt="$(jq -r 'if has("route_target") then .route_target else "absent" end' \
        "$_sf_ins_result" 2>/dev/null)"
fi

assert_eq "[SPEC-9] in-scope missing floor file → verdict=fail" \
    "fail" "$_sf_ins_verdict"
assert_eq "[SPEC-9] in-scope missing floor file → no route_target field" \
    "absent" "$_sf_ins_rt"

# ─── SPEC-11 (GUARD): the fail EVENT names the failure the same as the artifact
# The artifact writes `reason`; the event must not call the same value `detail`.
# Captured by stubbing eb_emit_event (which _sf_emit dispatches to when defined)
# rather than grepping the source — a source grep would pass on a comment.

_sf_ev_capture="$TEST_TEMP_DIR/sf-events.txt"
: > "$_sf_ev_capture"
eb_emit_event() { printf '%s\n' "$*" >> "$_sf_ev_capture"; }

_sf_art_ev="$TEST_TEMP_DIR/sf-event-artifacts"
mkdir -p "$_sf_art_ev"

set +e
ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
ZBUILD_SCHEMA_DIFF_CMD="" \
ZBUILD_SHAPE_FLOOR_SCOPE="" \
ZBUILD_SCOPE_ALLOWLIST="" \
ZBUILD_REPO_ROOT="$_sr_oos" \
ZBUILD_ARTIFACT_DIR="$_sf_art_ev" \
    shape_floor_run "shape-floor" ""
set -e
unset -f eb_emit_event

_sf_fail_ev="$(grep '^shape_floor.fail' "$_sf_ev_capture" 2>/dev/null || true)"
_sf_art_reason="$(jq -r '.reason // empty' "$_sf_art_ev/shape-floor-result.json" 2>/dev/null)"

# Pin the interpolated value first: an empty _sf_art_reason would silently reduce
# the assertion below to "the line contains 'reason='", which a value mismatch
# would then pass. The guard must not be able to weaken into a tautology.
assert_eq "[SPEC-11] artifact carries a non-empty reason (pins the comparison below)" \
    "missing_floor_files" "$_sf_art_reason"

assert_contains "[SPEC-11] shape_floor.fail event names the failure 'reason=', matching the artifact" \
    "$_sf_fail_ev" "reason=$_sf_art_reason"

# ─── SPEC-12 (#1924): comment-only template diff → SHAPE_FLOOR SKIP ──────────
# `config/templates/*.yaml` matches on FILENAME, so adding a block of env-var
# documentation to a template demanded edits to seven golden/order-assertion
# files. That kept the floor red on a change that cannot move a stage, and its
# out-of-scope escalation then set route_target=design — the route that made the
# gate-aggregator suppress build's feedback (issue #1831's run).
_sr4="$TEST_TEMP_DIR/tpl-comment-repo"
mkdir -p "$_sr4/config" "$_sr4/tests/golden/mytest"
printf 'config/templates/*.yaml\n' > "$_sr4/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr4/tests/golden/mytest/event-sequence.golden"

set +e
_spec12_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/clean.yaml\n'" \
    ZBUILD_TEMPLATE_DIFF_CMD="printf -- '--- a/config/templates/clean.yaml\n+++ b/config/templates/clean.yaml\n+# ZBUILD_TEARDOWN_SCOPE   release (default) | purge\n+\n-# the old note\n'" \
    _sf_shape_floor "$_sr4")"
set -e

assert_contains "[SPEC-12] comment-only template diff → SHAPE_FLOOR SKIP" \
    "$_spec12_out" "SHAPE_FLOOR SKIP template_comment_only"

# ─── SPEC-13 (GUARD): a real template edit is still gated ────────────────────
# One added non-comment line — a stage entry — must drop through to the floor
# check. This is the assertion that keeps SPEC-12 from becoming a blanket
# exemption for `config/templates/*.yaml`.
set +e
_spec13_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/clean.yaml\n'" \
    ZBUILD_TEMPLATE_DIFF_CMD="printf -- '--- a/config/templates/clean.yaml\n+++ b/config/templates/clean.yaml\n+# a comment\n+  - teardown\n'" \
    _sf_shape_floor "$_sr4")"
set -e

assert_contains "[SPEC-13] template diff with a real line → SHAPE_FLOOR FAIL (not SKIP)" \
    "$_spec13_out" "SHAPE_FLOOR FAIL missing_floor_files"

# ─── SPEC-14 (GUARD): a removed stage line is gated too ──────────────────────
# Deletions drift the shape exactly as additions do; the `-` side must be read.
set +e
_spec14_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/clean.yaml\n'" \
    ZBUILD_TEMPLATE_DIFF_CMD="printf -- '--- a/config/templates/clean.yaml\n+++ b/config/templates/clean.yaml\n-  - teardown\n+# replaced by a comment\n'" \
    _sf_shape_floor "$_sr4")"
set -e

assert_contains "[SPEC-14] removed stage line → SHAPE_FLOOR FAIL (not SKIP)" \
    "$_spec14_out" "SHAPE_FLOOR FAIL missing_floor_files"

# ─── SPEC-15 (GUARD): a non-template match defeats the exemption ─────────────
# The exemption is per-file but all-or-nothing: one matched file that is not a
# comment-only template returns the whole change to the floor check.
_sr5="$TEST_TEMP_DIR/tpl-mixed-repo"
mkdir -p "$_sr5/config" "$_sr5/tests/golden/mytest"
printf 'config/templates/*.yaml\ncore/pipeline/runner.sh\n' > "$_sr5/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr5/tests/golden/mytest/event-sequence.golden"

set +e
_spec15_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/clean.yaml\ncore/pipeline/runner.sh\n'" \
    ZBUILD_TEMPLATE_DIFF_CMD="printf -- '--- a/x\n+++ b/x\n+# just a comment\n'" \
    _sf_shape_floor "$_sr5")"
set -e

assert_contains "[SPEC-15] comment-only template + a real shape file → SHAPE_FLOOR FAIL" \
    "$_spec15_out" "SHAPE_FLOOR FAIL missing_floor_files"

# ─── SPEC-16 (GUARD): an empty template diff is not an exemption ─────────────
# No diff means the check could not read the file; fail closed rather than
# treating "nothing to see" as proof of innocence.
set +e
_spec16_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/clean.yaml\n'" \
    ZBUILD_TEMPLATE_DIFF_CMD="printf ''" \
    _sf_shape_floor "$_sr4")"
set -e

assert_contains "[SPEC-16] unreadable/empty template diff → SHAPE_FLOOR FAIL (fail-closed)" \
    "$_spec16_out" "SHAPE_FLOOR FAIL missing_floor_files"

# ─── #2064: "I could not check" is not "I checked and found nothing" ─────────
# Every SPEC above drives the gate through ZBUILD_DIFF_CMD, which hands it a
# diff and so never exercises baseline resolution at all. SPEC-17/18/19 use REAL
# git repos with no override, because the defect lives entirely in the path the
# override skips: when zbuild_resolve_merge_base returns empty, _sf_diff_files
# prints nothing, nothing matches, and the gate reported `no_shape_change` — a
# claim about a diff it never saw.

_sf_git_id() {
    git -C "$1" config user.email "test@zbuild.local"
    git -C "$1" config user.name  "Test"
    git -C "$1" config commit.gpgsign false
}

# _sf_mk_floor_repo <dir> <initial-branch> — a minimal shape-floor repo carrying
# one commit: shape-change-paths.txt, a golden, and a template. No remote, so the
# caller decides whether a trunk (and therefore a baseline) resolves at all.
_sf_mk_floor_repo() {
    local dir="$1" branch="$2"
    mkdir -p "$dir/config/templates" "$dir/tests/golden/mytest" "$dir/scripts/lib"
    git -C "$dir" init -q -b "$branch"
    _sf_git_id "$dir"
    printf 'config/templates/*.yaml\n' > "$dir/config/shape-change-paths.txt"
    printf 'golden-event-content\n' > "$dir/tests/golden/mytest/event-sequence.golden"
    printf 'stages:\n  - build\n' > "$dir/config/templates/simple.yaml"
    printf 'helper\n' > "$dir/scripts/lib/helpers.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "baseline"
}

# ─── SPEC-17 (#2064): unresolvable baseline → SKIP no_baseline ───────────────
# Trunk cannot be resolved (no origin, no main/master), so the resolver returns
# EMPTY — the one input that reaches this branch. The shape-change commit is
# real: were a baseline available, this diff WOULD be a shape change, so a
# `no_shape_change` answer here is not merely unhelpful, it is false.

_sr_nb="$TEST_TEMP_DIR/no-baseline-repo"
_sf_mk_floor_repo "$_sr_nb" "feat/work"
printf 'stages:\n  - build\n  - test\n' > "$_sr_nb/config/templates/simple.yaml"
git -C "$_sr_nb" add -A
git -C "$_sr_nb" commit -q -m "add a stage — a real shape change"

# Preconditions. Without these the SPEC is vacuous: it would pass on a fixture
# that simply had nothing to resolve for uninteresting reasons.
if [[ -z "$(zbuild_resolve_default_branch "$_sr_nb")" ]]; then
    assert_pass "[SPEC-17] precondition: no trunk resolves in the fixture"
else
    assert_fail "[SPEC-17] precondition: trunk must be unresolvable" \
        "got '$(zbuild_resolve_default_branch "$_sr_nb")'"
fi
assert_eq "[SPEC-17] precondition: zbuild_resolve_merge_base returns EMPTY" \
    "" "$(zbuild_resolve_merge_base "$_sr_nb")"
if git -C "$_sr_nb" rev-parse --verify 'HEAD~1' >/dev/null 2>&1; then
    assert_pass "[SPEC-17] precondition: HEAD~1 exists (there IS a prior commit to have seen)"
else
    assert_fail "[SPEC-17] precondition: HEAD~1 must exist" "did not verify"
fi

set +e
_spec17_out="$(ZBUILD_DIFF_CMD="" _sf_shape_floor "$_sr_nb")"
set -e

assert_contains "[SPEC-17] unresolvable baseline → SHAPE_FLOOR SKIP no_baseline" \
    "$_spec17_out" "SHAPE_FLOOR SKIP no_baseline"
# The positive assertion alone would pass an implementation that printed both
# reasons, or that appended the new one to the old line.
if [[ "$_spec17_out" == *"no_shape_change"* ]]; then
    assert_fail "[SPEC-17] must not claim no_shape_change about a diff it never saw" \
        "$_spec17_out"
else
    assert_pass "[SPEC-17] no_shape_change is NOT reported for an unresolvable baseline"
fi

# ─── SPEC-18 (GUARD, #2064): a resolvable baseline still reports the diff ────
# The other direction. Without this, an implementation that reported no_baseline
# unconditionally would satisfy SPEC-17.

_sr_ok="$TEST_TEMP_DIR/baseline-nonshape-repo"
_sf_mk_floor_repo "$_sr_ok" "main"
git -C "$_sr_ok" checkout -q -b feat/nonshape
printf 'helper v2\n' > "$_sr_ok/scripts/lib/helpers.sh"
git -C "$_sr_ok" add -A
git -C "$_sr_ok" commit -q -m "touch a non-shape file only"

if [[ -n "$(zbuild_resolve_merge_base "$_sr_ok")" ]]; then
    assert_pass "[SPEC-18] precondition: a baseline DOES resolve here"
else
    assert_fail "[SPEC-18] precondition: baseline must resolve" "got empty"
fi

set +e
_spec18_out="$(ZBUILD_DIFF_CMD="" _sf_shape_floor "$_sr_ok")"
set -e

assert_contains "[SPEC-18] resolved baseline + non-shape diff → SHAPE_FLOOR SKIP no_shape_change" \
    "$_spec18_out" "SHAPE_FLOOR SKIP no_shape_change"
if [[ "$_spec18_out" == *"no_baseline"* ]]; then
    assert_fail "[SPEC-18] must not report no_baseline when a baseline resolved" \
        "$_spec18_out"
else
    assert_pass "[SPEC-18] no_baseline is NOT reported when a baseline resolved"
fi

# ─── SPEC-19 (GUARD, #2064): an EMPTY diff off a resolved baseline ──────────
# The sharp discriminator. SPEC-17 and this case produce the IDENTICAL input to
# every line below _sf_diff_files — zero changed files. Only the baseline tells
# them apart, so an implementation that keyed the new reason off "diff came back
# empty" rather than off the resolver passes SPEC-17/18 and fails here.

_sr_empty="$TEST_TEMP_DIR/baseline-emptydiff-repo"
_sf_mk_floor_repo "$_sr_empty" "main"
git -C "$_sr_empty" checkout -q -b feat/nothing

_sf_empty_base="$(zbuild_resolve_merge_base "$_sr_empty")"
if [[ -n "$_sf_empty_base" ]]; then
    assert_pass "[SPEC-19] precondition: a baseline resolves"
else
    assert_fail "[SPEC-19] precondition: baseline must resolve" "got empty"
fi
assert_eq "[SPEC-19] precondition: the diff really is empty (same input as SPEC-17)" \
    "" "$(git -C "$_sr_empty" diff --name-only "$_sf_empty_base" HEAD)"

set +e
_spec19_out="$(ZBUILD_DIFF_CMD="" _sf_shape_floor "$_sr_empty")"
set -e

assert_contains "[SPEC-19] resolved baseline + empty diff → SHAPE_FLOOR SKIP no_shape_change" \
    "$_spec19_out" "SHAPE_FLOOR SKIP no_shape_change"
if [[ "$_spec19_out" == *"no_baseline"* ]]; then
    assert_fail "[SPEC-19] an empty diff is not an absent baseline" "$_spec19_out"
else
    assert_pass "[SPEC-19] an empty diff off a resolved baseline is still no_shape_change"
fi

# ─── SPEC-20 (#2064): the artifact carries the honest reason downstream ─────
# The reason is only worth changing if it survives into shape-floor-result.json,
# which is what every downstream consumer actually reads.

_sf_art_nb="$TEST_TEMP_DIR/sf-nb-artifacts"
mkdir -p "$_sf_art_nb"

set +e
ZBUILD_DIFF_CMD="" \
ZBUILD_SCHEMA_DIFF_CMD="" \
ZBUILD_SHAPE_FLOOR_SCOPE="" \
ZBUILD_REPO_ROOT="$_sr_nb" \
ZBUILD_ARTIFACT_DIR="$_sf_art_nb" \
    shape_floor_run "shape-floor" ""
set -e

_sf_nb_result="$_sf_art_nb/shape-floor-result.json"
assert_eq "[SPEC-20] artifact verdict stays the declared 'skip'" \
    "skip" "$(jq -r '.verdict // empty' "$_sf_nb_result" 2>/dev/null)"
assert_eq "[SPEC-20] artifact reason is no_baseline, not no_shape_change" \
    "no_baseline" "$(jq -r '.reason // empty' "$_sf_nb_result" 2>/dev/null)"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
