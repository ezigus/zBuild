#!/usr/bin/env bash
# plugins/tool/test/lib/own-checks.sh — test checks its own run (#2372, ADR-040,
# ADR-068).
#
# After the suite, test runs the checks that were stages of their own: the
# shape floor (lib/shape-floor-check.sh), the acceptance contract
# (lib/acceptance-check.sh), and that the assertion files are the ones their
# author wrote. test has no model to go back to: its one outcome is fail when any
# check fails, and the build loop goes round. Each check's numbered findings stay
# in that check's own result (#2428); test's result names the check in its reason.
#
# Sourced by plugin.sh after its bootstrap. Sourced library: no set -euo.

[[ -n "${_ZBUILD_TEST_OWN_CHECKS_LOADED:-}" ]] && return 0
_ZBUILD_TEST_OWN_CHECKS_LOADED=1

# _test_assertion_fingerprints <repo_root>
# The assertion files' fingerprints are found by what they are, never by which
# stage wrote them: any earlier output whose result carries data.testfiles (a
# path → content hash map) is one. Each file whose content no longer matches is
# a finding. Sets _TEST_FP_FINDINGS, and _TEST_FP_FOUND=1 when any fingerprint
# was given. rc 0.
_test_assertion_fingerprints() {
    local repo="$1" f p want got
    _TEST_FP_FINDINGS=(); _TEST_FP_FOUND=0
    [[ -s "${ZBUILD_STAGE_INPUTS:-}" ]] || return 0
    while IFS= read -r f; do
        [[ "$f" == *.json && -s "$f" ]] || continue
        while IFS=$'\t' read -r p want; do
            [[ -n "$p" ]] || continue
            _TEST_FP_FOUND=1
            got="$(git -C "$repo" hash-object -- "$p" 2>/dev/null || printf 'ABSENT')"
            [[ "$got" == "$want" ]] \
                || _TEST_FP_FINDINGS+=("$p was changed after its tests were written; the version its author wrote is restored before the next build")
        done < <(jq -r '(.data.testfiles // {}) | to_entries[]? | select(.value | type == "string") | "\(.key)\t\(.value)"' "$f" 2>/dev/null || true)
    done < <(jq -r '.inputs // {} | .[] | if type == "array" then .[] else . end | select(type == "string")' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)
    return 0
}

# _test_slow_files <repo_root> <timing_log>
# A test file this change added or changed that takes more than twice the
# slowest file the change did not touch, and over a minute, is a finding: on
# #1754's run a new file took 210 s against 72 s, and every re-run of it by the
# acceptance check went past its limit. The two are measured in the same run,
# so a slow runner slows both. The timing log (`file <ms> <path>`) names files
# under the run's staging copy, so files match on their repo-relative suffix.
# No untouched file measured (a targeted re-run): nothing to compare. Sets
# _TEST_SLOW_FINDINGS. rc 0.
_test_slow_files() {
    local repo="$1" log="$2" base kind ms path f
    _TEST_SLOW_FINDINGS=()
    [[ -s "$log" ]] || return 0
    local factor="${ZBUILD_TEST_SLOW_FACTOR:-2}" floor_s="${ZBUILD_TEST_SLOW_FLOOR_S:-60}"
    [[ "$factor" =~ ^[1-9][0-9]*$ ]] || factor=2
    [[ "$floor_s" =~ ^[0-9]+$ ]] || floor_s=60
    base="$(zbuild_resolve_merge_base "$repo" 2>/dev/null || true)"
    [[ -n "$base" ]] || return 0
    local -A changed=()
    while IFS= read -r f; do [[ -n "$f" ]] && changed[$f]=1; done \
        < <(git -C "$repo" diff --name-only "$base" -- 2>/dev/null; git -C "$repo" ls-files --others --exclude-standard 2>/dev/null)
    local -a mine=()
    local top_ms=0 top_path=""
    while read -r kind ms path; do
        [[ "$kind" == file && "$ms" =~ ^[0-9]+$ && -n "$path" ]] || continue
        local rel="" c
        for c in "${!changed[@]}"; do [[ "$path" == "$c" || "$path" == */"$c" ]] && { rel="$c"; break; }; done
        if [[ -n "$rel" ]]; then
            mine+=("$ms $rel")
        elif (( ms > top_ms )); then
            top_ms=$ms; top_path="$path"
        fi
    done < "$log"
    (( top_ms > 0 )) || return 0
    local top_rel="$top_path" top_s=$(( (top_ms + 500) / 1000 )) m_s
    [[ "$top_path" =~ ^/.*/((tests|plugins|scripts|core)/.*)$ ]] && top_rel="${BASH_REMATCH[1]}"
    local entry
    for entry in ${mine[@]+"${mine[@]}"}; do
        ms="${entry%% *}"; path="${entry#* }"
        (( ms > top_ms * factor && ms > floor_s * 1000 )) || continue
        m_s=$(( (ms + 500) / 1000 ))
        _TEST_SLOW_FINDINGS+=("$path took ${m_s} s — more than ${factor} times the slowest test file this change did not touch ($top_rel, ${top_s} s): make it, or the code it runs, faster")
    done
    return 0
}

