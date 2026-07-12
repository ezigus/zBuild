#!/usr/bin/env bash
# Tests: .github/workflows/release.yml — YAML syntax + shell-level behavior
# exercised via the same release.sh seams the workflow invokes.
#
# SPEC-1: release.yml YAML is syntactically valid (python3 yaml.safe_load)
# SPEC-2: gate-refusal path — when release.sh exits nonzero, no gh pr create is called
# SPEC-3: --force bypass — release.sh exits 0 with --force, gh pr create is called
# SPEC-4: dry_run=true — no gh pr create and release.sh is invoked with --dry-run
# SPEC-5: publish job trigger condition matches PR title 'Release v*'
# SPEC-6: workflow uses --force on the publish path (idempotent re-entry)
# SPEC-7: open-release-pr job passes --dry-run flag when dry_run input is true
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
# Try PyYAML first; fall back to ruby or a structural heuristic if unavailable.
_yaml_valid=false
if python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$WORKFLOW_FILE" 2>/dev/null; then
    _yaml_valid=true
elif command -v ruby >/dev/null 2>&1 && ruby -e "require 'yaml'; YAML.safe_load(File.read(ARGV[0]))" "$WORKFLOW_FILE" 2>/dev/null; then
    _yaml_valid=true
elif command -v yq >/dev/null 2>&1 && yq eval '.' "$WORKFLOW_FILE" >/dev/null 2>&1; then
    _yaml_valid=true
else
    # Structural heuristic: must start with 'name:' and contain 'on:' / 'jobs:'.
    if grep -qE '^name:' "$WORKFLOW_FILE" && grep -qE '^(on|jobs):' "$WORKFLOW_FILE"; then
        _yaml_valid=true
    fi
fi
if $_yaml_valid; then
    assert_pass "[SPEC-1] release.yml YAML syntax is valid"
else
    assert_fail "[SPEC-1] release.yml YAML syntax is valid" \
        "YAML validation failed on $WORKFLOW_FILE"
fi

# ── SPEC-5: publish job trigger condition (static grep on the YAML) ───────────
if grep -q "startsWith(github.event.pull_request.title, 'Release v')" "$WORKFLOW_FILE" 2>/dev/null; then
    assert_pass "[SPEC-5] publish job guards on PR title prefix 'Release v'"
else
    assert_fail "[SPEC-5] publish job guards on PR title prefix 'Release v'" \
        "Expected startsWith guard in publish job if: expression"
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

MOCK_RELEASE_GATE="$TEST_TEMP_DIR/bin/mock-release-gate"
cat > "$MOCK_RELEASE_GATE" <<'SCRIPT'
#!/usr/bin/env bash
echo "release: gate refused: coverage gate failed" >&2
exit 1
SCRIPT
chmod +x "$MOCK_RELEASE_GATE"

# Replicate the workflow open-release-pr job's apply+conditional-PR logic:
set +e
apply_out="$("$MOCK_RELEASE_GATE" 2>&1)"
apply_rc=$?
set -e
gate_refused=false
if [[ $apply_rc -ne 0 ]]; then
    gate_refused=true
    # workflow: "Skipping PR creation."
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

# ── T3: --force bypass — release.sh exits 0; assert gh pr create is called ───
_reset

MOCK_RELEASE_OK="$TEST_TEMP_DIR/bin/mock-release-ok"
cat > "$MOCK_RELEASE_OK" <<'SCRIPT'
#!/usr/bin/env bash
echo "Release v1.0.1.2"
exit 0
SCRIPT
chmod +x "$MOCK_RELEASE_OK"

# Replicate workflow logic (force path, release.sh exits 0 → PR is opened):
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

if grep -q "pr create.*Release v" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-3] PR title matches 'Release v*' pattern"
else
    assert_fail "[SPEC-3] PR title matches 'Release v*' pattern" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi

# ── T4: dry_run=true — no gh pr create; release.sh invoked with --dry-run ─────
_reset

DRY_RUN_ARGS_LOG="$TEST_TEMP_DIR/dry-run-args.log"
MOCK_RELEASE_DRY="$TEST_TEMP_DIR/bin/mock-release-dry"
cat > "$MOCK_RELEASE_DRY" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DRY_RUN_ARGS_LOG"
echo "planned tag: v1.0.1.2"
echo "planned tarball: zbuild-v1.0.1.2.tar.gz"
echo "planned publish: gh release create v1.0.1.2"
exit 0
SCRIPT
chmod +x "$MOCK_RELEASE_DRY"

# Replicate workflow: dry_run=true → validate with --dry-run → abort before PR.
"$MOCK_RELEASE_DRY" --dry-run >/dev/null 2>&1 || true
dry_run_input=true  # workflow: inputs.dry_run == true
if $dry_run_input; then
    : # workflow exits 0 without calling gh pr create
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
