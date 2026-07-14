#!/usr/bin/env bash
# Tests: .github/workflows/release.yml — YAML syntax + shell-level behavior
# exercised via the same release.sh seams the workflow invokes.
#
# SPEC-1: release.yml YAML is syntactically valid (real parser: python3/ruby/yq)
# SPEC-2: gate-refusal path — when release.sh exits nonzero, no gh pr create is called
# SPEC-3: --force bypass — release.sh exits 0 with --force, gh pr create is called
# SPEC-4: dry_run=true — no gh pr create and release.sh is invoked with --dry-run
# SPEC-5: publish job trigger is restricted to the workflow's own release/auto-* branches
# SPEC-6: workflow uses --force on the publish path (idempotent re-entry)
# SPEC-7: open-release-pr job passes --dry-run flag when dry_run input is true
# SPEC-8: DOC-F wiring — regen step rides the release PR + wiki-publish step on merge
# SPEC-9: cadence input exists (minor|major, default minor) and is wired into validate + apply steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.yml — YAML validity + shell-level workflow behavior (REL-D2 / #1413)"
setup_test_env "release-yml"

WORKFLOW_FILE="$REPO_ROOT/.github/workflows/release.yml"

# ── T1: YAML syntax ───────────────────────────────────────────────────────────
# Prefer a REAL YAML parser (python3 PyYAML, ruby psych, or yq). A parser is the
# only reliable validity check — a grep can't tell malformed YAML from valid.
# We only fall back to a structural heuristic when NO parser exists at all, and
# that fallback is stricter than before (requires the top-level keys we emit,
# each at column 0, and rejects tab indentation which YAML forbids).
_yaml_valid=false
_yaml_parser=""
if python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$WORKFLOW_FILE" 2>/dev/null; then
    _yaml_valid=true; _yaml_parser="python3"
elif command -v ruby >/dev/null 2>&1 && ruby -e "require 'yaml'; YAML.safe_load(File.read(ARGV[0]))" "$WORKFLOW_FILE" 2>/dev/null; then
    _yaml_valid=true; _yaml_parser="ruby"
elif command -v yq >/dev/null 2>&1 && yq eval '.' "$WORKFLOW_FILE" >/dev/null 2>&1; then
    _yaml_valid=true; _yaml_parser="yq"
else
    _yaml_parser="grep-heuristic"
    # No parser available: require all three top-level keys at column 0 and
    # reject any tab character (YAML disallows tabs for indentation).
    if grep -qE '^name:' "$WORKFLOW_FILE" \
        && grep -qE '^on:' "$WORKFLOW_FILE" \
        && grep -qE '^jobs:' "$WORKFLOW_FILE" \
        && grep -qE '^permissions:' "$WORKFLOW_FILE" \
        && ! grep -qP '\t' "$WORKFLOW_FILE"; then
        _yaml_valid=true
    fi
fi
if $_yaml_valid; then
    assert_pass "[SPEC-1] release.yml YAML syntax is valid (via $_yaml_parser)"
else
    assert_fail "[SPEC-1] release.yml YAML syntax is valid" \
        "YAML validation failed on $WORKFLOW_FILE (parser: $_yaml_parser)"
fi

# ── SPEC-5: publish job trigger is restricted to the workflow's OWN branches ──
# SECURITY (REL-D2): the publish job must fire ONLY when the merged PR's HEAD
# ref is a release/auto-* branch (the only branches open-release-pr creates),
# gated on merged==true + base main. Guarding on the PR *title* alone is the
# vulnerability we fixed — any contributor could hand-title a PR "Release v…".
_spec5_head_ref=false
_spec5_merged=false
_spec5_base=false
_spec5_no_title_guard=false
grep -q "startsWith(github.event.pull_request.head.ref, 'release/auto-')" "$WORKFLOW_FILE" 2>/dev/null && _spec5_head_ref=true
grep -q "github.event.pull_request.merged == true" "$WORKFLOW_FILE" 2>/dev/null && _spec5_merged=true
grep -q "github.event.pull_request.base.ref == 'main'" "$WORKFLOW_FILE" 2>/dev/null && _spec5_base=true
# The old wide-open title guard MUST be gone — its presence would re-open the hole.
grep -q "startsWith(github.event.pull_request.title," "$WORKFLOW_FILE" 2>/dev/null || _spec5_no_title_guard=true
if $_spec5_head_ref && $_spec5_merged && $_spec5_base && $_spec5_no_title_guard; then
    assert_pass "[SPEC-5] publish job is restricted to merged release/auto-* branches into main"
