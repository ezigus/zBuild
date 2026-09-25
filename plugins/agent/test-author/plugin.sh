#!/usr/bin/env bash
# plugins/agent/test-author/plugin.sh — authors acceptance assertions from the
# SPEC, before build implements against them (#2022, ADR-036, ADR-054).
#
# Kind: agent  Tier: T2 (config.tier_default)
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TEST_AUTHOR_LOADED:-}" ]] && return 0
_ZBUILD_TEST_AUTHOR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
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
# shellcheck source=../../../plugins/tool/assertion-integrity/plugin.sh
source "$_TA_ROOT/plugins/tool/assertion-integrity/plugin.sh" 2>/dev/null || true

_ta_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# _test_author_budget_guidance <max_turns> <timeout_s> — TURN BUDGET + WALL
# CLOCK BUDGET blocks (ADR-063 §1). Each is skipped when its value is 0.
_test_author_budget_guidance() {
    local turns="${1:-0}" secs="${2:-0}"
    if [[ "$turns" =~ ^[0-9]+$ && "$turns" -gt 0 ]]; then
        cat <<EOF
TURN BUDGET (read this — you have a BOUNDED tool-call budget):
- You have about ${turns} tool-call turns for reading the contract and the testfile(s) AND writing every assertion.
- Read the design and each testfile ONCE, then write. Do not explore the repository; the requirements above are complete.
- If an edit is refused, do not retry it another way — write what you can and say which SPECs are unwritten.
- STOP reading and WRITE well before you run out. Assertions for most SPECs beat a full budget spent and none written.
EOF
    fi
    if [[ "$secs" =~ ^[0-9]+$ && "$secs" -gt 0 ]]; then
        cat <<EOF
WALL CLOCK BUDGET (read this — the stage has a hard OS wall-clock timeout):
- This stage has a wall-clock budget of ${secs} seconds total. Estimate elapsed time from your tool-call history and finish writing before ~$(( secs * 70 / 100 ))s.
EOF
    fi
}

# _ta_drop_stale_tags <design.md> <repo_root> — strip `[SPEC-n] ` from the
# contract's testfiles where n is not a SPEC id of this contract (#2174).
_ta_drop_stale_tags() {
    local design="$1" repo="$2" ids tf n=0 before after
    declare -F acceptance_list_spec_ids >/dev/null 2>&1 || return 0
    ids="$(acceptance_list_spec_ids "$design" 2>/dev/null | sed 's/^SPEC-//' | tr '\n' ' ')"
    [[ -n "$ids" ]] || return 0
    while IFS= read -r tf; do
        [[ -n "$tf" && -f "$repo/$tf" ]] || continue
        before="$(grep -cE '\[SPEC-[0-9]+\]' "$repo/$tf" 2>/dev/null || true)"
        awk -v ids=" $ids " '
            { line=$0; out="";
              while (match(line, /\[SPEC-[0-9]+\] ?/)) {
                  tag=substr(line, RSTART, RLENGTH); num=tag; gsub(/[^0-9]/, "", num)
                  keep = index(ids, " " num " ") > 0
                  out = out substr(line, 1, RSTART-1) (keep ? tag : "")
                  line = substr(line, RSTART+RLENGTH)
              }
              print out line }' "$repo/$tf" > "$repo/$tf.zb-tags" 2>/dev/null \
            && mv -f "$repo/$tf.zb-tags" "$repo/$tf" || rm -f "$repo/$tf.zb-tags"
        after="$(grep -cE '\[SPEC-[0-9]+\]' "$repo/$tf" 2>/dev/null || true)"
        [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]] && n=$(( n + before - after ))
    done < <(acceptance_list_testfiles "$design" 2>/dev/null || true)
    (( n > 0 )) && _ta_emit "test_author.stale_tags_dropped" "count=$n"
    return 0
}

# _ta_write_result <dir> <verdict> <disposition> <reason> <n_specs>
# ADR-054 §5: one result file, every mandatory key. §6: `disposition` says how
# the STAGE stopped; `verdict` says what it produced. A router timeout is not a
# poor authoring pass, it is no authoring pass at all.
_ta_write_result() {
    local dir="$1" v="$2" d="$3" r="$4" n="${5:-0}"
    mkdir -p "$dir" 2>/dev/null || true
    if ! jq -n --arg v "$v" --arg d "$d" --arg r "$r" --argjson n "${n:-0}" \
        '{result_contract: 2, verdict: $v, disposition: $d, reason: $r,
          data: {specs_covered: $n}}' \
        | atomic_write "$dir/test-author-result.json"; then
        _ta_emit "test_author.result.write_failed" "dir=$dir"
    fi
    stage_summary_write "$dir/test-author-summary.md" "test-author" "$v" "$r" \
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
    local design="$art/design.md"

    if [[ ! -f "$design" ]] || ! declare -f acceptance_list_spec_ids >/dev/null 2>&1; then
        _ta_emit "test_author.no_contract" "reason=no_design"
        _ta_write_result "$art" "complete" "complete" \
            "no design.md acceptance block — there is no contract to author against" 0
        return 0
    fi

    # ── The contract, and ONLY the contract ─────────────────────────────────
    # #1978: naming a SPEC by id while its requirement sits 130 lines away is
    # how an assertion comes to test something else. The text travels with the id.
    local sid n=0 spec_block=""
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        local _txt _cls _tfs
        _txt="$(acceptance_spec_text "$design" "$sid" 2>/dev/null || true)"
        _cls="$(acceptance_spec_classifier "$design" "$sid" 2>/dev/null || true)"
        _tfs="$(acceptance_list_testfiles_for_spec "$design" "$sid" 2>/dev/null | tr '\n' ' ')"
        spec_block="${spec_block}- ${sid} [${_cls:-change}] ${_txt}"$'\n'
        spec_block="${spec_block}    testfile(s): ${_tfs}"$'\n'
        n=$(( n + 1 ))
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)

    if [[ "$n" -eq 0 ]]; then
        _ta_emit "test_author.no_contract" "reason=no_specs"
        _ta_write_result "$art" "complete" "complete" \
            "the acceptance block declares no SPECs — nothing to author" 0
        return 0
    fi

    # The prompt is the SPEC text and the target paths. It carries NO diff, no
    # build summary, no implementation of any kind: an author that can read the
    # code will describe the code, which is the very defect this stage exists to
    # remove. The omission is the mechanism, and it is asserted in the test.
    local prompt
    prompt="You are the test author. Write the acceptance assertions for the requirements below, in the language and idiom the target repository already uses.

