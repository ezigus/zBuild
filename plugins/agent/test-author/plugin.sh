#!/usr/bin/env bash
# plugins/agent/test-author/plugin.sh — authors acceptance assertions from the
# SPEC, before build implements against them (#2022, ADR-036, ADR-054).
#
# Kind: agent  Tier: T2 (config.tier_default)
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TEST_AUTHOR_LOADED:-}" ]] && return 0
_ZBUILD_TEST_AUTHOR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-summary.sh"
_TA_ROOT="$_ZBUILD_PLUGIN_ROOT"

# plugin-bootstrap.sh supplies helpers + artifact-render ONLY; a plugin that
# needs the event bus or the router sources them itself, as its header states. Without
# this the guard below could never pass in production — every dispatch wrote
# disposition=unavailable and no assertion was ever authored (#2060).
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_TA_ROOT/core/event-bus/event-bus.sh"
# route.sh also brings resolve_tier (tier-resolve.sh); route_to_model is the
# dependency this source exists for. (_llm_router_classify, consulted below,
# comes from llm-agent.sh, not from here.)
# shellcheck source=../../../core/router/route.sh
source "$_TA_ROOT/core/router/route.sh"

# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_TA_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_TA_ROOT/scripts/lib/llm-agent.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$_TA_ROOT/scripts/lib/stage-result.sh"
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_TA_ROOT/scripts/lib/earlier-output.sh"
# shellcheck source=./lib/record.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/lib/record.sh"
# #2370: test-author checks its own assertions against their SPECs; the
# assertion finder lives in acceptance-coverage.sh.
# shellcheck source=../../../scripts/lib/acceptance-coverage.sh
source "$_TA_ROOT/scripts/lib/acceptance-coverage.sh"
# shellcheck source=./lib/correspondence.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/lib/correspondence.sh"

_ta_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }


# _ta_drop_stale_tags <design.md> <repo_root> — strip THIS issue's tags whose
# SPEC number is not in this contract (#2174): they are left over from an
# earlier design of the same issue. Under an issue only [#<issue>/SPEC-n] tags
# are ever considered — a legacy [SPEC-n] or another issue's [#N/SPEC-n] belongs
# to other work and is never touched (#1845 stripped #1328's [SPEC-1..10] from a
# shared test before tags carried their issue). With no issue (a --goal run) the
# bare legacy tags are this run's, as before.
_ta_drop_stale_tags() {
    local design="$1" repo="$2" ids tf n=0 before after re issue="${ZBUILD_ISSUE:-}"
    declare -F acceptance_list_spec_ids >/dev/null 2>&1 || return 0
    ids="$(acceptance_list_spec_ids "$design" 2>/dev/null | sed 's/^SPEC-//' | tr '\n' ' ')"
    [[ -n "$ids" ]] || return 0
    if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
        re="\\[#${issue}/SPEC-[0-9]+\\]"
    else
        re='\[SPEC-[0-9]+\]'
    fi
    while IFS= read -r tf; do
        [[ -n "$tf" && -f "$repo/$tf" ]] || continue
        before="$(grep -cE "$re" "$repo/$tf" 2>/dev/null || true)"
        # The pattern goes in through ENVIRON, not -v: awk processes escapes in
        # a -v value, and `\[` would become a bracket expression.
        ZB_TAG_RE="$re" awk -v ids=" $ids " '
            { line=$0; out="";
              re = ENVIRON["ZB_TAG_RE"]
              while (match(line, re " ?")) {
                  tag=substr(line, RSTART, RLENGTH); num=tag
                  sub(/^.*SPEC-/, "", num); gsub(/[^0-9]/, "", num)
                  keep = index(ids, " " num " ") > 0
                  out = out substr(line, 1, RSTART-1) (keep ? tag : "")
                  line = substr(line, RSTART+RLENGTH)
              }
              print out line }' "$repo/$tf" > "$repo/$tf.zb-tags" 2>/dev/null \
            && replace_keep_mode "$repo/$tf.zb-tags" "$repo/$tf" || rm -f "$repo/$tf.zb-tags"
        after="$(grep -cE "$re" "$repo/$tf" 2>/dev/null || true)"
        [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]] && n=$(( n + before - after ))
    done < <(acceptance_list_testfiles "$design" 2>/dev/null || true)
    (( n > 0 )) && _ta_emit "test_author.stale_tags_dropped" "count=$n"
    return 0
}

