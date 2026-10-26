#!/usr/bin/env bash
# plugins/agent/test-author/lib/correspondence.sh — test-author's second model
# call: does each assertion test what its SPEC SAYS? (#2370; was the
# spec-correspondence stage, #2034, ADR-036.)
#
# A passing test proves the implementation satisfies the ASSERTION, never that
# the assertion satisfies the SENTENCE. This judges that link, before any code
# exists, from the requirement and the assertion alone.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TA_CORRESPONDENCE_LOADED:-}" ]] && return 0
_ZBUILD_TA_CORRESPONDENCE_LOADED=1

_ta_sc_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# _sc_prompt <requirement> <assertion>
# Deliberately specific about the task and deliberately starved of the code.
# Naming the failure mode matters: without it the judge evaluates "is this a
# good test?", and a good test that tests the wrong thing sails through.
_sc_prompt() {
    cat <<EOF
You are checking ONE acceptance requirement against ONE test assertion.

## What you own
One judgement: if the ASSERTION passes, does that establish the REQUIREMENT?

Answer in exactly two lines:

VERDICT: corresponds | partial | mismatch | uncheckable
REASON: <one sentence>

  corresponds — passing this assertion would establish the requirement.
  partial     — it tests the right thing, but establishes only part of what
                the requirement promises (one case of several, a narrower
                property, one form where the requirement names two).
  mismatch    — it tests something else, or the reverse of what is required.
  uncheckable — the requirement is too vague to say what would establish it.

Reserve the mismatch verdict for a genuine disagreement between the assertion
and the requirement. An assertion aimed at the right property but narrower in
reach is partial, not mismatch.

## What you judge against
Exactly two things, shown at the end of this part:

REQUIREMENT — a single sentence from a design document.
ASSERTION   — the source of the test assertion tagged as covering it: the lines
              marked >> are the ones tagged for the requirement; the lines
              above them set up the test, and what they do counts.

The failure you are looking for is an assertion that tests something real
and specific, but not what the requirement says — including asserting its
opposite. It will look like reasonable test code. That is expected. The
question is not whether it is a good test. The question is whether it
tests THIS requirement.

REQUIREMENT:
$1

ASSERTION:
$2

## What you must not do
- You cannot see the implementation. Do not guess what it does.
- Do not suggest a fix. Do not rewrite the assertion. Answer only.
EOF
}

