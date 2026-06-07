#!/usr/bin/env bash
# Unit: Wave 19-F (#738) — plan agent's DoD discipline validation.
#
# Tests the `_plan_validate_dod_discipline <plan_json> <goal_text>` helper
# in isolation: given a plan JSON + the goal text it was decomposed from,
# return 0 if the plan honors the issue's Definition of done + avoids
# anti-pattern phrases, return 1 otherwise.
#
# Forbidden phrases (when issue body has DoD): "may be toggled off",
# "optional", "gated by config", "future follow-up", "may be disabled".
#
# Migration keepers (5-test trial in body): plan MUST touch
# config/templates/standard.yaml in at least one step's files[].
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "plan agent — Issue-body DoD discipline (Wave 19-F #738)"
setup_test_env "plan-prompt-issue-discipline"

# Source the plan plugin to get _plan_validate_dod_discipline in scope.
# Stub bootstrap + helpers the plugin requires.
zbuild_plugin_bootstrap() { _ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/plan"; _ZBUILD_PLUGIN_ROOT="$REPO_ROOT"; }
emit_event() { return 0; }
# shellcheck source=../../plugins/agent/plan/plugin.sh
source "$REPO_ROOT/plugins/agent/plan/plugin.sh"

print_test_section "1. no DoD header in goal → validation passes regardless of plan content"

GOAL_NO_DOD="Fix a typo in README.md"
PLAN_OK='{"schema_version":1,"title":"fix typo","goal":"x","steps":[{"id":"step-1","description":"edit README","files":["README.md"],"estimated_lines":1}],"estimated_total_lines":1,"notes":""}'
PLAN_WITH_FORBIDDEN='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"may be toggled off optional gated by config future follow-up","files":["a"],"estimated_lines":1}],"estimated_total_lines":1,"notes":""}'

set +e; _plan_validate_dod_discipline "$PLAN_OK" "$GOAL_NO_DOD"; rc1=$?; set -e
assert_eq "T1: no DoD + clean plan = rc=0" "0" "$rc1"

set +e; _plan_validate_dod_discipline "$PLAN_WITH_FORBIDDEN" "$GOAL_NO_DOD"; rc2=$?; set -e
assert_eq "T2: no DoD + forbidden phrases = rc=0 (no DoD means no enforcement)" "0" "$rc2"

print_test_section "2. DoD header present + clean plan → validation passes"

GOAL_WITH_DOD="Implement feature X
## Definition of done
- [ ] Stage X is invoked
- [ ] Tests verify the live path"

PLAN_CLEAN_TOUCHES_TEMPLATE='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"wire stage X","files":["config/templates/standard.yaml","plugins/agent/x/plugin.sh"],"estimated_lines":50}],"estimated_total_lines":50,"notes":""}'

set +e; _plan_validate_dod_discipline "$PLAN_CLEAN_TOUCHES_TEMPLATE" "$GOAL_WITH_DOD"; rc3=$?; set -e
assert_eq "T3: DoD + clean plan + touches template = rc=0" "0" "$rc3"

print_test_section "3. DoD header present + forbidden phrase in plan → validation fails"

PLAN_HAS_FORBIDDEN='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"add stage but may be toggled off","files":["config/templates/standard.yaml"],"estimated_lines":50}],"estimated_total_lines":50,"notes":""}'

set +e; _plan_validate_dod_discipline "$PLAN_HAS_FORBIDDEN" "$GOAL_WITH_DOD"; rc4=$?; set -e
assert_eq "T4: DoD + plan contains 'may be toggled off' = rc=1" "1" "$rc4"

PLAN_HAS_FUTURE_FOLLOWUP='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"wire it","files":["config/templates/standard.yaml"],"estimated_lines":50}],"estimated_total_lines":50,"notes":"future follow-up will handle the rest"}'

set +e; _plan_validate_dod_discipline "$PLAN_HAS_FUTURE_FOLLOWUP" "$GOAL_WITH_DOD"; rc5=$?; set -e
assert_eq "T5: DoD + plan notes mention 'future follow-up' = rc=1" "1" "$rc5"

PLAN_HAS_OPTIONAL_GATED='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"add as optional gated by config","files":["config/templates/standard.yaml"],"estimated_lines":50}],"estimated_total_lines":50,"notes":""}'

set +e; _plan_validate_dod_discipline "$PLAN_HAS_OPTIONAL_GATED" "$GOAL_WITH_DOD"; rc6=$?; set -e
assert_eq "T6: DoD + 'optional gated by config' = rc=1" "1" "$rc6"

print_test_section "4. 5-test trial keeper + plan missing standard.yaml flow change → validation fails"

GOAL_KEEPER="Migrate stage X
## 5-test trial
- [ ] New code preserves behavior
- [ ] Removing reproduces symptom"

PLAN_MISSES_TEMPLATE='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"add plugin","files":["plugins/agent/x/manifest.yaml","plugins/agent/x/plugin.sh"],"estimated_lines":100}],"estimated_total_lines":100,"notes":""}'

set +e; _plan_validate_dod_discipline "$PLAN_MISSES_TEMPLATE" "$GOAL_KEEPER"; rc7=$?; set -e
assert_eq "T7: 5-test trial keeper + plan does NOT touch standard.yaml = rc=1" "1" "$rc7"

PLAN_TOUCHES_TEMPLATE='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"add plugin","files":["plugins/agent/x/plugin.sh"],"estimated_lines":100},{"id":"step-2","description":"wire into flow","files":["config/templates/standard.yaml"],"estimated_lines":10}],"estimated_total_lines":110,"notes":""}'

set +e; _plan_validate_dod_discipline "$PLAN_TOUCHES_TEMPLATE" "$GOAL_KEEPER"; rc8=$?; set -e
assert_eq "T8: 5-test trial keeper + plan touches standard.yaml = rc=0" "0" "$rc8"

print_test_section "5. Anti-patterns header present + per-issue pattern match → validation fails"

# Per-issue anti-patterns use issue-specific phrases NOT in the global
# forbidden list, to actually exercise the awk-extraction loop.
GOAL_WITH_ANTI="Migrate X
## Anti-patterns the plan agent MUST refuse

- ❌ \"side-channel via env var\"
- ❌ \"shadow registry of legacy callbacks\"

## Notes
Other section follows."

PLAN_MATCHES_ANTI='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"add side-channel via env var fallback","files":["config/templates/standard.yaml"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

set +e; _plan_validate_dod_discipline "$PLAN_MATCHES_ANTI" "$GOAL_WITH_ANTI"; rc9=$?; set -e
assert_eq "T9: Anti-patterns + plan matches per-issue 'side-channel via env var' = rc=1" "1" "$rc9"

# Sanity: a clean plan against the SAME anti-patterns goal passes (proves
# T9's failure was due to the per-issue match, not some other rule).
PLAN_CLEAN_AGAINST_ANTI='{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"step-1","description":"add proper feature","files":["config/templates/standard.yaml"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

set +e; _plan_validate_dod_discipline "$PLAN_CLEAN_AGAINST_ANTI" "$GOAL_WITH_ANTI"; rc9b=$?; set -e
assert_eq "T9b: Anti-patterns + clean plan = rc=0 (proves per-issue extraction is bounded)" "0" "$rc9b"

print_test_section "6. Acceptance criteria header (alias for DoD) triggers same discipline"

GOAL_WITH_AC="Build X
## Acceptance criteria
- [ ] X must work
- [ ] Integration test exists"

set +e; _plan_validate_dod_discipline "$PLAN_HAS_FORBIDDEN" "$GOAL_WITH_AC"; rc10=$?; set -e
assert_eq "T10: 'Acceptance criteria' header treated as DoD = rc=1 on forbidden phrase" "1" "$rc10"

print_test_results
cleanup_test_env
exit $((FAIL > 0))
