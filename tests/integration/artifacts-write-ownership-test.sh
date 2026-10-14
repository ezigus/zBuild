#!/usr/bin/env bash
# tests/integration/artifacts-write-ownership-test.sh — in the artifacts folder
# a stage may write only what is its own (#2379 part B, ADR-058).
#
# Why: #2174 made other stages' DECLARED outputs read-only, but everything else
# in the shared artifacts folder stayed open to every model call: another
# stage's notes, its earlier attempts, the run's stage reports. A stage could
# rewrite a finding another stage wrote about it.
#
#   A1 [change] a file another stage left in the artifacts folder — its notes,
#               its attempts, the stage reports — is denied to this stage
#   A2 [guard]  the stage's own notes file and its own declared output are not
#   A3 [change] a folder with nothing of the stage's in it is denied as a whole
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "artifacts: a stage writes only its own (#2379 part B)"
setup_test_env "artifacts-write-ownership"
emit_event() { :; }
verify_plugin_for_source() { return 0; }
scan_plugin_outputs() { return 0; }
export ZBUILD_NO_WORKTREE=1

JOB="$TEST_TEMP_DIR/state/runs/aw"; A="$JOB/artifacts"
SF="$JOB/pipeline-state.json"
mkdir -p "$A/notes" "$A/attempts/plan/1" "$JOB/runtime"
echo '{}' > "$SF"
printf 'n\n' > "$A/notes/plan.md"
printf 'n\n' > "$A/notes/me-stage.md"
printf '{}\n' > "$A/attempts/plan/1/plan.json"
printf '{}\n' > "$A/stage-reports.json"
printf '{}\n' > "$A/me-result.json"

WT="$TEST_TEMP_DIR/wt"; mkdir -p "$WT"; git -C "$WT" init -q
export ZBUILD_REPO_ROOT="$WT"

CAP="$TEST_TEMP_DIR/deny.txt"
FX="$TEST_TEMP_DIR/plugins/me"; mkdir -p "$FX"
cat > "$FX/manifest.yaml" <<'YAML'
id: me
name: me
kind: tool
version: 0.0.1
hooks:
  run: me_run
outputs:
  - id: result
    path: ${artifact_dir}/me-result.json
    required: true
    primary: true
YAML
cat > "$FX/plugin.sh" <<PEOF
me_run() { printf '%s\n' "\${ZBUILD_PERMISSION_DENY_EDIT:-}" > '$CAP'; }
PEOF
plugin_hook_call "$FX" run me-stage "$SF" >/dev/null 2>&1 || true
D="$(cat "$CAP" 2>/dev/null)"

print_test_section "A1: what another stage left is denied"
_has() { grep -qxF -- "$1" <<< "$D"; }
if _has "$A/notes/plan.md"; then assert_pass "[A1] another stage's notes"
else assert_fail "[A1] another stage's notes" "not denied"; fi
if _has "$A/stage-reports.json"; then assert_pass "[A1] the stage reports"
else assert_fail "[A1] the stage reports" "not denied"; fi

print_test_section "A2: what is the stage's own is not"
if grep -qxF "$A/notes/me-stage.md" <<< "$D"; then assert_fail "[A2] own notes are writable" "denied"
else assert_pass "[A2] own notes are writable"; fi
if grep -qxF "$A/me-result.json" <<< "$D"; then assert_fail "[A2] own declared output is writable" "denied"
else assert_pass "[A2] own declared output is writable"; fi

print_test_section "A3: a folder with nothing of the stage's is denied whole"
if _has "$A/attempts/**"; then assert_pass "[A3] attempts/ is denied as a folder"
else assert_fail "[A3] attempts/ is denied as a folder" "not denied"; fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