# _ta_write_result <dir> <outcome> <reason> <n_specs>
# ADR-054 §6 (#2366): one outcome from the engine's list — `pass` when the
# author finished, otherwise how it stopped. A router timeout is not a poor
# authoring pass, it is no authoring pass at all.
_ta_write_result() {
    local dir="$1" o="$2" r="$3" n="${4:-0}" fnd="${5:-[]}"
    mkdir -p "$dir" 2>/dev/null || true
    # #2189: the author REPORTS the testfiles it owns; the engine denies every
    # other stage edits to them from this report (never from design.md by path).
    local _owned="[]" _design
    _design="$(earlier_acceptance_contract "$dir" 2>/dev/null || true)"
    if [[ -s "$_design" ]] && declare -F acceptance_list_testfiles >/dev/null 2>&1; then
        local _ol; _ol="$(acceptance_list_testfiles "$_design" 2>/dev/null || true)"
        _owned="$(jq -Rnc '[inputs | select(length > 0)] | unique' <<< "$_ol" 2>/dev/null || true)"
        [[ -n "$_owned" ]] || _owned="[]"
    fi
    # The author's work lands in the repo, not in this file — so the result
    # carries each testfile's content hash as it stands now. An attempt that
    # wrote changes this artifact; one that wrote nothing leaves it identical,
    # which is what the engine's per-attempt progress check compares (#2186).
    local _tfh="{}" _repo="${ZBUILD_REPO_ROOT:-$_TA_ROOT}" _tf _h
    if [[ "$_owned" != "[]" ]]; then
        local _tf_pairs=""
        while IFS= read -r _tf; do
            [[ -n "$_tf" && -f "$_repo/$_tf" ]] || continue
            _h="$(git hash-object "$_repo/$_tf" 2>/dev/null || true)"
            [[ -n "$_h" ]] && _tf_pairs+="$_tf"$'\t'"$_h"$'\n'
        done < <(jq -r '.[]' <<< "$_owned" 2>/dev/null)
        _tfh="$(jq -Rnc '[inputs | select(length > 0) | split("\t") | {(.[0]): .[1]}] | add // {}' <<< "$_tf_pairs" 2>/dev/null || true)"
        [[ -n "$_tfh" ]] || _tfh="{}"
    fi
    local _data
    _data="$(jq -nc --argjson n "${n:-0}" --argjson o "${_owned:-[]}" --argjson t "$_tfh" --argjson f "$fnd" \
        '{specs_covered: $n, owned_files: $o, testfiles: $t}
         + (if ($f | length) > 0 then {findings: $f} else {} end)')"
    if ! stage_result_write "$dir/test-author-result.json" "$o" "$r" "$_data"; then
        _ta_emit "test_author.result.write_failed" "dir=$dir"
    fi
    stage_summary_write "$dir/test-author-summary.md" "test-author" "$o" "$r" \
        "$(printf -- '- SPECs in the contract: %s\n- assertions are authored from the SPEC text, never from the implementation' "${n:-0}")"
}

