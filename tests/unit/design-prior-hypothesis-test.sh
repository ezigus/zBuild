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
# SPEC-2[change]: design's latest design.md is carried as YOUR LATEST DESIGN, with the
#   instruction to re-check every claim it makes against the tree as it is NOW. What
#   moved since design last ran — files and the issue text — is the engine's, under
#   Previous work (ADR-067 §8; stage-prompt-contract-test P4), not design's own block.
# SPEC-3[change]: the prompt no longer says "refine, do not recreate"
# SPEC-5[change]: one wording whichever try or run wrote it — a rerun of an issue
#   continues it (ADR-068 §8): no "earlier in this run", no "previous attempt", no
#   "earlier run" label
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

# The design call: it writes a design where the prompt says, when the test
# asks for one (MOCK_DESIGN_WRITE_PATH set).
route_to_model() {
    local _t; _t="$(zb_test_prompt_write_path "$2")"
    [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" && -n "$_t" ]] && {
        mkdir -p "$(dirname "$_t")"
        printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$_t"
    }
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
( cd "$FIX" && _design_stage_run_inner "$FIX/state/scope-manifest.md" "$AD/design.md" "$AD" >/dev/null 2>&1 ) || true
_at="$(jq -r '.data.authored_at // empty' "$AD/design-verdict.json" 2>/dev/null)"
_sha="$(jq -r '.data.authored_at_commit // empty' "$AD/design-verdict.json" 2>/dev/null)"
if [[ "$_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    assert_pass "[SPEC-1] design-verdict.json data.authored_at is an ISO-8601 UTC timestamp"
else
    assert_fail "[SPEC-1] design-verdict.json data.authored_at is an ISO-8601 UTC timestamp" "got: '$_at'"
fi
assert_eq "[SPEC-1] data.authored_at_commit is the repo HEAD at authoring" "$(git -C "$FIX" rev-parse HEAD)" "$_sha"

print_test_section "SPEC-2/3/5: design refines its latest design, whichever run wrote it"
for _case in 2 5 5b; do
    ADc="$FIX/state$_case/artifacts"; mkdir -p "$ADc"; cp "$AD/plan.json" "$ADc/"
    printf 'scope: all\n' > "$FIX/state$_case/scope-manifest.md"
    printf '# Design\n\nLATEST-DESIGN-%s\n\n```scope\nfoo.sh\n```\n' "$_case" > "$ADc/design.md"
    export MOCK_DESIGN_WRITE_PATH="$ADc/design.md"
    _iter=1; [[ "$_case" == 5 ]] && _iter=2
    ( cd "$FIX" && ZBUILD_CYCLE_ITER=$_iter _design_stage_run_inner "$FIX/state$_case/scope-manifest.md" "$ADc/design.md" "$ADc" >/dev/null 2>&1 ) || true
    Pc="$(cat "$ADc/design-prompt.txt" 2>/dev/null)"
    assert_contains "[SPEC-2] ($_case) the latest design is carried into the prompt" "$Pc" "LATEST-DESIGN-$_case"
    assert_contains "[SPEC-2] ($_case) as YOUR LATEST DESIGN" "$Pc" "### YOUR LATEST DESIGN"
    assert_contains "[SPEC-2] ($_case) every claim is re-checked against the tree as it is now" "$Pc" "re-checked against the tree as it is NOW"
    if grep -qF 'refine, do not recreate' <<< "$Pc"; then
        assert_fail "[SPEC-3] ($_case) the prompt no longer says 'refine, do not recreate'" "still present"
    else
        assert_pass "[SPEC-3] ($_case) the prompt no longer says 'refine, do not recreate'"
    fi
    if grep -qiE 'earlier in this run|previous attempt|earlier run|SINCE THE PRIOR DESIGN' <<< "$Pc"; then
        assert_fail "[SPEC-5] ($_case) one wording, with no run label" "$(grep -iE 'earlier in this run|previous attempt|earlier run|SINCE THE PRIOR' <<< "$Pc" | head -2)"
    else
        assert_pass "[SPEC-5] ($_case) one wording, with no run label"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
