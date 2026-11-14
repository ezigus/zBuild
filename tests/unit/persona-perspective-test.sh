#!/usr/bin/env bash
# tests/unit/persona-perspective-test.sh — what a shipped persona's perspective
# holds (ADR-051 §9).
#
# Why: a persona is shared by any stage that pins it (§1), so a perspective that
# speaks of one stage's work is wrong wherever else it runs. On #1769 run
# 43517034037 the scope lens judged "the plan's declared file list" — the plan
# stage had been merged into design — and issue-acceptance ran as a persona
# that judged "a plan". Studies of persona prompts find an identity line ("you
# are an expert …") does not make a model more accurate (ADR-051 §9), so a
# perspective says what to look for, not who the model is.
#
# P1 [change] no shipped perspective is an identity line: no "you are a/an/the",
#             no "expert"
# P2 [change] no shipped perspective speaks of the pipeline it runs in: no
#             stage, plan, pipeline, manifest or lens
# P3 [change] every shipped persona has a perspective to check
# P4 [change] a persona's summary, which reaches the model with its perspective
#             (ADR-051 §3), holds to P1 and P2 too
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
print_test_header "a persona's perspective says what to look for (ADR-051 §9)"

_IDENTITY_RE='(^|[^[:alpha:]])(you are (a|an|the)|experts?)([^[:alpha:]]|$)'
_PIPELINE_RE='(^|[^[:alpha:]])(stages?|plans?|planned|pipelines?|manifests?|lens(es)?)([^[:alpha:]]|$)'

_n=0
for _m in "$REPO_ROOT"/plugins/persona/*/manifest.yaml; do
    _id="$(basename "$(dirname "$_m")")"
    _p="$(resolve_persona_perspective "$_id" "$REPO_ROOT/plugins" 2>/dev/null || true)"
    _lp="$(tr '[:upper:]' '[:lower:]' <<< "$_p")"
    if [[ -z "$_p" ]]; then
        assert_fail "[P3] $_id has a perspective" "resolve_persona_perspective returned nothing"
        continue
    fi
    _n=$((_n + 1))
    if [[ "$_lp" =~ $_IDENTITY_RE ]]; then
        assert_fail "[P1] $_id's perspective is no identity line" "it has: ${BASH_REMATCH[2]}"
    else
        assert_pass "[P1] $_id's perspective is no identity line"
    fi
    if [[ "$_lp" =~ $_PIPELINE_RE ]]; then
        assert_fail "[P2] $_id's perspective names nothing of the pipeline" "it has: ${BASH_REMATCH[2]}"
    else
        assert_pass "[P2] $_id's perspective names nothing of the pipeline"
    fi
    _ls="$(tr '[:upper:]' '[:lower:]' <<< "$(yaml_get "$_m" summary 2>/dev/null || true)")"
    if [[ "$_ls" =~ $_IDENTITY_RE || "$_ls" =~ $_PIPELINE_RE ]]; then
        assert_fail "[P4] $_id's summary is no identity line and names nothing of the pipeline" "it has: ${BASH_REMATCH[2]}"
    else
        assert_pass "[P4] $_id's summary is no identity line and names nothing of the pipeline"
    fi
done
if [[ $_n -gt 0 ]]; then assert_pass "[P3] the shipped personas were read ($_n)"
else assert_fail "[P3] the shipped personas were read" "none found"; fi

print_test_results
exit $((FAIL > 0))