# _sc_call <tier> <task> [rc_file] — compose the task and route it. The persona
# (ADR-051) reaches the model through the provider, not this text.
# rc_file: if given, the first non-zero router exit code is kept there (subshell boundary
# prevents a nameref from crossing; a file survives it — same pattern as
# review-lens and other stages that need the rc from inside a command substitution).
_sc_call() {
    local tier="$1" _task="$2" _rc_file="${3:-}" _framed="$2" _raw=""
    # ADR-067 §8: the stage's three parts and the engine's blocks, in the one
    # prompt order. A prompt that cannot be composed is not sent: the call
    # fails as misconfigured (rc 2), the first failure kept like any other.
    local _composed
    if ! _composed="$(stage_prompt_compose_parts "$_framed")"; then
        _ta_sc_emit "test_author.check.prompt_refused" "reason=not_composed"
        if [[ -n "$_rc_file" ]]; then
            local _prev0=0
            [[ -f "$_rc_file" ]] && _prev0="$(cat "$_rc_file" 2>/dev/null || printf '0')"
            [[ "$_prev0" =~ ^[1-9][0-9]*$ ]] || printf '2' > "$_rc_file" 2>/dev/null || true
        fi
        return 0
    fi
    _framed="$_composed"
    # No 2>/dev/null: the stage-io input banner writes to fd 2 (#491). stdin
    # is /dev/null: a model that drains stdin must not eat a caller's stream (#2108).
    if declare -f route_to_model >/dev/null 2>&1; then
        local _call_rc=0
        _raw="$(route_to_model "$tier" "$_framed" </dev/null)" || _call_rc=$?
        # The batch call and every fallback call share one rc file. The FIRST
        # non-zero rc is kept: a later success must not hide an earlier failure
        # (review on PR #2262), and the first failure is the cause — later calls
        # ran on whatever time the first one left.
        if [[ -n "$_rc_file" && "$_call_rc" -ne 0 ]]; then
            local _prev_rc=0
            [[ -f "$_rc_file" ]] && _prev_rc="$(cat "$_rc_file" 2>/dev/null || printf '0')"
            [[ "$_prev_rc" =~ ^[0-9]+$ ]] || _prev_rc=0
            [[ "$_prev_rc" -ne 0 ]] || printf '%s' "$_call_rc" > "$_rc_file" 2>/dev/null || true
        fi
    fi
    printf '%s' "$_raw"
}
# _sc_parse_verdict / _sc_parse_reason <reply-or-line> — the first VERDICT word
# and the REASON text. No `| head` (#1886): capture in full, trim in bash.
_sc_parse_verdict() {
    local v; v="$(grep -oE 'VERDICT:[[:space:]]*(corresponds|partial|mismatch|uncheckable)' <<< "$1" || true)"
    v="${v%%$'\n'*}"; printf '%s' "${v##*[[:space:]]}"
}
_sc_parse_reason() {
    local r; r="$(grep -oE 'REASON:[^|]*' <<< "$1" || true)"
    r="${r%%$'\n'*}"; r="${r#REASON:}"; r="${r#"${r%%[![:space:]]*}"}"; printf '%s' "${r%"${r##*[![:space:]]}"}"
}
# _sc_batch_prompt <ids_arr> <txts_arr> <srcs_arr> (namerefs) — every pair in
# one prompt, one answer line per SPEC (#2143).
_sc_batch_prompt() {
    local -n _bp_ids="$1" _bp_txts="$2" _bp_srcs="$3"
    cat <<'EOF'
You are checking acceptance requirements against the test assertions tagged as covering them, one pair at a time.

## What you own
For EACH pair, one judgement: if the ASSERTION passes, does that establish the REQUIREMENT?

Answer with exactly one line per SPEC, in this form and nothing else — begin each line with that SPEC's identifier from its `###` heading, exactly as written there:

<identifier>: VERDICT: <corresponds, partial, mismatch or uncheckable> | REASON: <one sentence>

  corresponds — passing this assertion would establish the requirement.
  partial     — it tests the right thing, but establishes only part of it.
  mismatch    — it tests something else, or the reverse of what is required.
  uncheckable — the requirement is too vague to say what would establish it.

Reserve mismatch for a genuine disagreement.

## What you judge against
The pairs below, each a REQUIREMENT and the ASSERTION tagged as covering it. In each ASSERTION, the lines marked >> are the ones tagged for the requirement; the lines above them set up the test, and what they do counts. The failure you are looking for is an assertion that tests something real and specific, but not what the requirement says — including its opposite.
EOF
    local _i
    for (( _i=0; _i<${#_bp_ids[@]}; _i++ )); do
        printf '\n### %s\nREQUIREMENT:\n%s\n\nASSERTION:\n%s\n' "${_bp_ids[_i]}" "${_bp_txts[_i]}" "${_bp_srcs[_i]}"
    done
    cat <<'EOF'

## What you must not do
- You cannot see the implementation. Do not guess what it does.
- Do not suggest a fix. Do not rewrite anything.
EOF
}

# _ta_correspondence <design.md> <repo_root> <tier>
# Sets _TA_CORR_FINDINGS (one entry per SPEC whose assertion does not establish
# it: partial, mismatch or uncheckable) and _TA_CORR_OUTCOME: empty when every
# SPEC was judged, otherwise the outcome word for how the check failed — the
# call's own disposition, or unusable when the judge gave no verdict. rc 0.
_ta_correspondence() {
    local design="$1" repo="$2" tier="${3:-T2}"
    _TA_CORR_FINDINGS=(); _TA_CORR_OUTCOME=""
    # #2143: collect every judgeable (requirement, assertion) pair FIRST, judge
    # them in ONE model call, and fall back to a per-SPEC call only for what
    # the batch left unjudged.
    local sid _txt _tfs _src _i
    local -a _ids=() _txts=() _srcs=()
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        [[ "$(acceptance_spec_status "$design" "$sid" 2>/dev/null || true)" == "done" ]] && continue
        _txt="$(acceptance_spec_text "$design" "$sid" 2>/dev/null || true)"
        [[ -n "$_txt" ]] || continue
        _tfs="$(acceptance_list_testfiles_for_spec "$design" "$sid" 2>/dev/null || true)"
        # The whole assertion with its enclosing predicate, comments stripped:
        # a bare tagged line reads as a vacuous test, and a pasted SPEC sentence
        # in a comment would buy a false `corresponds`.
        _src=""
        declare -f acceptance_find_assertion_sources >/dev/null 2>&1 && _src="$(
            # shellcheck disable=SC2086
            acceptance_find_assertion_sources "$repo" "$sid" $_tfs 2>/dev/null || true)"
        # No tagged assertion: nothing to judge here (as before #2370); a missing
        # assertion is the acceptance check's to report.
        [[ -n "$_src" ]] || continue
        _ids+=("$sid"); _txts+=("$_txt"); _srcs+=("$_src")
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    local n=${#_ids[@]}
    [[ $n -gt 0 ]] || return 0

    local -a _verdicts=() _reasons=()
    for (( _i=0; _i<n; _i++ )); do _verdicts+=(""); _reasons+=(""); done
    # A nameref cannot cross a subshell; a file survives it (#2032).
    local _rc_file; _rc_file="$(mktemp)" || _rc_file=""
    [[ -n "$_rc_file" ]] && printf '0' > "$_rc_file" 2>/dev/null || true

    local _batch_raw _line _l
    _batch_raw="$(_sc_call "$tier" "$(_sc_batch_prompt _ids _txts _srcs)" "$_rc_file")"
    for (( _i=0; _i<n; _i++ )); do
        # A glob match, not a regex built from the id (review on #2148).
        _line=""
        while IFS= read -r _l; do
            [[ "$_l" == "${_ids[_i]}:"*"VERDICT:"* ]] && { _line="$_l"; break; }
        done <<< "$_batch_raw"
        [[ -n "$_line" ]] || continue
        _verdicts[_i]="$(_sc_parse_verdict "$_line")"
        _reasons[_i]="$(_sc_parse_reason "$_line")"
    done
    local _one_raw
    for (( _i=0; _i<n; _i++ )); do
        [[ -z "${_verdicts[_i]}" ]] || continue
        _one_raw="$(_sc_call "$tier" "$(_sc_prompt "${_txts[_i]}" "${_srcs[_i]}")" "$_rc_file")"
        _verdicts[_i]="$(_sc_parse_verdict "$_one_raw")"
        _reasons[_i]="$(_sc_parse_reason "$_one_raw")"
    done

    # A call that failed is how the check ended (#2032): its rc, classified.
    local _router_rc=0
    if [[ -n "$_rc_file" && -f "$_rc_file" ]]; then
        _router_rc="$(cat "$_rc_file" 2>/dev/null || echo 0)"; rm -f "$_rc_file" 2>/dev/null || true
    fi
    if [[ "$_router_rc" =~ ^[0-9]+$ && "$_router_rc" -ne 0 ]]; then
        local _rv _rr
        _router_rc_classify "$_router_rc" _rv _rr 2>/dev/null || true
        # disposition-ok: the model router is not responding
        _TA_CORR_OUTCOME="$(router_reason_disposition "${_rr:-}" 2>/dev/null || true)"
        [[ -n "$_TA_CORR_OUTCOME" ]] || _TA_CORR_OUTCOME="unavailable"
        return 0
    fi

    local _unjudged=0
    for (( _i=0; _i<n; _i++ )); do
        case "${_verdicts[_i]:-}" in
            corresponds) ;;
            partial)     _TA_CORR_FINDINGS+=("${_ids[_i]}'s assertion establishes only part of the requirement: ${_reasons[_i]}") ;;
            mismatch)    _TA_CORR_FINDINGS+=("${_ids[_i]}'s assertion does not test what the requirement says: ${_reasons[_i]}") ;;
            uncheckable) _TA_CORR_FINDINGS+=("${_ids[_i]}: it cannot be said what would establish this requirement: ${_reasons[_i]}") ;;
            *)           _unjudged=$(( _unjudged + 1 )) ;;
        esac
    done
    # #2062: a judge with no answer has no basis for "corresponds".
    [[ $_unjudged -gt 0 ]] && _TA_CORR_OUTCOME=unusable
    return 0
}