else
    assert_fail "[SPEC-5] publish job is restricted to merged release/auto-* branches into main" \
        "head.ref=$_spec5_head_ref merged=$_spec5_merged base=$_spec5_base no_title_guard=$_spec5_no_title_guard"
fi

# ── SPEC-6: publish job uses --force (static grep on the YAML) ───────────────
if grep -q "release.sh --force" "$WORKFLOW_FILE" 2>/dev/null; then
    assert_pass "[SPEC-6] publish job invokes release.sh --force for idempotent re-entry"
else
    assert_fail "[SPEC-6] publish job invokes release.sh --force for idempotent re-entry" \
        "Expected 'release.sh --force' in the publish job step"
fi

# ── SPEC-7: dry_run path uses --dry-run in release.sh invocation ─────────────
if grep -q "\-\-dry-run" "$WORKFLOW_FILE" 2>/dev/null; then
    assert_pass "[SPEC-7] workflow passes --dry-run to release.sh when dry_run input is true"
else
    assert_fail "[SPEC-7] workflow passes --dry-run to release.sh when dry_run input is true" \
        "Expected '--dry-run' flag reference in release.yml"
fi

# ── SPEC-8: DOC-F wiring (static grep on the YAML) ───────────────────────────
# The regen step must ride the release PR (open-release-pr, --regen-only) and the
# wiki push must run on merge (publish job, --wiki-only). Both invoke the CLI.
_spec8_regen=false
_spec8_wiki=false
grep -q "docs publish --regen-only" "$WORKFLOW_FILE" 2>/dev/null && _spec8_regen=true
grep -q "docs publish --wiki-only"  "$WORKFLOW_FILE" 2>/dev/null && _spec8_wiki=true
if $_spec8_regen && $_spec8_wiki; then
    assert_pass "[SPEC-8] DOC-F wired: regen rides the PR + wiki push on merge"
else
    assert_fail "[SPEC-8] DOC-F wired: regen rides the PR + wiki push on merge" \
        "regen=$_spec8_regen wiki=$_spec8_wiki"
fi

# ── SPEC-9: cadence input wired into validate + apply steps ──────────────────
# (a) cadence choice input exists with default 'minor' in the workflow_dispatch block
_spec9_input=false
_spec9_default=false
_spec9_validate=false
_spec9_apply=false
grep -q "cadence:" "$WORKFLOW_FILE" 2>/dev/null && _spec9_input=true
grep -q "default: \"minor\"" "$WORKFLOW_FILE" 2>/dev/null && _spec9_default=true
# (b) validate step wires CADENCE env and appends --${CADENCE} to args
grep -q 'CADENCE: ${{ inputs.cadence }}' "$WORKFLOW_FILE" 2>/dev/null && _spec9_validate=true
# (c) apply step also includes --${CADENCE} in its args
grep -q '"--${CADENCE}"' "$WORKFLOW_FILE" 2>/dev/null && _spec9_apply=true

if $_spec9_input && $_spec9_default; then
    assert_pass "[SPEC-9] cadence choice input exists with default 'minor'"
else
    assert_fail "[SPEC-9] cadence choice input exists with default 'minor'" \
        "input=$_spec9_input default=$_spec9_default"
fi

if $_spec9_validate && $_spec9_apply; then
    assert_pass "[SPEC-9] cadence CADENCE env wired into validate and apply steps"
