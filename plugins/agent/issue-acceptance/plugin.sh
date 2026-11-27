#!/usr/bin/env bash
# plugins/agent/issue-acceptance/plugin.sh — does the finished change do what
# the ISSUE asked? (#1849, ADR-040 §5, ADR-054, ADR-055)
#
# Kind: agent  Tier: T2  convergence: gate (its standard is the issue, which the
# judged parties cannot re-author).
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_ISSUE_ACCEPTANCE_LOADED:-}" ]] && return 0
_ZBUILD_ISSUE_ACCEPTANCE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-summary.sh"
# #2366: the one writer of a stage's result (contract 3).
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-result.sh"
_IA_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_IA_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_IA_ROOT/core/router/route.sh"
# shellcheck source=../../../scripts/lib/trace.sh
source "$_IA_ROOT/scripts/lib/trace.sh"
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_IA_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/test-paths.sh
source "$_IA_ROOT/scripts/lib/test-paths.sh"
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_IA_ROOT/scripts/lib/earlier-output.sh"
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_IA_ROOT/scripts/lib/test-output-sanitize.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_IA_ROOT/scripts/lib/llm-agent.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/judge.sh
source "$_IA_ROOT/scripts/lib/judge.sh"
# shellcheck source=../../../scripts/lib/stage-handoff.sh
source "$_IA_ROOT/scripts/lib/stage-handoff.sh"
# #2584: the rule on outside assumptions, as design, build and the lenses get it.
# shellcheck source=../../../scripts/lib/outside-assumptions.sh
source "$_IA_ROOT/scripts/lib/outside-assumptions.sh"
# shellcheck source=./lib/parse.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/lib/parse.sh"
# #2574: a verdict kept per item.
# shellcheck source=./lib/items.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/lib/items.sh"
# shellcheck source=../../../scripts/lib/merge-base.sh
declare -F zbuild_change_files_v >/dev/null 2>&1 || source "$_IA_ROOT/scripts/lib/merge-base.sh"
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_IA_ROOT/scripts/lib/router-rc-classify.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/persona-resolve.sh
source "$_IA_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
# shellcheck source=../../../core/plugin-registry/persona.sh
source "$_IA_ROOT/core/plugin-registry/persona.sh" 2>/dev/null || true

_ia_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }
# #2574 (ADR-068 §5): the code its findings' ids take (IAFND).
_IA_FCODE=""; zb_finding_code_v _IA_FCODE "${BASH_SOURCE[0]%/*}/manifest.yaml"