# ─── test_author_run <stage_id> <state_file> [resolved_inputs] ───────────────
# ADR-054 §4: rc is binary. rc=0 = "my result file is on disk"; rc=1 = "I
# failed". Nothing else.
# _ta_commit_testfiles <design.md> <repo_root> <message>
# #2188: the author's testfiles are committed — after a pass AND after a call
# that stopped mid-write — so the next attempt, or a new session restoring the
# work branch, continues from them instead of from nothing. Only the testfiles
# the contract names are staged. Best-effort: a commit failure never fails the
# stage, it only leaves the work uncommitted as before.
_ta_commit_testfiles() {
    local design="$1" repo="$2" msg="$3" tf
    local -a files=()
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
    while IFS= read -r tf; do
        [[ -n "$tf" && -e "$repo/$tf" ]] && files+=("$tf")
    done < <(acceptance_list_testfiles "$design" 2>/dev/null || true)
    [[ ${#files[@]} -gt 0 ]] || return 0
    git -C "$repo" add -- "${files[@]}" 2>/dev/null || return 0
    git -C "$repo" diff --cached --quiet -- "${files[@]}" 2>/dev/null && return 0
    git -C "$repo" commit -q --no-verify --author "zbuild-pipeline <pipeline@local>" \
        -m "$msg" -- "${files[@]}" >/dev/null 2>&1 || return 0
    _ta_emit "test_author.committed" "files=${#files[@]}"
}

test_author_run() {
    local stage_id="${1:-test-author}"; : "$stage_id"
    local state_file="${2:-}"

    local art
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        art="$(dirname "$state_file")/artifacts"
    else
        art="${ZBUILD_ARTIFACT_DIR:-}"
    fi
    [[ -n "$art" ]] || return 1
    mkdir -p "$art" 2>/dev/null || true

    local repo="${ZBUILD_REPO_ROOT:-$_TA_ROOT}"
    # #2364: the acceptance contract, found by what it contains.
    local design; design="$(earlier_acceptance_contract "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"

    if [[ ! -f "$design" ]] || ! declare -f acceptance_list_spec_ids >/dev/null 2>&1; then
        _ta_emit "test_author.no_contract" "reason=no_design"
        _ta_write_result "$art" "pass" \
            "no acceptance contract — there is no contract to author against" 0
        return 0
    fi

    # ── The contract, and ONLY the contract ─────────────────────────────────
    # #1978: naming a SPEC by id while its requirement sits 130 lines away is
    # how an assertion comes to test something else. The text travels with the id.
    local sid n=0 n_done=0 spec_block=""
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        local _st _txt _tfs
        _st="$(acceptance_spec_status "$design" "$sid" 2>/dev/null || true)"
        # #2304 (ADR-069 §6): the code already does a done requirement — no test.
        if [[ "$_st" == "done" ]]; then n_done=$(( n_done + 1 )); continue; fi
        _txt="$(acceptance_spec_text "$design" "$sid" 2>/dev/null || true)"
        _tfs="$(acceptance_list_testfiles_for_spec "$design" "$sid" 2>/dev/null | tr '\n' ' ')"
        spec_block="${spec_block}- ${sid} [${_st:-code}] ${_txt}"$'\n'
        # #2269: what the status demands of the test, in before-and-after words.
        if [[ "$_st" == "no-code" ]]; then
            spec_block="${spec_block}    its test must pass after this change; it need not fail before"$'\n'
        else
            spec_block="${spec_block}    its test must FAIL on the code as it was before this change, and pass after"$'\n'
        fi
        spec_block="${spec_block}    tag: $(acceptance_spec_tag "$sid")"$'\n'
        spec_block="${spec_block}    testfile(s): ${_tfs}"$'\n'
        n=$(( n + 1 ))
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)

    if [[ "$n" -eq 0 && "$n_done" -gt 0 ]]; then
        _ta_emit "test_author.no_contract" "reason=all_done"
        _ta_write_result "$art" "pass" \
            "every requirement is already done — there is no test to write" 0
        return 0
    fi
    if [[ "$n" -eq 0 ]]; then
        _ta_emit "test_author.no_contract" "reason=no_specs"
        _ta_write_result "$art" "pass" \
            "the acceptance block declares no SPECs — nothing to author" 0
        return 0
    fi

    # The prompt is the SPEC text and the target paths. It carries NO diff, no
    # build summary, no implementation of any kind: an author that can read the
    # code will describe the code, which is the very defect this stage exists to
    # remove. The omission is the mechanism, and it is asserted in the test.
    # #2243: existing checks the design says this change makes wrong. Updating
    # them to the new behaviour is part of this job — no other stage may (build
    # is read-only on testfiles; #1842 evaded one instead). Only these become
    # editable; any other foreign tag stays untouchable.
    local sup_block="" _sp _st _sw
    while IFS=$'\t' read -r _sp _st _sw; do
        [[ -n "$_sp" ]] || continue
        sup_block="${sup_block}- ${_sp} ${_st}: ${_sw}"$'\n'
    done < <(acceptance_list_supersedes "$design" 2>/dev/null || true)
    local sup_section=""
    if [[ -n "$sup_block" ]]; then
        sup_section="
EXISTING CHECKS THIS CHANGE MAKES WRONG — these assertions exist already and assert the old behaviour. Update each to the behaviour this change introduces (the requirements above), keeping its tag. These are the only foreign tags you may change:
${sup_block}"
    fi

    # #2308: the stage's own text in three parts (ADR-067 §8).
    local _spec_tag1; _spec_tag1="$(acceptance_spec_tag SPEC-1)"
    local prompt
    prompt="$(cat <<EOF
Your job: write the acceptance assertions for the requirements below, in the language and idiom the target repository already uses.

## What you own
An assertion for every requirement below, written to its testfile(s)${sup_block:+, and the existing checks listed below brought up to the new behaviour}.

Each assertion must be able to FAIL: if the requirement were not met, your assertion must not pass. Check the new value or file itself — the output, the field, the file's content — not only that the step finished without an error: a test that only checks that something ran passes on the old code too.

A test that needs data another part of the code writes — a file, a record, a field, a message — makes it with that code: open the code that writes it and use what it really produces. Never make such data by hand: hand-made data holds whatever its author assumed.

Tag each assertion with the tag shown for its SPEC, exactly as shown, in the assertion's label — e.g. ${_spec_tag1}. Tags that carry THIS issue's number are yours: one already there whose SPEC is not in this contract is stale from an earlier design — remove the tag and keep the assertion.

Some of these testfile(s) may already hold assertions from an earlier attempt at this contract: keep what is right, finish what is missing, fix what is wrong.

Work one testfile at a time: read only what that file's SPECs need, write it to disk, and only then move on — write each file before you plan the next. Do not plan every SPEC up front. Your call has a time limit; a file already written survives it and is continued by the next attempt, and a plan that was never written is lost.

You will be called again until you are done: what you wrote stays on disk and the next call picks up from it. When EVERY SPEC below has its assertion written to disk, end your reply with a line containing only:
LOOP_COMPLETE

## What you judge against
The requirements below. Write what each requirement DEMANDS, not what some implementation might do.

REQUIREMENTS:
${spec_block}${sup_section}
## What you must not do
- You cannot see the implementation, and you must not guess at it.
- Write or amend only the testfile(s) named above${sup_block:+, and the existing checks listed above}. Do not write, modify or stub any implementation file.
- A tag that does not carry this issue's number (a bare [SPEC-n], or one naming another issue) belongs to other work: leave it as it is${sup_block:+, except on the existing checks listed above}.
EOF
)"

    # #2370: the limits are kept apart from the rest so each round can add what
    # the check found before them.
    local _ta_text="${prompt%%$'\n'## What you must not do*}"
    local _ta_limits="## What you must not do${prompt#*$'\n'## What you must not do}"
    local _rounds; _rounds="$(yaml_get "$(dirname "${BASH_SOURCE[0]}")/manifest.yaml" config.check_rounds 2>/dev/null || true)"
    [[ "$_rounds" =~ ^[1-9][0-9]*$ ]] || _rounds=2
    local _round=1 _found=""

    local tier="T2" rc=0
    declare -f resolve_tier >/dev/null 2>&1 && tier="$(resolve_tier test-author "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"

    if ! declare -f route_to_model_loop >/dev/null 2>&1; then
        _ta_write_result "$art" "broken" \
            "no router available to author assertions" "$n"
        return 1
    fi
    # #2225: like build, the author works in a loop until it says it is done —
    # each call with its own time limit, each starting from the testfiles the
    # earlier calls left on disk; they are committed when the loop ends, done
    # or not. (Not between calls: the loop measures progress against the last
    # commit, so a mid-loop commit reads as "no progress".) One call for the
    # whole contract overran on every 15–25 SPEC contract (#1846, #1837).
    local max_iter; max_iter="$(_route_resolve_max_iterations 2>/dev/null || printf '10')"
    [[ "$max_iter" =~ ^[0-9]+$ && "$max_iter" -gt 0 ]] || max_iter=10
    [[ -n "${ZBUILD_CYCLE_ITER:-}" && "$max_iter" -gt 15 ]] && max_iter=15
    while :; do
    # ADR-067 §8: the stage's three parts and the engine's blocks — its budget
    # and notes file among the engine's rules — in the one prompt order.
    local _composed
    if ! _composed="$(stage_prompt_compose_parts "${_ta_text}${_found}
${_ta_limits}")"; then
        _ta_write_result "$art" "misconfigured" \
            "the prompt could not be composed — the engine's blocks are missing" "$n"
        return 1
    fi
    prompt="$_composed"
    local prompt_file
    prompt_file="$(mktemp "$(zbuild_engine_tmpdir 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}")/zb-ta-prompt.XXXXXX")" || {
        _ta_write_result "$art" "broken" "could not create the prompt file" "$n"
        return 1
    }
    printf '%s' "$prompt" > "$prompt_file"
    # The loop shows the model only its own testfiles' progress — never the
    # implementation, which this stage must not see (#2022; review #2229).
    local _ctx; _ctx="$( { acceptance_list_testfiles "$design"; acceptance_list_supersedes "$design" | cut -f1; } 2>/dev/null \
        | awk 'NF && !seen[$0]++' | paste -sd, - || true)"
    route_to_model_loop "$tier" "$prompt_file" "$repo" "$max_iter" \
        --context-paths "${_ctx:-.zbuild-no-testfiles}" || rc=$?
    rm -f "$prompt_file"
    local _end="${_ROUTE_LOOP_TERMINATED_REASON:-}"

    if [[ "$_end" != "done_sentinel" ]]; then
        # ADR-054 §6: this stage only says HOW it stopped; the one mapping from
        # a router or loop reason to its word decides which (#2187). A loop that
        # used every call without finishing is `out_of_turns`.
        local _reason="$_end" _disp="" _v=""
        if [[ "$rc" -eq 130 ]]; then
            _reason="signal"
        elif [[ -z "$_end" ]]; then
            # The loop never got going (no model CLI, a bad tier): classify its
            # rc the way single-shot calls are (review #2229).
            _router_rc_classify "$rc" _v _reason 2>/dev/null || _reason="router_rc_nonzero"
        fi
        if [[ "$_reason" == "error" ]]; then
            # The loop's own machinery failed (e.g. git diff) — zBuild's defect,
            # not an outside service (review #2229).
            _disp="broken"
        else
            _disp="$(router_reason_disposition "$_reason")"
        fi
        _ta_write_result "$art" "$_disp" \
            "the author did not finish (${_reason}) — what it wrote is kept for the next attempt" "$n"
        _ta_commit_testfiles "$design" "$repo" "test-author: partial assertions (${_reason}) — continued by the next attempt"
        return 1
    fi

    # #2174: the stage enforces its own invariant — a [SPEC-n] tag whose
    # number is not in THIS contract is stale (an earlier contract's), and the
    # gate would match it instead of the authored assertion. Drop the tag,
    # keep the assertion. #2370: then test-author checks its own assertions —
    # does each one test what its SPEC says? What does not goes back to its
    # model, within its rounds.
    _ta_drop_stale_tags "$design" "$repo"
    _ta_correspondence "$design" "$repo" "$tier"
    if [[ -n "$_TA_CORR_OUTCOME" ]]; then
        declare -f assertion_integrity_record >/dev/null 2>&1 && assertion_integrity_record "$art" "$repo"
        _ta_commit_testfiles "$design" "$repo" "test-author: acceptance assertions for $n SPEC(s), unchecked"
        _ta_write_result "$art" "$_TA_CORR_OUTCOME" \
            "the check that each assertion tests its SPEC could not be run ($_TA_CORR_OUTCOME)" "$n"
        return 0
    fi
    [[ ${#_TA_CORR_FINDINGS[@]} -eq 0 ]] && break
    _ta_emit "test_author.checks.failed" "round=$_round" "rounds=$_rounds" "findings=${#_TA_CORR_FINDINGS[@]}"
    if (( _round >= _rounds )); then
        declare -f assertion_integrity_record >/dev/null 2>&1 && assertion_integrity_record "$art" "$repo"
        _ta_commit_testfiles "$design" "$repo" "test-author: acceptance assertions for $n SPEC(s), still failing their check"
        _ta_write_result "$art" "fail" \
            "${#_TA_CORR_FINDINGS[@]} assertion(s) still do not test what their SPEC says after $_rounds rounds" "$n" \
            "$(printf '%s\n' "${_TA_CORR_FINDINGS[@]}" | stage_findings_json)"
        return 0
    fi
    _round=$(( _round + 1 ))
    _found="$(printf '\n### What the check of your assertions found (round %s of %s)\nYour assertions were checked against their requirements, and these do not hold. Fix each one in its testfile; keep what already holds.\n' "$_round" "$_rounds"; printf -- '- %s\n' "${_TA_CORR_FINDINGS[@]}")"
    done

    # The digests are recorded HERE, by the author, immediately after authoring.
    # Recording anywhere else would baseline someone else's edit as if it were
    # the author's — which is precisely what the guard exists to catch.
    # (#2174: stale tags were dropped before the check above, so the digests
    # are of the assertions as checked.)
    declare -f assertion_integrity_record >/dev/null 2>&1 \
        && assertion_integrity_record "$art" "$repo"

    _ta_commit_testfiles "$design" "$repo" "test-author: acceptance assertions for $n SPEC(s)"
    _ta_emit "test_author.authored" "specs=$n"
    _ta_write_result "$art" "pass" \
        "authored acceptance assertions for $n SPEC(s) from the design contract" "$n"
    return 0
}

test_author_cleanup() { return 0; }
