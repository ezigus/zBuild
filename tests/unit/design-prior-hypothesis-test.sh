#!/usr/bin/env bash
# design-prior-hypothesis-test.sh — a carried-forward design is a hypothesis
# the design stage re-checks against the tree as it is NOW (#2172).
#
# #1841 (2026-09-21): the design was refined for weeks from a prior design that
# cited ADR-056's per-stage cleanup hook. ADR-062 had retired that hook and the
# repo's guard tests enforce it. The prompt said "refine, do not recreate", no
# stage told the design its premise had moved, and the failure had no path back
# to the one stage that could change the contract.
#
# SPEC-1[change]: the design result records WHEN and against WHICH commit it was authored
#   (data.authored_at ISO-8601, data.authored_at_commit)
# SPEC-2[change]: with a prior design that carries that stamp, the prompt carries an
#   engine-collected "SINCE THE PRIOR DESIGN" block naming the ADRs added or changed
#   since, each with its Supersedes line, and the scope files that changed
# SPEC-3[change]: the prior design is presented as a hypothesis to re-verify — the prompt
#   no longer says "refine, do not recreate"
# SPEC-4[change]: a prior design with no stamp is presented as undated — every claim unverified
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: the prior design is a hypothesis, re-checked against the tree (#2172)"
setup_test_env "design-prior-hypothesis"
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

route_to_model_loop() {
    [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" ]] && {
        mkdir -p "$(dirname "$MOCK_DESIGN_WRITE_PATH")"
        printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$MOCK_DESIGN_WRITE_PATH"
    }
    _ROUTE_LOOP_FINAL_OUTPUT="ok"; _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
_route_loop_close_final_banner() { return 0; }

# A fixture repo with history: an old ADR, then (later) a superseding ADR and a
# change to a scope file.
FIX="$TEST_TEMP_DIR/fix"; mkdir -p "$FIX/docs/adr" "$FIX/state/artifacts"
git -C "$FIX" init -q; git -C "$FIX" config user.email t@t; git -C "$FIX" config user.name t
printf '# ADR-001 — cleanup hooks\n\n**Status:** Accepted\n\nStages declare a cleanup hook.\n' > "$FIX/docs/adr/ADR-001-cleanup-hooks.md"
printf 'old\n' > "$FIX/foo.sh"
GIT_AUTHOR_DATE="2026-08-01T10:00:00Z" GIT_COMMITTER_DATE="2026-08-01T10:00:00Z" git -C "$FIX" -c commit.gpgsign=false commit -qam "adr-001 + foo" 2>/dev/null || { git -C "$FIX" add -A; GIT_AUTHOR_DATE="2026-08-01T10:00:00Z" GIT_COMMITTER_DATE="2026-08-01T10:00:00Z" git -C "$FIX" commit -qm "adr-001 + foo"; }
OLD_SHA="$(git -C "$FIX" rev-parse HEAD)"
printf '# ADR-002 — the engine reclaims\n\n**Status:** Accepted\n**Supersedes:** ADR-001 per-stage cleanup hooks\n\nNo stage declares a cleanup hook.\n' > "$FIX/docs/adr/ADR-002-engine-reclaims.md"
printf 'new\n' > "$FIX/foo.sh"
git -C "$FIX" add -A; GIT_AUTHOR_DATE="2026-09-15T10:00:00Z" GIT_COMMITTER_DATE="2026-09-15T10:00:00Z" git -C "$FIX" commit -qm "adr-002 supersedes; foo changed"
export ZBUILD_REPO_ROOT="$FIX"
AD="$FIX/state/artifacts"
printf 'scope: all\n' > "$FIX/state/scope-manifest.md"
cat > "$AD/plan.json" <<'EOF2'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF2

print_test_section "SPEC-1: the result is stamped with when and against what it was authored"
export MOCK_DESIGN_WRITE_PATH="$AD/design.md"
( cd "$FIX" && _design_stage_run_inner "$FIX/state/scope-manifest.md" "$AD/plan.json" "$AD/design.md" "$AD" >/dev/null 2>&1 ) || true
_at="$(jq -r '.data.authored_at // empty' "$AD/design-verdict.json" 2>/dev/null)"
_sha="$(jq -r '.data.authored_at_commit // empty' "$AD/design-verdict.json" 2>/dev/null)"
if [[ "$_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    assert_pass "[SPEC-1] design-verdict.json data.authored_at is an ISO-8601 UTC timestamp"
else
    assert_fail "[SPEC-1] design-verdict.json data.authored_at is an ISO-8601 UTC timestamp" "got: '$_at'"
fi
assert_eq "[SPEC-1] data.authored_at_commit is the repo HEAD at authoring" "$(git -C "$FIX" rev-parse HEAD)" "$_sha"

print_test_section "SPEC-2/3: a stamped prior design gets the engine-collected drift block"
RESTORED="$TEST_TEMP_DIR/restored"; mkdir -p "$RESTORED"
printf '# Design\n\nRelies on ADR-001: declare a cleanup hook.\n\n```scope\nfoo.sh\n```\n' > "$RESTORED/design.md"
# The prior design was authored before ADR-002 and before foo.sh changed.
jq -n --arg sha "$OLD_SHA" '{result_contract:2, verdict:"pass", disposition:"complete", reason:"design_produced", data:{authored_at:"2026-08-02T00:00:00Z", authored_at_commit:$sha}}' > "$RESTORED/design-verdict.json"
export ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED"
AD2="$FIX/state2/artifacts"; mkdir -p "$AD2"; cp "$AD/plan.json" "$AD2/"; printf 'scope: all\n' > "$FIX/state2/scope-manifest.md"
export MOCK_DESIGN_WRITE_PATH="$AD2/design.md"
( cd "$FIX" && _design_stage_run_inner "$FIX/state2/scope-manifest.md" "$AD2/plan.json" "$AD2/design.md" "$AD2" >/dev/null 2>&1 ) || true
P="$AD2/design-prompt.txt"
assert_file_exists "[SPEC-2] the prompt is written" "$P"
assert_contains "[SPEC-2] the prompt carries the SINCE THE PRIOR DESIGN block" "$(cat "$P")" "SINCE THE PRIOR DESIGN"
assert_contains "[SPEC-2] …dating the prior design" "$(cat "$P")" "2026-08-02"
assert_contains "[SPEC-2] …naming the ADR added since" "$(cat "$P")" "ADR-002-engine-reclaims.md"
assert_contains "[SPEC-2] …with its Supersedes line" "$(cat "$P")" "Supersedes: ADR-001"
assert_contains "[SPEC-2] …and the scope file that changed since" "$(sed -n '/SINCE THE PRIOR DESIGN/,/^## /p' "$P")" "foo.sh"
assert_contains "[SPEC-3] the prior design is framed as a hypothesis to re-verify" "$(cat "$P")" "a hypothesis, not a fact"
if grep -qF 'refine, do not recreate' "$P"; then
    assert_fail "[SPEC-3] the prompt no longer says 'refine, do not recreate'" "still present"
else
    assert_pass "[SPEC-3] the prompt no longer says 'refine, do not recreate'"
fi

print_test_section "SPEC-4: an unstamped prior design is undated — every claim unverified"
rm -f "$RESTORED/design-verdict.json"
AD3="$FIX/state3/artifacts"; mkdir -p "$AD3"; cp "$AD/plan.json" "$AD3/"; printf 'scope: all\n' > "$FIX/state3/scope-manifest.md"
export MOCK_DESIGN_WRITE_PATH="$AD3/design.md"
( cd "$FIX" && _design_stage_run_inner "$FIX/state3/scope-manifest.md" "$AD3/plan.json" "$AD3/design.md" "$AD3" >/dev/null 2>&1 ) || true
assert_contains "[SPEC-4] an undated prior design is said to be undated" "$(cat "$AD3/design-prompt.txt")" "date is unknown"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