# intake writes the literal "GitHub issue #<N>" when the fetch fails (#1804);
# judging a change against that must not read as satisfied (spec-coverage's rule).
_ia_issue_is_placeholder() {
    local t="${1-}"
    t="${t//[[:space:]]/}"
    [[ -z "$t" ]] && return 0
    [[ "$t" =~ ^GitHubissue#[0-9]+$ ]]
}

# _ia_prompt <issue> <acc> <change> <test_verdict> <reqs> [held] [lims] [terms]
#            [reverse] [kept] — [reverse] 0: the reverse question keeps its
# verdict and is not asked; [kept]: the items that keep theirs (#2574).
_ia_prompt() {
    local _rev_q="" _kept=""
    if [[ "${9:-1}" != 0 ]]; then
        # #2629 (ADR-075 §3): the rule every check of a change is given.
        local _trace=""; zb_trace_rule_v _trace "a requirement of the issue" "the issue"
        IFS= read -r -d '' _rev_q <<'REV' || true
Then answer the reverse question: each part of the DIFF that no requirement asks
for — not the ISSUE, not ISSUE REQUIREMENTS, not REQUIREMENTS. @TRACE@
Write one answer for each part nothing asks for:

UNASKED: <what the change does>
why: <why no requirement asks for it>
accepted if: <the change without it, or the requirement that would ask for it — nothing else>
quote: <file> | <one line of the code that does it>

Its QUOTE is the code that does it. When every part of the DIFF is asked for,
write one line: UNASKED: none
REV
        _rev_q="${_rev_q/@TRACE@/$_trace}"
    fi
    [[ -n "${10:-}" ]] && _kept=$'\n'"ALREADY JUDGED — each keeps the verdict it was given; write no line for them:"$'\n'"${10}"$'\n'
    cat <<EOF
You are checking whether a finished CHANGE does what an ISSUE asked for.

## What you own
One verdict on the whole issue: does THE CHANGE meet every requirement the
issue states, in full — including what its tests must catch?

Answer once for every requirement in ISSUE REQUIREMENTS, by its id.
Write each answer as a block: its first line as shown, then each field on a
line of its own. A quote: line holds only the quote, copied as it is; your own
words go in why: or note:. A blank line ends the answer.

MET: <id>
UNMET: [fix-code] <id>
why: <what the change does not do>
accepted if: <the requirement, in its own words>
quote: <quote>
UNMET: [fix-design] <id>
why: <what the requirements miss or get wrong>
accepted if: <the requirement, in its own words>
quote: <quote>

ACCEPTED IF names the line you judge against: the requirement or the limit, in
its own words, so the finding says what would be accepted. An UNASKED line with
no ACCEPTED IF cannot be used.

When none are listed under ISSUE REQUIREMENTS, write one of these lines for
each requirement the ISSUE states, naming it in a few words where the id would
go.

Start each UNMET: line with what would fix it:
- [fix-code] — the change does not do it yet: the code or its tests must change.
- [fix-design] — the REQUIREMENTS miss it or get it wrong, or the issue itself is
  wrong: the design must change.
Leave the mark off when you cannot tell which would fix it.

${ZB_OUTSIDE_ASSUMPTIONS_RULE:-}
A requirement whose change rests on an outside assumption it does not handle is
unmet: say which assumption in its WHY. To see whether one about GitHub holds —
that a label, a branch or a setting exists — check it, read-only, with
zbuild-gh-get <endpoint> [jq-filter] rather than guess it.

${ZB_UNCLEAR_RULES}
When none are listed under ISSUE REQUIREMENTS, the <id> of an UNCLEAR line is
the requirement's few words joined by dashes.
A question is never a verdict: write the requirement's MET: or UNMET: line too, judged by the reading you assumed.

A QUOTE is either the requirement's own words, from ISSUE REQUIREMENTS or the
ISSUE, or the code that shows it: <file> | <one line from it>. Copy it as it
is, with no quote marks around it: it is checked, and one that is not there
makes the answer unusable.

${_rev_q}${7:+
Then judge each LIMIT — something the issue says the change must not do — one
line for each, by its id:

KEPT: <id>
BROKEN: <id>
why: <what the change does that the limit forbids>
accepted if: <the limit, in its own words>
quote: <file> | <one line of the code that does it>

A limit is broken only by code the change adds or changes; its QUOTE is that
code.
}
Findings other stages raised may be shown under Previous work. After your
verdict lines, answer each of them:
${_ZB_ANSWER_FORMS:-}
## What you judge against
Five things, shown at the end of this part:

ISSUE — what was asked for, in the requester's own words. This is the standard.
ISSUE REQUIREMENTS — the issue's requirements, each with its id.
REQUIREMENTS — what the design committed to, each with what was done about it.
THE CHANGE — the commit the branch started from and the files it changed.
Read each change yourself with git, as it says there.
TEST VERDICT — whether the test suite passed.

Judge every requirement in ISSUE REQUIREMENTS: decide whether the change meets it
IN FULL, and name an unmet one by its id and words (<its id>: <its words>). Read the
ISSUE for what a requirement means. When none are listed under ISSUE REQUIREMENTS,
judge every requirement the ISSUE states.
Judge against the issue's own words, not the SPECs: a SPEC that narrowed a
requirement does not make the narrowed version enough. A requirement met only
partly — a subset of the cases, a weaker condition, some of the files — is unmet.
A requirement is met only when the behaviour it asks for
runs when the program runs: code that nothing calls, or
a new file nothing uses, does not meet it — say what should call or use it.
A requirement with a test the change puts off ("to be tested later"), or with
behaviour the change makes optional (off by default, or skipped when a value
is missing), is unmet unless the issue asks for it that way.

An issue contains more than requirements — context, rationale, links, history.
Those are not requirements. Judge every requirement the issue states, including
what its tests must catch (for example "putting the old code back turns the test
red"). The pipeline does not check those for you. For each one, ask: if the
change were broken, would its tests catch it? If they would not, it is unmet.

Some REQUIREMENTS were not run against the old code: those that need work but
no code, the doc changes, and those design says are already done. Nothing but
you checks them. For a doc change, read the doc on the branch: no test checks
it. For one already done, open the file its evidence names and check the claim
against the code. If you cannot
tell whether such a requirement is met, it is UNMET: say in its WHY what you
cannot tell, and in its ACCEPTED IF what would settle it.

A failing test you cannot trace to the change within a few reads: mark the
requirement it bears on UNMET, naming in its WHY the test and that you could
not tell whether the change broke it. Do not
work out why a test fails: that is the build's job, and your answer is lost if
your time runs out first.

ISSUE:
$1

ISSUE REQUIREMENTS:
${5:-<none listed>}
${_kept}
REQUIREMENTS:
$2
${7:+
LIMITS — what the change must not do:
$7
}${8:+
TERMS — what the issue says each of these words means, and only this:
$8
}
THE CHANGE:
$3

TEST VERDICT: $4
${6:-}
## What you must not do
- Do not suggest code.
- Do not guess whether a requirement is met: when you cannot tell, it is UNMET, saying what you cannot tell.
- Do not work out why a test fails: a failure you cannot trace to the change is UNMET, saying so.
- Answer only, in the form above.
EOF
}

# _ia_write <dir> <outcome> <reason> [unmet_json] [unsure_json] [judgement] [unasked_json]
# #2366 (ADR-054 §6, contract 3): one outcome — pass when every requirement is
# met, fail when one is not, is unsure, or the issue cannot be read; otherwise
# how the stage failed to finish. `judgement` keeps "unreadable" as detail.
_ia_write() {
    local dir="$1" o="$2" r="$3" u="${4:-[]}" s="${5:-[]}" j="${6:-}" x="${7:-[]}"
    mkdir -p "$dir" 2>/dev/null || true
    # #2271 (ADR-068): each unmet acceptance item is a numbered finding. #2304
    # (ADR-069 §7): so is each requirement the judge is not sure of — nothing
    # else checks it. #2330, #2569: each says what would settle it — the
    # check's own ACCEPTED IF, never advice the engine writes. #2629 (ADR-075
    # §3): an unasked part's is the change without it, or a requirement that
    # asks for it — the reader refuses any other, and the check is asked again.
    # #2452, #2556, #2569 (ADR-071 §1): a line's [fix-<word>] mark is its topic,
    # <word>-findings — what must change — and sends it to the output of the
    # stages that can fix it, never its text. #2569 (review): an unmet or
    # unsure line with no mark says nothing of what must change, so it goes to
    # every stage that can change something: design, test and code.
    # #2508 (ADR-072 §3): a part of the change nothing asked for is
    # the code's to undo; #2523: one in a test file ([fix-test]) is a test's,
    # which test-author takes: build may not change a test.
    # #2571 (ADR-072 §3): a question it raised now is a finding routed as an
    # unmarked UNSURE line was; the questions it goes on with are data.unclear.
    local _uq_new="[]"; zb_unclear_result_json_v _uq_new _IA_UQ_NEW
    local _fnd; _fnd="$(jq -r --argjson s "$s" --argjson x "$x" --argjson q "$_uq_new" 'def topic: if test("^\\[fix-code\\]") then "code-findings,test-findings\t"
            elif test("^\\[fix-design\\]") then "design-findings\t" else "design-findings,test-findings,code-findings\t" end;
        def bare: sub("^\\[fix-(code|design)\\][[:space:]]*"; "");
        (.[]? | tostring | topic + "The issue requires this and the change does not meet it: " + bare),
        ($s[] | tostring | topic + "Not sure this requirement is met: " + bare),
        ($x[] | tostring | (if test("^\\[fix-test\\]") then "test-findings\t" else "code-findings\t" end)
            + "The change does this and no requirement asks for it: " + sub("^\\[fix-test\\][[:space:]]*"; "")),
        ($q[] | "design-findings,test-findings,code-findings\tThe issue is unclear here, and issue-acceptance judged by the assumption: " + .)' \
        <<< "$u" 2>/dev/null | stage_findings_route_each "$dir" issue-acceptance design-findings "$_IA_FCODE")"
    u="$(jq -c 'map(tostring | sub("^\\[fix-(code|design)\\][[:space:]]*"; ""))' <<< "$u" 2>/dev/null || printf '%s' "$u")"
    [[ "$s" == "[]" ]] || s="$(jq -c 'map(tostring | sub("^\\[fix-(code|design)\\][[:space:]]*"; ""))' <<< "$s" 2>/dev/null || printf '%s' "$s")"
    x="$(jq -c 'map(tostring | sub("^\\[fix-test\\][[:space:]]*"; ""))' <<< "$x" 2>/dev/null || printf '%s' "$x")"
    # ADR-068 §6: what it did about each finding it was given (_IA_ANSWERS),
    # and how many it was shown when it was asked this time.
    local _data _ia_a="[]" _ia_af="{}"
    [[ ${#_IA_ANSWERS[@]} -gt 0 ]] && _ia_a="$(_ia_json_list "${_IA_ANSWERS[@]}")"
    zb_answers_findings_json_v _ia_af _IA_ANSWERS
    _data="$(jq -nc --argjson u "$u" --argjson s "$s" --argjson x "$x" --argjson fnd "${_fnd:-[]}" --arg j "$j" --argjson a "$_ia_a" --argjson uq "${_IA_UQ_JSON:-[]}" --argjson af "$_ia_af" \
        --argjson ud "${_IA_UQ_DROPPED:-[]}" --arg un2 "${_IA_UQ_NOTES:-}${_IA_HANDOFF_NOTES:-}" \
        --arg known "${_IA_ANS_KNOWN:-0}" --argjson fs "${_ZB_ANS_SHOWN:-0}" --arg un "${_ZB_ANS_MISSING:-}" \
        '{unmet: $u, unsure: $s, findings: $fnd} + (if ($x | length) > 0 then {unasked: $x} else {} end) + (if $j == "" then {} else {judgement: $j} end)
         + (if ($a | length) > 0 then {answers: $a} else {} end)
         + (if ($af | length) > 0 then {answer_findings: $af} else {} end)
         + (if ($uq | length) > 0 then {unclear: $uq} else {} end)
         + (if ($ud | length) > 0 then {unclear_dropped: $ud} else {} end)
         + ($un2 | split("\n") | map(select(length > 0)) | if length > 0 then {notes: .} else {} end)
         + (if $known == "1" then {findings_shown: $fs} + (if $un != "" then {unanswered: ($un | split("\n"))} else {} end) else {} end)' 2>/dev/null)"
    [[ -n "$_data" ]] || _data='{}'
    if ! stage_result_write "$dir/issue-acceptance-result.json" "$o" "$r" "$_data"; then
        _ia_emit "issue_acceptance.result.write_failed" "dir=$dir"
    fi
    local _body="- every requirement the issue states is met by the change"
    # #2452: the unmet requirements are findings, each sent to the stages that
    # can fix it; listed here they would reach every stage that reads this.
    [[ "$u" != "[]" || "$s" != "[]" || "$x" != "[]" ]] && _body="$(jq -r --argjson s "$s" '(if length > 0 then "- \(length) requirement(s) not met — each is a finding, sent to the stages that can fix it" else empty end), (if ($x | length) > 0 then "- \($x | length) part(s) of the change no requirement asks for — each is a finding, sent to the stages that can fix it" else empty end), ($s[] | "- NOT SURE: " + .)' <<< "$u" 2>/dev/null || printf -- '- see result')"
    if [[ "$j" == unreadable ]] || [[ "$o" != pass && "$o" != fail ]]; then
        _body="- the change was not judged against the issue"
    fi
    if [[ "${_IA_ANS_KNOWN:-0}" == 1 ]]; then
        local _ia_sa=""; zb_answers_summary_v _ia_sa _IA_ANSWERS; _body+=$'\n'"$_ia_sa"
    fi
    stage_summary_write "$dir/issue-acceptance-summary.md" "issue-acceptance" "$o" "$r" "$_body"
}

# ─── issue_acceptance_run <stage_id> <state_file> ────────────────────────────
# ADR-054 §4: rc is binary; the verdict lives in the result.
_IA_ANSWERS=() _IA_ANS_KNOWN=0
issue_acceptance_run() {
    # The check splits its item lists on blanks, whatever its caller's IFS.
    local IFS=$' \t\n'
    local stage_id="${1:-issue-acceptance}"; : "$stage_id"
    _IA_ANSWERS=(); _IA_ANS_KNOWN=0; _IA_HANDOFF_NOTES=""
    local state_file="${2:-}"
    local art="${ZBUILD_ARTIFACT_DIR:-}"
    [[ -n "$art" ]] || { [[ -n "$state_file" ]] && art="$(dirname "$state_file")/artifacts"; }
    [[ -n "$art" ]] || return 1
    mkdir -p "$art" 2>/dev/null || true
    # #2571 (ADR-072 §3): the questions its last result carries, for this call
    # to judge; a result written before they are judged keeps them.
    _ia_unclear_carried_load "${art%/}/issue-acceptance-result.json"

    # #2364: each piece of earlier work found by what it contains.
    # shellcheck disable=SC2034  # change and test_verdict are read by _ia_judge (lib/items.sh)
    local design_f diff_f tests_f issue="" acc="" change="" test_verdict=""
    issue="$(earlier_issue_text "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    design_f="$(earlier_acceptance_contract "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    diff_f="$(earlier_change_patch "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    tests_f="$(earlier_test_run "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"

    if _ia_issue_is_placeholder "$issue"; then
        _ia_emit "issue_acceptance.unreadable_issue" "stage=$stage_id"
        _ia_write "$art" fail \
            "the issue text is absent or a placeholder — the change was not judged against anything" \
            "[]" "[]" unreadable
        return 0
    fi

    # #2304 (ADR-069 §7): the requirements in plain words, by status — never the
    # raw block's tags — with a done one's evidence, cleaned for the model.
    local _root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    [[ -n "$design_f" && -f "$design_f" ]] && declare -f acceptance_requirements_for_judge >/dev/null 2>&1 \
        && acc="$(acceptance_requirements_for_judge "$design_f" "$_root" 2>/dev/null || true)"
    declare -F _zbuild_sanitize_for_llm >/dev/null 2>&1 && [[ -n "$acc" ]] \
        && acc="$(printf '%s\n' "$acc" | _zbuild_sanitize_for_llm)"
    # #2482 (ADR-069 §7): the whole branch's change, from where it started, as
    # the lenses judge it. Build's diff.patch holds this round's work only: on
    # #1805 run 42293991602 the judge called code an earlier round added "not in
    # this incremental DIFF", and design took it for the code from before.
    # #2507 (ADR-072 §7): the judge is pointed at the change — its starting
    # commit and the files it changed — and reads it with git; `_change_fp` is
    # what the change is, for the kept answer.
    local _change_fp=""
    zbuild_change_files_v change _change_fp "$diff_f" "$_root"
    # shellcheck disable=SC2034  # read by _ia_judge
    [[ -n "$tests_f" && -f "$tests_f" ]] && test_verdict="$(jq -r '.outcome // empty' "$tests_f" 2>/dev/null || true)"

    local tier="T2"
    declare -f resolve_tier >/dev/null 2>&1 \
        && tier="$(resolve_tier issue-acceptance "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"

    local _task _framed
    # #2306 (ADR-070 §4): the issue's requirements as intake numbered them.
    local _reqs="" _lims="" _terms="" _req_f=""
    _req_f="$(earlier_requirements "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    declare -F acceptance_requirements_list >/dev/null 2>&1 && _reqs="$(acceptance_requirements_list "$_req_f")"
    # #2550 (ADR-072 §3): what the change must not do; #2555 (ADR-070): the issue's terms, word for word.
    declare -F acceptance_limits_list >/dev/null 2>&1 && { _lims="$(acceptance_limits_list "$_req_f")"; acceptance_terms_v _terms "$_req_f"; }
    # #2464, #2569, #2574 (ADR-072 §4 §5): a verdict is kept per item while
    # what it judged is unchanged; only the items whose verdict no longer holds
    # are asked (lib/items.sh).
    local _root_q="$_root"
    _ia_judge
}

# _ia_call <task> <want> — the one call for the items in <want> (space
# separated), in _ia_judge's scope: asked again once when its answer cannot be
# used (ADR-060 §6). Sets _IA_RAW (the reply, read whole), _IA_DEPS (the files
# the call opened) and _IA_ANSWERS. rc 1 when the stage's result is already
# written (a failed call, an answer that cannot be used), with _IA_STOP_RC the
# rc the stage returns.
_IA_RAW="" _IA_DEPS=() _IA_STOP_RC=0
_ia_call() {
    local _task="$1" _want="$2" _framed _composed
    _IA_RAW=""; _IA_DEPS=(); _IA_STOP_RC=0
    # ADR-067 §8: the stage's three parts and the engine's blocks, in the one
    # prompt order. A prompt that cannot be composed is not sent.
    # #2458: it judges, so it composes fresh — no notes, and no rule to confirm earlier work.
    if ! _composed="$(stage_prompt_compose_parts --fresh "$_task")"; then
        _ia_write "$art" misconfigured \
            "the prompt could not be composed — the engine's blocks are missing; the change was not judged"
        _IA_STOP_RC=1; return 1
    fi
    _framed="$_composed"
    local _raw="" rc=0 _ask="$_framed" _try _opened _first=""
    _opened="$(mktemp 2>/dev/null)" || _opened=""
    local -x ZBUILD_ROUTER_OPENED_FILE="$_opened"
    # ADR-060 §6: an answer that cannot be used is asked again once, at once,
    # with what was wrong and the answer. A failed call is not asked again.
    for _try in 1 2; do
        _raw=""
        # No 2>/dev/null: the stage-io banner writes to fd 2 (ADR-015 §v4).
        if declare -f route_to_model >/dev/null 2>&1; then
            _raw="$(route_to_model "$tier" "$_ask")" || rc=$?
        else
            rc=1
        fi
        [[ $rc -eq 0 ]] || break
        # No `| head` (#1886): capture in full, trim in bash. #2460: a wrapped
        # line is read whole.
        zb_reply_join_v _raw "$_raw"
        _ia_parse "$_raw" "$_reqs" "$issue" "$_root_q" "$_lims" "$_want"
        # #2571: what is wrong with a question is asked again once, then costs
        # only that question; a re-ask answered worse leaves the first answer.
        [[ -z "$_IA_PROBLEM" && ( -z "$_IA_UQ_PROBLEM" || $_try -eq 2 ) ]] && break
        [[ -z "$_IA_PROBLEM" ]] && _first="$_raw"
        _ask="$(stage_prompt_reask "$_framed" "$_IA_PROBLEM${_IA_PROBLEM:+${_IA_UQ_PROBLEM:+; }}$_IA_UQ_PROBLEM" "$_raw")"
    done
    [[ $rc -eq 0 && -n "$_IA_PROBLEM" && -n "$_first" ]] && { _raw="$_first"; _ia_parse "$_raw" "$_reqs" "$issue" "$_root_q" "$_lims" "$_want"; }
    # #2598: a requirement still not checkable costs only itself.
    _IA_UNCHECKED_WHY=()
    [[ $rc -eq 0 ]] && _ia_unchecked_to_unmet
    judge_opened_v _IA_DEPS "$_opened"; rm -f "$_opened" 2>/dev/null
    if [[ $rc -ne 0 ]]; then
        local _v="" _reason="" _disp="broken"
        declare -f _llm_router_classify >/dev/null 2>&1 && _llm_router_classify "$rc" _v _reason 2>/dev/null
        declare -f router_reason_disposition >/dev/null 2>&1 \
            && _disp="$(router_reason_disposition "${_reason:-router_rc_nonzero}")"
        _ia_write "$art" "$_disp" \
            "the model call failed (${_reason:-rc=$rc}) — the change was not judged"
        _IA_STOP_RC=1; return 1
    fi
    if [[ -n "$_IA_PROBLEM" ]]; then
        # ADR-054 §6a: the stage ran but its output cannot be used — retry.
        _ia_write "$art" unusable \
            "the answer could not be used, even when asked again: $_IA_PROBLEM — the change was not judged"
        _IA_STOP_RC=0; return 1
    fi
    # ADR-068 §6: a finding it was shown and did not answer stays open.
    _IA_ANSWERS=(); zb_answers_finish _IA_ANSWERS "$_framed" "$_raw" "$art/issue-acceptance-result.json"; _IA_ANS_KNOWN=1
    _IA_RAW="$_raw"
    return 0
}

# _ia_finish <dir> — the judged answer as the stage's result: fail when any
# requirement is unmet or unsure (#2304, ADR-069 §7: one the judge is not sure
# of is never a pass, and is reported as open), pass otherwise.
declare -gA _IA_BARE_WRONG=()
_ia_finish() {
    local _v=pass _u_json _s_json _x_json _fi _fit
    _ia_unclear_settle
    # #2586: an unmet requirement answered with a plain wrong says so.
    for _fi in "${!_IA_UNMET[@]}"; do
        _ia_item_of_finding_v _fit "The issue requires this and the change does not meet it: ${_IA_UNMET[_fi]}"
        [[ -n "$_fit" && -n "${_IA_BARE_WRONG[$_fit]+x}" ]] || continue
        _IA_UNMET[_fi]+=" ¶ answered before: ${_IA_BARE_WRONG[$_fit]//$'\n'/ } — a wrong that quotes no line does not close it: change what it names, or answer wrong quoting the line (<file> | <line>) that shows it met"
    done
    _u_json="$(_ia_json_list "${_IA_UNMET[@]+"${_IA_UNMET[@]}"}")"
    _s_json="$(_ia_json_list "${_IA_UNSURE[@]+"${_IA_UNSURE[@]}"}")"
    _x_json="$(_ia_json_list "${_IA_UNASKED[@]+"${_IA_UNASKED[@]}"}")"
    [[ ${#_IA_UNMET[@]} -gt 0 || ${#_IA_UNASKED[@]} -gt 0 ]] && _v=fail
    if [[ ${#_IA_UNSURE[@]} -gt 0 ]]; then
        _v=fail
        _ia_emit "issue_acceptance.unsure" "count=${#_IA_UNSURE[@]}"
    fi
    _ia_emit "issue_acceptance.judged" "verdict=$_v"
    local _r="judged the change against the issue: every requirement is met"
    [[ "$_v" == fail ]] && _r="judged the change against the issue: $(( ${#_IA_UNMET[@]} + ${#_IA_UNSURE[@]} )) requirement(s) not met or not sure"
    [[ ${#_IA_UNASKED[@]} -gt 0 ]] && _r+=", ${#_IA_UNASKED[@]} part(s) of the change no requirement asks for"
    _ia_write "$1" "$_v" "$_r" "$_u_json" "$_s_json" "" "$_x_json"
}

# _ia_json_list <item>... — the items as a JSON array of strings.
_ia_json_list() {
    [[ $# -gt 0 ]] || { printf '[]'; return 0; }
    printf '%s\n' "$@" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null || printf '[]'
}

issue_acceptance_cleanup() { return 0; }