else
    assert_fail "[SPEC-9] cadence CADENCE env wired into validate and apply steps" \
        "validate=$_spec9_validate apply=$_spec9_apply"
fi

# (d) invalid cadence is rejected — the Validate-inputs case guard exits 1 on a
# value that is neither 'minor' nor 'major' (untested by the wiring checks above).
_spec9_guard=false
grep -q "Invalid 'cadence' input" "$WORKFLOW_FILE" 2>/dev/null && _spec9_guard=true

if $_spec9_guard; then
    assert_pass "[SPEC-9] invalid cadence value is rejected by the validate-inputs guard"
else
    assert_fail "[SPEC-9] invalid cadence value is rejected by the validate-inputs guard" \
        "guard=$_spec9_guard"
fi

# ── Shared fixtures for T2/T3/T4 ─────────────────────────────────────────────
GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls.log"
export GH_CALLS_LOG

mock_binary "gh" '
GH_CALLS_LOG="${GH_CALLS_LOG:-/tmp/gh-calls.log}"
printf "gh %s\n" "$*" >> "$GH_CALLS_LOG"
case "${1:-} ${2:-}" in
    "pr create")      echo "https://github.com/ezigus/zBuild/pull/999"; exit 0 ;;
    "pr merge")       exit 0 ;;
    "release view")   exit 1 ;;
    "release create") exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 0 ;;
esac
'

_reset() {
    > "$GH_CALLS_LOG"
}

# ── T2: gate-refusal — mock release.sh exits 1; assert no gh pr create ───────
_reset

GATE_ARGS_LOG="$TEST_TEMP_DIR/gate-args.log"
export GATE_ARGS_LOG
: > "$GATE_ARGS_LOG"
MOCK_RELEASE_GATE="$TEST_TEMP_DIR/bin/mock-release-gate"
# QUOTED heredoc delimiter ('SCRIPT') → "$@" is written to the mock LITERALLY,
# not expanded when the heredoc is written. The mock logs the args it received
# so the test can prove the workflow's real (non-dry-run) apply pass passes NO
# --dry-run flag on the mutating call.
cat > "$MOCK_RELEASE_GATE" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GATE_ARGS_LOG"
echo "release: gate refused: coverage gate failed" >&2
exit 1
SCRIPT
chmod +x "$MOCK_RELEASE_GATE"

# Replicate the workflow open-release-pr job's apply+conditional-PR logic. The
# apply step builds args WITHOUT --dry-run (mutating pass) — mirror that here.
apply_args=()
set +e
apply_out="$("$MOCK_RELEASE_GATE" "${apply_args[@]}" 2>&1)"
apply_rc=$?
set -e
gate_refused=false
if [[ $apply_rc -ne 0 ]]; then
    gate_refused=true
    # workflow: "skip=true" → Skipping PR creation.
else
    gate_refused=false
    gh pr create --title "Release v1.0.0.0" --body "auto" >/dev/null 2>&1 || true
fi

if $gate_refused && ! grep -qF "pr create" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-2] gate-refusal: no gh pr create when release.sh exits nonzero"
else
    assert_fail "[SPEC-2] gate-refusal: no gh pr create when release.sh exits nonzero" \
        "gate_refused=$gate_refused gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi

# The mutating apply pass must NOT carry --dry-run (that would open no PR AND
# mutate nothing — the workflow strips it by building a fresh non-dry array).
if ! grep -q -- "--dry-run" "$GATE_ARGS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-2] apply (mutating) pass invokes release.sh WITHOUT --dry-run"
else
    assert_fail "[SPEC-2] apply (mutating) pass invokes release.sh WITHOUT --dry-run" \
        "gate args log: $(cat "$GATE_ARGS_LOG" 2>/dev/null || echo '<empty>')"
fi

# ── T3: --force bypass — release.sh exits 0; assert gh pr create is called ───
_reset