You cannot see the implementation, and you must not guess at it. Write what the requirement DEMANDS, not what some implementation might do. Each assertion must be able to FAIL: if the requirement were not met, your assertion must not pass.

Tag each assertion with its SPEC id in square brackets, exactly as shown. You own every [SPEC-n] tag in the testfile(s) you write: a tag already there whose number is not in this contract is stale from an earlier contract — remove the tag and keep the assertion.

REQUIREMENTS:
${spec_block}
Some of these testfile(s) may already hold assertions from an earlier attempt at this contract: keep what is right, finish what is missing, fix what is wrong.

Write or amend only the testfile(s) named above. Do not write, modify or stub any implementation file."

    # ADR-063 §1 (#2170): the budget reaches the prompt from the values that
    # enforce it — never a literal. Same shape as design/plan/review-lens.
    local _ta_max_turns=0 _ta_timeout_s=0
    declare -F _route_resolve_max_turns >/dev/null 2>&1 && _ta_max_turns="$(_route_resolve_max_turns 2>/dev/null || printf '0')"
    declare -F _route_resolve_timeout >/dev/null 2>&1 && _ta_timeout_s="$(_route_resolve_timeout 2>/dev/null || printf '0')"
    [[ "$_ta_max_turns" =~ ^[0-9]+$ ]] || _ta_max_turns=0
    [[ "$_ta_timeout_s" =~ ^[0-9]+$ ]] || _ta_timeout_s=0
    local _ta_guidance
    _ta_guidance="$(_test_author_budget_guidance "$_ta_max_turns" "$_ta_timeout_s")"
    [[ -n "$_ta_guidance" ]] && prompt+=$'\n\n'"$_ta_guidance"

    local tier="T2" rc=0
    declare -f resolve_tier >/dev/null 2>&1 && tier="$(resolve_tier test-author "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || printf 'T2')"

    if ! declare -f route_to_model >/dev/null 2>&1; then
        _ta_write_result "$art" "degraded" "broken" \
            "no router available to author assertions" "$n"
        return 1
    fi
    route_to_model "$tier" "$prompt" >/dev/null 2>&1 || rc=$?

    if [[ $rc -ne 0 ]]; then
        # ADR-054 §6: the engine's closed set decides what happens next; this
        # stage only says HOW it stopped. _llm_router_classify owns the mapping
        # so a new rc does not need a new opinion here.
        local _v="" _reason="" _disp=""
        if declare -f _llm_router_classify >/dev/null 2>&1; then
            _llm_router_classify "$rc" _v _reason 2>/dev/null || true
        fi
        # #2187: the one mapping from a router failure to its cause word.
        _disp="$(router_reason_disposition "${_reason:-router_rc_nonzero}")"
        _ta_write_result "$art" "degraded" "$_disp" \
            "the model call failed (${_reason:-rc=$rc}) — no assertions were authored" "$n"
        _ta_commit_testfiles "$design" "$repo" "test-author: partial assertions (${_reason:-rc=$rc}) — continued by the next attempt"
        return 1
    fi

    # The digests are recorded HERE, by the author, immediately after authoring.
    # Recording anywhere else would baseline someone else's edit as if it were
    # the author's — which is precisely what the guard exists to catch.
    # #2174: the stage enforces its own invariant — a [SPEC-n] tag whose
    # number is not in THIS contract is stale (an earlier contract's), and the
    # gate would match it instead of the authored assertion. Drop the tag,
    # keep the assertion. Runs before the digests are recorded.
    _ta_drop_stale_tags "$design" "$repo"
    declare -f assertion_integrity_record >/dev/null 2>&1 \
        && assertion_integrity_record "$art" "$repo"

    _ta_commit_testfiles "$design" "$repo" "test-author: acceptance assertions for $n SPEC(s)"
    _ta_emit "test_author.authored" "specs=$n"
    _ta_write_result "$art" "complete" "complete" \
        "authored acceptance assertions for $n SPEC(s) from the design contract" "$n"
    return 0
}

test_author_cleanup() { return 0; }
