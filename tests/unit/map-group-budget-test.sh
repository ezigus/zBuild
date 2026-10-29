#!/usr/bin/env bash
# Tests: a map group's time budget in the shipped templates (ADR-063 §3
# amendment, ADR-047 §2).
#
# Why: on #1801 and #1944 (2026-10-28) five of six review lenses were stopped
# by their 300 s per-call limit before they finished: a lens reads the change,
# the files around it and the tests, and spent its five minutes reading. Build
# and test-author get 900 s a call. And six lenses four at a time run in two
# rounds, so a longer call only helps if every round fits in the group's own
# stage limit.
#
# B1 a review lens's model call gets at least what build's does
# B2 every map group's rounds fit in its stage limit:
#    ceil(elements / max_parallel) x per-call limit <= the stage's timeout_s
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a map group's time budget fits its members (ADR-063, ADR-047)"
setup_test_env "map-group-budget"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/strategies/map.sh
source "$REPO_ROOT/core/pipeline/strategies/map.sh"

for tpl in simple deployed; do
    print_test_section "$tpl.yaml"
    load_template "$REPO_ROOT/config/templates/$tpl.yaml" >/dev/null 2>&1
    lens_call="$(template_stage_router_timeout review_lenses)"
    build_call="$(template_stage_router_timeout build)"
    if [[ "${lens_call:-0}" -ge "${build_call:-1}" ]]; then
        assert_pass "[B1] $tpl: a lens call ($lens_call s) gets at least build's ($build_call s)"
    else
        assert_fail "[B1] $tpl: a lens call gets at least build's" "lens ${lens_call:-unset} s < build ${build_call:-unset} s"
    fi
    for unit in "${_TPL_DISPATCH_UNITS[@]}"; do
        [[ "$unit" == map:* ]] || continue
        g="${unit#map:}"; gs="${g//-/_}"
        ev="_TPL_MAP_ELEMENTS_${gs}"; mv="_TPL_MAP_MAX_${gs}"
        IFS=, read -ra els <<< "${!ev:-}"
        max="$(ZBUILD_PARALLEL_JOBS=4 _strategy_map_resolve_max "${!mv:-}")"
        call="$(template_stage_router_timeout "$g")"; call="${call:-0}"
        limit="$(template_stage_time_limit "$g")"
        rounds=$(( (${#els[@]} + max - 1) / max ))
        need=$(( rounds * call ))
        if [[ "$need" -le "$limit" ]]; then
            assert_pass "[B2] $tpl: $g — $rounds round(s) x $call s fit in $limit s"
        else
            assert_fail "[B2] $tpl: $g — every round fits its stage limit" \
                "${#els[@]} members, $max at a time: $rounds round(s) x $call s = $need s > $limit s"
        fi
    done
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