# _test_own_checks <stage> <state_file> <output_json> <repo_root>
# Runs the checks and folds them into test's one result (<output_json>). A run
# that did not finish keeps its own word; a check that could not run says how.
_test_own_checks() {
    local stage="$1" state_file="$2" out="$3" repo="$4"
    local art; art="$(dirname "$out")"
    local own; own="$(jq -r '.outcome // empty' "$out" 2>/dev/null || true)"
    case "$own" in pass|fail) ;; *) return 0 ;; esac

    ( cd "$repo" 2>/dev/null && shape_floor_run "$stage" "$state_file" ) >/dev/null 2>&1 || true
    ( cd "$repo" 2>/dev/null && acceptance_gate_run "$stage" "$state_file" ) >/dev/null 2>&1 || true
    _test_assertion_fingerprints "$repo"

    local -a texts=() why=()
    local outcome="$own" r o t
    while IFS= read -r t; do [[ -n "$t" ]] && texts+=("$t"); done \
        < <(jq -r '.data.findings[]?.text // empty' "$out" 2>/dev/null || true)
    for r in "$art/shape-floor-result.json:the shape floor" "$art/acceptance-gate-result.json:the acceptance check"; do
        local f="${r%%:*}" name="${r#*:}"
        o="$(jq -r '.outcome // empty' "$f" 2>/dev/null || true)"
        case "$o" in
            pass) ;;
            fail)
                [[ "$outcome" == pass || "$outcome" == fail ]] && outcome=fail
                why+=("$name failed: $(jq -r '.reason // ""' "$f" 2>/dev/null)")
                # #2428 (ADR-071 §2): a finding lives in one output — the
                # check's own result, whose topic decides who reads it. A
                # check that failed with no findings gets its reason as one.
                if [[ "$(jq -r '(.data.findings // []) | length' "$f" 2>/dev/null)" == 0 ]]; then
                    local fj1 tmp1
                    fj1="$(printf '%s failed: %s\n' "$name" "$(jq -r '(.reason // "") | gsub("[\r\n]+"; " ")' "$f" 2>/dev/null)" | stage_findings_json)"
                    tmp1="$(jq --argjson f "${fj1:-[]}" '.data = ((.data // {}) + {findings: $f})' "$f" 2>/dev/null)" \
                        && printf '%s\n' "$tmp1" | atomic_write "$f"
                fi ;;
            "") outcome=broken; why+=("$name wrote no result") ;;
            *)  # A check that could not run says how; it is never a pass.
                [[ "$outcome" == pass || "$outcome" == fail ]] && outcome="$o"
                why+=("$name could not run ($o): $(jq -r '.reason // ""' "$f" 2>/dev/null)") ;;
        esac
    done
    if [[ ${#_TEST_FP_FINDINGS[@]} -gt 0 ]]; then
        [[ "$outcome" == pass || "$outcome" == fail ]] && outcome=fail
        why+=("assertion files were changed after their tests were written")
        texts+=("${_TEST_FP_FINDINGS[@]}")
    fi
    _test_slow_files "$repo" "$art/test-timing.log"
    if [[ ${#_TEST_SLOW_FINDINGS[@]} -gt 0 ]]; then
        [[ "$outcome" == pass || "$outcome" == fail ]] && outcome=fail
        why+=("a test file this change added or changed is far slower than the rest of the suite")
        texts+=("${_TEST_SLOW_FINDINGS[@]}")
    fi

    # No fingerprints given: nothing to compare — a warning, never a failure.
    local _note=""
    if [[ $_TEST_FP_FOUND -eq 0 ]]; then
        _note="the assertions were not fingerprinted, so changes to them were not checked"
        emit_event "test.assertions.unchecked" "stage=$stage" 2>/dev/null || true
    fi

    local fj tmp reason
    fj="$( { [[ ${#texts[@]} -gt 0 ]] && printf '%s\n' "${texts[@]}"; } | stage_findings_json)"
    tmp="$(jq --argjson f "${fj:-[]}" '.data = ((.data // {}) + {findings: $f})' "$out" 2>/dev/null)" \
        && printf '%s\n' "$tmp" | atomic_write "$out"
    # A check's failure the loop cannot fix (a malformed contract) still ends
    # the run: the engine reads `severity: terminal` on a member's result, so
    # test carries it from the acceptance check.
    if [[ "$outcome" == fail && "$(jq -r '.severity // empty' "$art/acceptance-gate-result.json" 2>/dev/null)" == terminal ]]; then
        tmp="$(jq '. + {severity: "terminal"}' "$out" 2>/dev/null)" && printf '%s\n' "$tmp" | atomic_write "$out"
    fi
    if [[ "$outcome" != "$own" || ${#why[@]} -gt 0 ]]; then
        reason="$(jq -r '.reason // ""' "$out" 2>/dev/null)"
        [[ ${#why[@]} -gt 0 ]] && reason="${reason:+$reason; }$(IFS=';'; printf '%s' "${why[*]}")"
        stage_result_add "$out" "$outcome" "$reason" >/dev/null 2>&1 || true
    fi
    local summ="$art/test-failures-summary.md"
    if [[ -n "$_note" || ${#why[@]} -gt 0 ]]; then
        {
            [[ ${#why[@]} -gt 0 ]] && { printf '\n## The checks of this run\n'; printf -- '- %s\n' "${why[@]}"; }
            [[ -n "$_note" ]] && printf '\nNote: %s.\n' "$_note"
        } >> "$summ" 2>/dev/null || true
    fi
    return 0
}