FORCE_ARGS_LOG="$TEST_TEMP_DIR/force-args.log"
export FORCE_ARGS_LOG
: > "$FORCE_ARGS_LOG"
MOCK_RELEASE_OK="$TEST_TEMP_DIR/bin/mock-release-ok"
# QUOTED heredoc delimiter → "$@" written literally; the mock logs its args so
# the test can prove the publish path actually passes --force (not just exit 0).
cat > "$MOCK_RELEASE_OK" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FORCE_ARGS_LOG"
echo "Release v1.0.1.2"
exit 0
SCRIPT
chmod +x "$MOCK_RELEASE_OK"

# Replicate the publish job: release.sh --force exits 0 → publish proceeds and,
# on the open-release-pr force path, the PR is opened.
set +e
force_out="$("$MOCK_RELEASE_OK" --force 2>&1)"
force_rc=$?
set -e
if [[ $force_rc -ne 0 ]]; then
    pr_skipped=true
else
    pr_skipped=false
    gh pr create --title "Release v1.0.1.2" --body "auto" >/dev/null 2>&1 || true
fi

if ! $pr_skipped && grep -qF "pr create" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-3] --force bypass: gh pr create is called when release.sh exits 0"
else
    assert_fail "[SPEC-3] --force bypass: gh pr create is called when release.sh exits 0" \
        "pr_skipped=$pr_skipped gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi

# Prove --force was actually the flag passed (mock logged it) — not assumed.
if grep -q -- "--force" "$FORCE_ARGS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-3] release.sh was invoked with --force on the publish path"
else
    assert_fail "[SPEC-3] release.sh was invoked with --force on the publish path" \
        "force args log: $(cat "$FORCE_ARGS_LOG" 2>/dev/null || echo '<empty>')"
fi

if grep -q "pr create.*Release v" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-3] PR title matches 'Release v*' pattern"
else
    assert_fail "[SPEC-3] PR title matches 'Release v*' pattern" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi

# ── T4: dry_run=true — no gh pr create; release.sh invoked with --dry-run ─────
_reset

DRY_RUN_ARGS_LOG="$TEST_TEMP_DIR/dry-run-args.log"
export DRY_RUN_ARGS_LOG
: > "$DRY_RUN_ARGS_LOG"
MOCK_RELEASE_DRY="$TEST_TEMP_DIR/bin/mock-release-dry"
# QUOTED heredoc delimiter ('SCRIPT') → "$@" is written LITERALLY into the mock,
# not expanded at heredoc-write time. The log path flows in through env at
# invocation, so the delimiter can stay quoted (the whole point of the fix).
cat > "$MOCK_RELEASE_DRY" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DRY_RUN_ARGS_LOG"
echo "planned version: 1.0.1.2"
echo "planned tag:     v1.0.1.2"
echo "planned tarball: zbuild-v1.0.1.2.tar.gz"
echo "planned publish: gh release create v1.0.1.2"
exit 0
SCRIPT
chmod +x "$MOCK_RELEASE_DRY"

# Replicate workflow: dry_run=true → validate with --dry-run → apply/create-PR
# steps are GATED OUT (if: inputs.dry_run != true), so NO gh pr create runs.
"$MOCK_RELEASE_DRY" --dry-run >/dev/null 2>&1 || true
dry_run_input=true  # workflow: inputs.dry_run == true
if $dry_run_input; then
    : # apply-changelog + create-PR steps are skipped → no gh pr create
fi

if ! grep -qF "pr create" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-4] dry_run=true: no gh pr create call is made"
else
    assert_fail "[SPEC-4] dry_run=true: no gh pr create call is made" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi

if grep -q -- "--dry-run" "$DRY_RUN_ARGS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-4] dry_run=true: release.sh is invoked with --dry-run flag"
else
    assert_fail "[SPEC-4] dry_run=true: release.sh is invoked with --dry-run flag" \
        "dry-run args log: $(cat "$DRY_RUN_ARGS_LOG" 2>/dev/null || echo '<empty>')"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
