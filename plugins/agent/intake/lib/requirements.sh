#!/usr/bin/env bash
# plugins/agent/intake/lib/requirements.sh — the issue's requirements as one
# fixed, engine-numbered list (#2306, ADR-070 §1, §2; #2445).
#
# Every later stage reads this list instead of re-reading the issue's prose for
# itself. A model call writes it from the issue alone, and a second model call
# checks it against the issue; what the check says is missing is added. Each
# call has one turn and is given only the issue, so neither reads the code.
# #2462 (ADR-070 §1): each id describes its requirement and never moves — the
# rules are scripts/lib/item-ids.sh's, checked here. No id is one the issue's
# own words write (on #2035, "SPEC-2" in the issue meant a test label, and three
# stages read it as design's own SPEC-2).
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_INTAKE_REQUIREMENTS_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_REQUIREMENTS_LOADED=1
# #2460: a reply is read in whole units; loaded here too, for a caller that
# sources this file alone.
declare -F zb_reply_join_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/reply-units.sh" 2>/dev/null || true
# shellcheck source=../../../../scripts/lib/item-ids.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/item-ids.sh"
# shellcheck source=../../../../scripts/lib/trace.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/trace.sh"
# #2477: the engine and fingerprint a kept list is checked against.
# shellcheck source=../../../../scripts/lib/judge.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/judge.sh"
# #2569: a MISSING line is held to the issue's words.
# shellcheck source=missing-quote.sh
source "${BASH_SOURCE[0]%/*}/missing-quote.sh"
# #2571 (ADR-070 §1, ADR-069 §12): what intake finds unclear, in the one form.
# shellcheck source=unclear.sh
source "${BASH_SOURCE[0]%/*}/unclear.sh"
# #2482 (ADR-001): intake's id prefix, from its manifest — every requirement
# id starts with it, so no SPEC's id is ever the same.
zb_id_prefix_v _IREQ_PX "${BASH_SOURCE[0]%/*}/../manifest.yaml"
# #2603 (ADR-070 §1): a limit is not a requirement, so its id has a prefix of
# its own: the manifest's limit_id_prefix, which zb_id_prefixes_check counts as
# taken, so no stage's id_prefix can be the same.
zb_id_prefix_v _IREQ_LX "${BASH_SOURCE[0]%/*}/../manifest.yaml" limit_id_prefix
[[ -n "$_IREQ_LX" ]] || _IREQ_LX="LM"
# The other kinds' prefixes, so a corrected id leaves them off (item-ids.sh).
_ZB_ID_OTHER_PX="$_IREQ_PX $_IREQ_LX"

# _ireq_issue_text <issue_json> — the issue as the calls are shown it.
_ireq_issue_text() {
    jq -r '"TITLE: \(.title // "")\n\n\(.body // "")"' <<< "${1:-}" 2>/dev/null
}

_ireq_write_own() {
    cat <<EOF
Your job: list every requirement this issue states — each thing the change must
do or deliver, in the issue's own words. A requirement may be written as a
checkbox, a numbered or bulleted item, or a sentence. Context, background,
rationale, links and history are not requirements. Nor is a note about how or
when to do the work — the order to do it in, what not to run it alongside, when
to start it: no change to the code can show it is met.

Answer with one line per requirement, in the order the issue gives them:

REQUIREMENT: <id> <the requirement, in the issue's words>

When the issue says not to do something, decide which it is:
- Something the change must keep doing, which a test can show: write it as a
  requirement. "The old rules stay as they are" is
  REQUIREMENT: ${_IREQ_PX}RULE-1 The old rules keep working
- A note that another issue covers something ("two runs at once is #2534"):
  it is not a requirement. Leave it out.
- Something the change must not build, which no test can show was not built:
  write it as a limit, on its own line, keeping its "Do not". A limit's id
  starts with ${_IREQ_LX}, not ${_IREQ_PX}:
  LIMIT: ${_IREQ_LX}SCOP-1 Do not <what the change must not build, in the issue's words>

The id names the requirement: ${_IREQ_PX}, then a code of 3 or 4 capital letters
or digits, starting with a letter, that says what the requirement is about, a
dash, and a number — ${_IREQ_PX}LOOP-1 for a requirement about loop state.
Requirements about the same thing share the code and count up: ${_IREQ_PX}LOOP-1,
${_IREQ_PX}LOOP-2. Never use an id the issue itself writes.
When a requirement refers to another of the issue's items by the issue's own
name for it (R1, R1–R5), write the ids of the requirements it means instead:
every later stage sees only this list, never the issue's names.

${ZB_UNCLEAR_RULES}
Write the requirement in the issue's own words all the same.
EOF
    # #2460, #2462: a list from the last run is where the work starts, and its
    # ids never move. #2569: a start, not the whole issue — on #1764 run
    # 44530053809 the call copied its 19 old requirements and missed a new one.
    # #2550 (ADR-069 §1): the numbers, counted by the function intake's id
    # check uses.
    local _idl="" _idll=""; zb_ids_highest_line_v _idl "${_IREQ_PREV_IDS:-}" "${_IREQ_PREV_REMOVED:-}" "$_IREQ_PX" requirement
    zb_ids_highest_line_v _idll "${_IREQ_PREV_IDS:-}" "${_IREQ_PREV_REMOVED:-}" "$_IREQ_LX" limit; _idl+=" For limits: $_idll"
    [[ -n "${_IREQ_PREV_SHOWN:-}" ]] && cat <<EOF

Your list from the last run is shown below the issue, each requirement with its
id. It is a starting point, not the whole issue: read the whole issue for every
requirement it states, and add each one the old list does not have.
- Keep each requirement the issue still states, with the same id, in the same words.
- A requirement shown without an id gets one.
- Leave out any the issue no longer asks for, and say why on its own line:
  REMOVED: <id> — <why>
- $_idl Never use a removed id again.
EOF
    return 0
}

_ireq_check_own() {
    # #2629 (ADR-075 §3): the list traces to the issue, in the rule's words.
    local _idl="" _idll="" _trace=""; zb_trace_list_rule_v _trace "a sentence of the issue" "the issue"; zb_ids_highest_line_v _idl "${_IREQ_CHECK_IDS:-}" "${_IREQ_CHECK_RM:-}" "$_IREQ_PX" requirement
    zb_ids_highest_line_v _idll "${_IREQ_CHECK_IDS:-}" "${_IREQ_CHECK_RM:-}" "$_IREQ_LX" limit; _idl+=" For limits: $_idll"
    cat <<EOF
Your job: check a list of requirements against the issue it was taken from.
Name every requirement the issue states that the list misses, in the issue's
words. A requirement may be written as a checkbox, a numbered or bulleted item,
or a sentence. Context, background, rationale, links and history are not
requirements.

Answer with one line for each requirement the list misses, in this form:

MISSING: <id> <a requirement the list misses, in the issue's words>

The issue's words are its own sentences, copied as written: the whole sentence
or item, never a paraphrase and never a part of a sentence.

or the one line "MISSING: none" when it misses nothing. Something the issue
says the change must not build, which the list misses, is a limit: write it as
LIMIT: ${_IREQ_LX}<code>-<n> Do not <what the change must not build, in the
issue's words>, keeping its "Do not" (or "Never"); a limit's id starts with
${_IREQ_LX}, not ${_IREQ_PX}. Something it says the change must keep doing is a
requirement, and a note that another issue covers something is neither. The id is ${_IREQ_PX}, then
a code of 3 or 4 capital letters or digits, starting with a letter, that says
what the requirement is about, a dash, and a number: ${_IREQ_PX}LOOP-1. A requirement about the same
thing as a listed one shares its code. $_idl Never use an id the list or
the issue already writes, or a removed one.
When a requirement refers to another of the issue's items by the issue's own
name for it (R1, R1–R5), write the ids of the requirements it means instead:
every later stage sees only this list, never the issue's names.

Read the issue literally, not charitably: a listed requirement narrower than the issue's words —
fewer of its cases, a weaker condition, some of its files — misses the rest. Name what it misses as
its own requirement.

A listed item that is not a requirement — a note about how or when to do the
work, such as the order to do it in or what not to run it alongside, which no
change to the code can show is met — gets its own line:

NOT-A-REQUIREMENT: <id> — <why>

A listed item the issue does not state — no sentence of the issue asks for
it — is not a requirement either: give it that line, its why saying what it
adds to the issue. $_trace

An item already removed needs no line: it is shown under ALREADY REMOVED, with
its words and why, and it is not a requirement.
EOF
}

_ireq_limits() {
    cat <<'EOF'
- You are given only the issue. Do not read any file, and do not look at the
  code: what the issue asks for is in its words alone.
- Answer only, in the form above.
EOF
}

# _ireq_call_v <var> <prompt> — one model call; <var> gets the reply. Sets
# _INTAKE_REQ_OUTCOME to the call's outcome word when it fails (rc 1).
_ireq_call_v() {
    local -n _icv="$1"; _icv=""
    local tier="T1" rc=0
    declare -F resolve_tier >/dev/null 2>&1 \
        && tier="$(resolve_tier intake "$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)" 2>/dev/null || printf 'T1')"
    _icv="$(route_to_model "$tier" "$2" </dev/null)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        local _rv _rr
        _router_rc_classify "$rc" _rv _rr 2>/dev/null || true
        _INTAKE_REQ_OUTCOME="$(router_reason_disposition "${_rr:-}" 2>/dev/null || true)"
        [[ -n "$_INTAKE_REQ_OUTCOME" ]] || _INTAKE_REQ_OUTCOME=unavailable
        return 1
    fi
    return 0
}

# _ireq_prev_load <json> — the last run's list, from its requirements.json:
# _IREQ_PREV_IDS (every id), _IREQ_PREV_REMOVED (ids removed in any run),
# _IREQ_PREV_TEXT[id], _IREQ_PREV_REMOVED_JSON (to carry on), and
# _IREQ_PREV_SHOWN, the list as the calls are shown it. #2462: an old position
# id (R-1), or one from before the prefix (#2482), is shown without it, so the
# requirement gets an id of the new form.
_ireq_prev_load() {
    _IREQ_PREV_IDS="" _IREQ_PREV_REMOVED="" _IREQ_PREV_SHOWN="" _IREQ_PREV_REMOVED_JSON="[]" _IREQ_PREV_REMOVED_LINES="" _IREQ_PREV_LIMS=" "
    declare -gA _IREQ_PREV_TEXT=()
    [[ -n "${1:-}" ]] || return 0
    local kind id text why removed=""
    while IFS=$'\x1f' read -r kind id text why; do
        case "$kind" in
            A)  _IREQ_PREV_IDS+="$id "; _IREQ_PREV_TEXT[$id]="$text"
                local _pl=REQUIREMENT; [[ "$why" == L ]] && { _pl=LIMIT; _IREQ_PREV_LIMS+="$id "; }
                if zb_id_new_form "$id" "$_IREQ_PX" || { [[ "$why" == L ]] && zb_id_new_form "$id" "$_IREQ_LX"; }; then _IREQ_PREV_SHOWN+="$_pl: $id $text"$'\n'
                else _IREQ_PREV_SHOWN+="$_pl: $text"$'\n'; fi ;;
            R)  _IREQ_PREV_REMOVED+="$id "; removed+="- $id — $text (removed: $why)"$'\n' ;;
            J)  _IREQ_PREV_REMOVED_JSON="$id" ;;
        esac
    done < <(jq -r '(.requirements[]? | "A\u001f\(.id)\u001f\(.text | gsub("[[:cntrl:]]"; " "))\u001f\(if .limit == true then "L" else "" end)"),
                    (.removed[]? | "R\u001f\(.id)\u001f\(.text | gsub("[[:cntrl:]]"; " "))\u001f\(.reason // "" | gsub("[[:cntrl:]]"; " "))"),
                    "J\u001f\([.removed[]?] | tojson)"' <<< "$1" 2>/dev/null)
    _IREQ_PREV_REMOVED_LINES="$removed"
    [[ -n "$removed" ]] && _IREQ_PREV_SHOWN+=$'\n'"IDS ALREADY REMOVED (never use them again):"$'\n'"$removed"
    return 0
}

# _ireq_issue_labels_v <var> <issue> — the issue's own names for its items: a
# line that starts, after any bullet, number or heading mark and any bold, with
# 1 to 3 capital letters and a number, then a stop ("- **R1.** …", "R2: …").
# Space separated; empty when it names none.
_ireq_issue_labels_v() {
    local -n _iil="$1"; local _l re='^[[:space:]]*(#+[[:space:]]+|[-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)?(\*\*|__)?([A-Z]{1,3}[0-9]{1,3})(\*\*|__)?([.:)]|[[:space:]]+[—–-][[:space:]])'
    _iil=" "
    while IFS= read -r _l; do
        [[ "$_l" =~ $re && "$_iil" != *" ${BASH_REMATCH[3]} "* ]] && _iil+="${BASH_REMATCH[3]} "
    done <<< "$2"
    [[ "$_iil" == " " ]] && _iil=""
    return 0
}

# _ireq_parse <LABEL> <reply> — the reply's <LABEL>: lines into _IREQ_IDS,
# _IREQ_TEXTS (parallel arrays) and, for REQUIREMENT, its REMOVED: lines into
# _IREQ_RM_IDS / _IREQ_RM_WHY. A line with no id, or a removal with no reason,
# goes to _IREQ_FORM (plain sentences).
_ireq_parse() {
    local label="$1" line rest re_id='^([A-Za-z][A-Za-z0-9_]*-[0-9]+)[[:space:]]*(—|–|:|-)?[[:space:]]*(.+)$'
    # #2603: an id in the wrong form (LIMIT-OUT1) is still an id: the id check
    # says what is wrong with it, never "has no id".
    local re_odd='^([A-Z][A-Z0-9_]*-[A-Z0-9_]+|[A-Za-z][A-Za-z0-9_]*[0-9][A-Za-z0-9_]*-[A-Za-z0-9_]+|[A-Za-z][A-Za-z0-9_]*-[A-Za-z_]*[0-9][A-Za-z0-9_]*)()[[:space:]]+(.+)$'
    # (all capitals, or a digit in it — LIMIT-OUT1, LIMSCOPE-1 — never a
    # hyphenated word such as "Read-only")
    local re_rm='^[[:space:]]*REMOVED:[[:space:]]*([A-Za-z][A-Za-z0-9_]*-[0-9]+)[[:space:]]*(—|–|-|:)?[[:space:]]*(.*[^[:space:]])?[[:space:]]*$'
    local re_nr='^[[:space:]]*NOT-A-REQUIREMENT:[[:space:]]*([A-Za-z][A-Za-z0-9_]*-[0-9]+)[[:space:]]*(—|–|-|:)?[[:space:]]*(.*[^[:space:]])?[[:space:]]*$'
    _IREQ_IDS=() _IREQ_TEXTS=() _IREQ_RM_IDS=() _IREQ_RM_WHY=() _IREQ_FORM=() _IREQ_NR_IDS=() _IREQ_NR_WHY=()
    _IREQ_LIMITS=" "
    while IFS= read -r line; do
        # #2550 (ADR-070 §1): an item the issue says not to do is a limit, in
        # either call's answer, and keeps its "Do not".
        if [[ "$line" =~ ^[[:space:]]*LIMIT:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
            rest="${BASH_REMATCH[1]}"
            if [[ ! "$rest" =~ $re_id && ! "$rest" =~ $re_odd ]]; then
                _IREQ_FORM+=("\"${rest:0:60}\" has no id — write it as LIMIT: ${_IREQ_LX:-LM}<code>-<n> Do not <what the change must not do>")
                continue
            fi
            local _lid="${BASH_REMATCH[1]}" _ltx="${BASH_REMATCH[3]}"
            if [[ "${_ltx,,}" =~ ^(do[[:space:]]+not|don\'t|never)[[:space:]] ]]; then
                _IREQ_IDS+=("$_lid"); _IREQ_TEXTS+=("$_ltx"); _IREQ_LIMITS+="$_lid "
            else
                _IREQ_FORM+=("the LIMIT: line for $_lid does not say what the change must not do — write it starting with \"Do not\": LIMIT: $_lid Do not <…>")
            fi
            continue
        fi
        # #2476: the check names a listed item that is not a requirement.
        if [[ "$label" == MISSING && "$line" =~ $re_nr ]]; then
            if [[ -n "${BASH_REMATCH[3]}" ]]; then _IREQ_NR_IDS+=("${BASH_REMATCH[1]}"); _IREQ_NR_WHY+=("${BASH_REMATCH[3]}")
            else _IREQ_FORM+=("the NOT-A-REQUIREMENT: line for ${BASH_REMATCH[1]} gives no reason — NOT-A-REQUIREMENT: ${BASH_REMATCH[1]} — <why>"); fi
            continue
        fi
        if [[ "$label" == REQUIREMENT && "$line" =~ $re_rm ]]; then
            if [[ -n "${BASH_REMATCH[3]}" ]]; then _IREQ_RM_IDS+=("${BASH_REMATCH[1]}"); _IREQ_RM_WHY+=("${BASH_REMATCH[3]}")
            else _IREQ_FORM+=("the REMOVED: line for ${BASH_REMATCH[1]} gives no reason — say why it goes: REMOVED: ${BASH_REMATCH[1]} — <why>"); fi
            continue
        fi
        [[ "$line" =~ ^[[:space:]]*$label:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue
        rest="${BASH_REMATCH[1]}"
        [[ "$label" == MISSING && "${rest,,}" == none ]] && continue
        if [[ "$rest" =~ $re_id || "$rest" =~ $re_odd ]]; then
            _IREQ_IDS+=("${BASH_REMATCH[1]}"); _IREQ_TEXTS+=("${BASH_REMATCH[3]}")
        else
            _IREQ_FORM+=("\"${rest:0:60}\" has no id — write it as $label: ${_IREQ_PX}<code>-<n> <the requirement>")
        fi
    done <<< "$2"
    [[ "$label" == MISSING || ${#_IREQ_IDS[@]} -gt 0 || ${#_IREQ_FORM[@]} -gt 0 ]] \
        || _IREQ_FORM+=("it has no REQUIREMENT: lines — write one line per requirement: REQUIREMENT: <id> <the requirement>")
    return 0
}

# _ireq_call_parsed <prompt> <LABEL> <prev_active> <prev_removed> <issue> <base_ids>
# One call, read and held to the id rules (#2462); asked again once, with what
# was wrong, when it breaks one (ADR-060 §6). <base_ids> are ids already in the
# list a MISSING answer adds to. rc 1 with _INTAKE_REQ_OUTCOME set when the call
# fails or its answer still breaks a rule.
_ireq_call_parsed() {
    local prompt="$1" label="$2" ask="$1" reply _try v plain i labels _ni="" _unq
    _ireq_issue_labels_v labels "$5"
    local -a _iv=()
    for _try in 1 2; do
        _unq=""
        _ireq_call_v reply "$ask" || return 1
        zb_reply_join_v reply "$reply"
        _ireq_parse "$label" "$reply"
        # #2603: requirements are checked with RQ and limits with LM, each
        # against the last list's ids of its kind. A limit kept under an old RQ
        # id is not an RQ id that went missing: it gets an LM one, no REMOVED.
        # The kind is this answer's (and, on the check call, the list's): an
        # old RQ-id limit this issue now makes a requirement is a requirement.
        local _ik=" ${_IREQ_LIMS_NOW:-} $_IREQ_LIMITS " _x
        local _rp="$3" _rn="" _rr="" _ln="" _lr=""
        local -a _xs=()
        _IREQ_OLD_LIMS_GONE=""
        read -ra _xs <<< "${_IREQ_PREV_LIMS:-}"
        for _x in ${_xs[@]+"${_xs[@]}"}; do
            zb_id_new_form "$_x" "$_IREQ_PX" || continue
            [[ " ${_IREQ_IDS[*]+${_IREQ_IDS[*]}} $6 " == *" $_x "* ]] || _IREQ_OLD_LIMS_GONE+="$_x "
        done
        read -ra _xs <<< "$6"
        _xs+=(${_IREQ_IDS[@]+"${_IREQ_IDS[@]}"})
        for _x in ${_xs[@]+"${_xs[@]}"}; do
            if [[ "$_ik" == *" $_x "* ]]; then _ln+="$_x "; else _rn+="$_x "; fi
        done
        for _x in ${_IREQ_RM_IDS[@]+"${_IREQ_RM_IDS[@]}"}; do if [[ "$_ik" == *" $_x "* ]]; then _lr+="$_x "; else _rr+="$_x "; fi; done
        local -a _ivl=()
        zb_ids_check_v _iv "$_rp" "$4" "$_rn" "$_rr $_IREQ_OLD_LIMS_GONE" "$5" "$_IREQ_PX" 0
        zb_ids_check_v _ivl "$3" "$4" "$_ln" "$_lr" "$5" "$_IREQ_LX" 0
        plain=""
        for v in "${_IREQ_NR_IDS[@]+"${_IREQ_NR_IDS[@]}"}"; do
            # #2550: a limit is kept — not dropped as a note (lens review).
            [[ "${_IREQ_LIMS_NOW:-}" == *" $v "* ]] && { _IREQ_FORM+=("$v is a limit — something the change must not do — and is kept: write no NOT-A-REQUIREMENT line for it"); continue; }
            # #2527: never "name a listed id" — on #1805 run 43130129438 that
            # turned a note already removed into the removal of a requirement.
            [[ " $6 " == *" $v "* ]] || _IREQ_FORM+=("NOT-A-REQUIREMENT: $v is not in the list, so leave that line out")
        done
        # A requirement that names one of the issue's own items by its label
        # (#1805 run 42340358110: "Tests for R1–R5" reached checks that never
        # see the issue, and one took R1–R5 for the ids that looked like it).
        for i in "${!_IREQ_TEXTS[@]}"; do
            for v in $labels; do
                [[ "${_IREQ_TEXTS[i]}" =~ (^|[^A-Za-z0-9])$v([^A-Za-z0-9]|$) ]] \
                    && _IREQ_FORM+=("${_IREQ_IDS[i]} writes $v, the issue's own name for one of its items — write the id of the requirement it means instead")
            done
        done
        # #2569 (ADR-070 §1): what the check says is missing is the issue's own
        # sentences, never a paraphrase or a part (#1764 run 44530053809). A
        # limit's "Do not" may be intake's, so a limit is not held to it. The
        # issue is made ready once, however many lines are held to it.
        if [[ "$label" == MISSING ]]; then
            for i in "${!_IREQ_IDS[@]}"; do
                [[ "$_IREQ_LIMITS" == *" ${_IREQ_IDS[i]} "* ]] && continue
                [[ -n "$_ni" ]] || _ireq_issue_norm_v _ni "$5"
                _ireq_in_norm "${_IREQ_TEXTS[i]}" "$_ni" \
                    || _unq+="${_IREQ_IDS[i]} is not in the issue's words: \"${_IREQ_TEXTS[i]:0:100}\""$'\n'
            done
        fi
        # #2571 (ADR-070 §1): an UNCLEAR line the writer raised is in the one
        # form; the check's answers to the carried questions can be used.
        local _usoft=""; _ireq_unclear_reply "$label" "$reply" "$5" _usoft
        # #2550: an id keeps its kind — a limit in the last list stays a limit.
        for i in "${!_IREQ_IDS[@]}"; do
            v="${_IREQ_IDS[i]}"
            if [[ "${_IREQ_PREV_LIMS:-}" == *" $v "* && "$_IREQ_LIMITS" != *" $v "* ]] && zb_id_new_form "$v" "$_IREQ_LX"; then
                _IREQ_FORM+=("$v was a limit in the last list — keep it a LIMIT: line starting \"Do not\", or remove it and give the new item a new id")
            elif [[ "${_IREQ_PREV_IDS:-}" == *"$v "* && "${_IREQ_PREV_LIMS:-}" != *" $v "* && "$_IREQ_LIMITS" == *" $v "* ]]; then
                _IREQ_FORM+=("$v was a requirement in the last list — keep it a REQUIREMENT: line, or remove it and give the limit a new id")
            fi
        done
        for v in "${_IREQ_FORM[@]+"${_IREQ_FORM[@]}"}"; do plain+="${plain:+; }$v"; done
        for v in "${_iv[@]+"${_iv[@]}"}"; do plain+="${plain:+; }$(zb_id_plain "$v" requirement)"; done
        for v in "${_ivl[@]+"${_ivl[@]}"}"; do plain+="${plain:+; }$(zb_id_plain "$v" limit)"; done
        # #2569 review: after the one re-ask, a line still not in the issue's
        # words does not stop the run — it is kept, and intake's result says so.
        if [[ -z "$plain" && ( -z "$_unq$_usoft" || $_try -eq 2 ) ]]; then
            while IFS= read -r v; do if [[ -n "$v" ]]; then _INTAKE_REQ_NOTES+="$v — kept as the check wrote it"$'\n'; fi; done <<< "$_unq"
            return 0
        fi
        while IFS= read -r v; do
            if [[ -n "$v" ]]; then plain+="${plain:+; }$v — copy the requirement from the issue as it is written, whole sentences, never a paraphrase or a part of a sentence"; fi
        done <<< "$_unq"
        [[ -n "$_usoft" ]] && plain+="${plain:+; }$_usoft"
        ask="$(stage_prompt_reask "$prompt" "$plain" "$reply")"
    done
    _INTAKE_REQ_OUTCOME=unusable
    # #2550 (lens review): the rule the last answer still broke, for the result.
    _INTAKE_REQ_WHY="$plain"
    return 1
}

# _ireq_input_fp_v <var> <issue> — the fingerprint of what the list is written
# from (#2477, ADR-070 §1): the engine, the issue as the calls are shown it, and
# intake's own instructions as written. Comments are not in it: the list never
# reads them. `declare -f` prints a body as the running bash formats it, so a
# new bash makes the calls once more: an extra call, never a missed one.
_ireq_input_fp_v() {
    local -n _iif="$1"; local _iif_e _iif_t
    judge_engine_v _iif_e
    _iif_t="$(declare -f _ireq_write_own _ireq_check_own _ireq_limits)"
    judge_fp_v _iif "$_iif_e"$'\n'"$2"$'\n'"$_iif_t"
}

# _ireq_terms_v <var> <issue_text> — the issue's ## Terms section, word for
# word, with no model (#2555, ADR-070): the lines under a `## Terms` or
# `### Terms` heading (any case, a colon allowed), up to the next heading,
# without the blank lines around them. A heading inside a code fence is text,
# and a carriage return (a CRLF body) is dropped.
_ireq_terms_v() {
    local -n _itv="$1"; local _l _in=0 _fence=0 _out="" _re='^##(#)?[[:space:]]+[Tt][Ee][Rr][Mm][Ss]:?[[:space:]]*$'
    _itv=""
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%$'\r'}"
        if [[ "$_l" == '```'* ]]; then
            _fence=$(( 1 - _fence ))
        elif (( ! _fence )); then
            if (( ! _in )); then [[ "$_l" =~ $_re ]] && _in=1; continue; fi
            [[ "$_l" =~ ^\#{1,3}[[:space:]] ]] && break
        fi
        (( _in )) && _out+="$_l"$'\n'
    done <<< "$2"
    while [[ "$_out" == $'\n'* ]]; do _out="${_out#$'\n'}"; done
    while [[ "$_out" == *$'\n' ]]; do _out="${_out%$'\n'}"; done
    _itv="$_out"
}

# _intake_requirements_json_v <var> <issue_json> — requirements.json for an
# issue fetched as {title, body}, written and checked by the model, into <var>.
# The last run's list (_INTAKE_PREV_REQ_JSON) is where it starts. rc 1, with
# _INTAKE_REQ_OUTCOME set, when a call fails or its answer cannot be used.
# Sets _INTAKE_REQ_CHANGES: what was added and removed since the last list.
_intake_requirements_json_v() {
    local -n _irj="$1"; shift
    _irj=""; _INTAKE_REQ_OUTCOME=""; _INTAKE_REQ_CHANGES=""; _INTAKE_REQ_NOTES=""
    _IREQ_UQ_NEW=(); _IREQ_UQ_DROP=(); _IREQ_UQ_BAD=()
    local issue prompt i listed
    local -a ids=() texts=() rm_ids=() rm_why=()
    issue="$(_ireq_issue_text "${1:-}")"
    local _terms=""; _ireq_terms_v _terms "$issue"
    # #2477: an unchanged issue under the same engine and instructions gives the
    # same list, so the last one is kept and no model is asked.
    local _ifp=""; _INTAKE_REQ_KEPT=""
    _ireq_input_fp_v _ifp "$issue"
    if [[ -n "$_ifp" && "${_INTAKE_PREV_REQ_JSON:-}" =~ \"input_fp\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" \
          && "${BASH_REMATCH[1]}" == "$_ifp" ]]; then
        _irj="$_INTAKE_PREV_REQ_JSON"; _INTAKE_REQ_KEPT=1
        # #2555: a list kept from before terms were copied gets them now.
        if [[ -n "$_terms" || "$_irj" == *'"terms"'* ]]; then
            _irj="$(jq -c --arg t "$_terms" 'if $t == "" then del(.terms) else . + {terms: $t} end' <<< "$_irj" 2>/dev/null || printf '%s' "$_irj")"
        fi
        _INTAKE_REQ_CHANGES='{"added":[],"removed":[]}'
        declare -F emit_event >/dev/null 2>&1 && emit_event "intake.requirements.kept" "plugin=intake" 2>/dev/null
        return 0
    fi
    _ireq_prev_load "${_INTAKE_PREV_REQ_JSON:-}"
    # #2458: intake has no tools and its reply is its output, so both its calls
    # compose fresh — no notes, and no rule to confirm earlier work.
    local _judged="ISSUE:"$'\n'"$issue"
    [[ -n "$_IREQ_PREV_SHOWN" ]] && _judged+=$'\n\n'"YOUR LIST FROM THE LAST RUN:"$'\n'"$_IREQ_PREV_SHOWN"
    prompt="$(stage_prompt_compose_text --fresh "$(_ireq_write_own)" "$_judged" "$(_ireq_limits)")" \
        || { _INTAKE_REQ_OUTCOME=misconfigured; return 1; }
    _ireq_call_parsed "$prompt" REQUIREMENT "$_IREQ_PREV_IDS" "$_IREQ_PREV_REMOVED" "$issue" "" || return 1
    ids=("${_IREQ_IDS[@]+"${_IREQ_IDS[@]}"}"); texts=("${_IREQ_TEXTS[@]+"${_IREQ_TEXTS[@]}"}")
    rm_ids=("${_IREQ_RM_IDS[@]+"${_IREQ_RM_IDS[@]}"}"); rm_why=("${_IREQ_RM_WHY[@]+"${_IREQ_RM_WHY[@]}"}")
    # #2603: an old RQ-id limit this list does not keep is removed, so its id
    # stays taken (a limit's id now starts with LM).
    local _og
    for _og in ${_IREQ_OLD_LIMS_GONE:-}; do rm_ids+=("$_og"); rm_why+=("a limit, now under an LM id or no longer listed (#2603)"); done
    local _lims="$_IREQ_LIMITS"

    listed=""
    for i in "${!ids[@]}"; do
        if [[ "$_lims" == *" ${ids[i]} "* ]]; then listed+="LIMIT: ${ids[i]} ${texts[i]}"$'\n'
        else listed+="REQUIREMENT: ${ids[i]} ${texts[i]}"$'\n'; fi
    done
    # shellcheck disable=SC2124  # a space-separated list, not an array
    local _removed_now="$_IREQ_PREV_REMOVED${rm_ids[*]+${rm_ids[*]}}"
    # #2527 (ADR-070 §1): each removed item with its words and why, so the check
    # sees a note is already gone rather than naming it again.
    local _rm_lines="$_IREQ_PREV_REMOVED_LINES"
    for i in "${!rm_ids[@]}"; do
        _rm_lines+="- ${rm_ids[i]} — ${_IREQ_PREV_TEXT[${rm_ids[i]}]:-} (removed: ${rm_why[i]})"$'\n'
    done
    [[ -n "${_removed_now// }" ]] && listed+=$'\n'"ALREADY REMOVED (not requirements; never use their ids again):"$'\n'"$_rm_lines"
    local _IREQ_CHECK_IDS="${ids[*]+${ids[*]}}" _IREQ_CHECK_RM="$_removed_now" _IREQ_LIMS_NOW="$_lims"
    # #2571: the questions intake carried, judged against the issue as it is now.
    local _uqb=""; zb_unclear_judge_block_v _uqb "${_IREQ_UQ_CARRIED:-}"; [[ -n "$_uqb" ]] && _uqb=$'\n'"$_uqb"
    prompt="$(stage_prompt_compose_text --fresh "$(_ireq_check_own)" \
        "ISSUE:"$'\n'"$issue"$'\n\n'"THE LIST:"$'\n'"$listed$_uqb" "$(_ireq_limits)")" \
        || { _INTAKE_REQ_OUTCOME=misconfigured; return 1; }
    # ADR-017 §12 (#2507): the call intake's manifest lists as `check`.
    local -x ZBUILD_ROUTE_CALL=check
    _ireq_call_parsed "$prompt" MISSING "${ids[*]}" "$_removed_now" "$issue" "${ids[*]}" || return 1
    unset ZBUILD_ROUTE_CALL
    ids+=("${_IREQ_IDS[@]+"${_IREQ_IDS[@]}"}"); texts+=("${_IREQ_TEXTS[@]+"${_IREQ_TEXTS[@]}"}")
    _lims+="${_IREQ_LIMITS# }"
    # #2476: what the check says is not a requirement leaves the list, kept as
    # removed with its words and why, so it never comes back.
    local -A _txt_of=()
    for i in "${!ids[@]}"; do _txt_of[${ids[i]}]="${texts[i]}"; done
    if [[ ${#_IREQ_NR_IDS[@]} -gt 0 ]]; then
        local -a _ki=() _kt=()
        for i in "${!ids[@]}"; do
            [[ " ${_IREQ_NR_IDS[*]} " == *" ${ids[i]} "* ]] || { _ki+=("${ids[i]}"); _kt+=("${texts[i]}"); }
        done
        ids=("${_ki[@]+"${_ki[@]}"}"); texts=("${_kt[@]+"${_kt[@]}"}")
        rm_ids+=("${_IREQ_NR_IDS[@]}"); rm_why+=("${_IREQ_NR_WHY[@]}")
    fi

    # #2462: the ids the issue's own words write — labels of the issue's, never
    # ours. Kept with the list, so design refuses them as SPEC ids without
    # reading the issue again.
    local _new="" _rm="" _iss="" _s="$issue" _re='[A-Z][A-Z0-9]{2,5}-[0-9]+'
    while [[ "$_s" =~ $_re ]]; do
        [[ "$_iss" == *$'\n'"${BASH_REMATCH[0]}"$'\n'* ]] || _iss+=$'\n'"${BASH_REMATCH[0]}"$'\n'
        _s="${_s#*"${BASH_REMATCH[0]}"}"
    done
    for i in "${!ids[@]}"; do
        _new+="${ids[i]}"$'\x1f'"${texts[i]}"; [[ "$_lims" == *" ${ids[i]} "* ]] && _new+=$'\x1f'L
        _new+=$'\n'
    done
    for i in "${!rm_ids[@]}"; do _rm+="${rm_ids[i]}"$'\x1f'"${_IREQ_PREV_TEXT[${rm_ids[i]}]:-${_txt_of[${rm_ids[i]}]:-}}"$'\x1f'"${rm_why[i]}"$'\n'; done
    _irj="$(jq -nc --arg n "$_new" --arg r "$_rm" --arg iss "$_iss" --arg fp "$_ifp" --arg terms "$_terms" --argjson carry "$_IREQ_PREV_REMOVED_JSON" '
        def rows($s): $s | split("\n") | map(select(length > 0) | split("\u001f")
            | map(gsub("[[:cntrl:]]"; " ") | gsub("^\\s+|\\s+$"; "")));
        (rows($r) | map({id: .[0], text: .[1], reason: .[2]})) as $now
        | {schema_version: 1, source: "model",
           requirements: (rows($n) | map({id: .[0], text: .[1]} + (if .[2] == "L" then {limit: true} else {} end))),
           removed: ($carry + $now),
           issue_ids: ($iss | split("\n") | map(select(length > 0)))}
        + (if $fp != "" then {input_fp: $fp} else {} end)
        + (if $terms != "" then {terms: $terms} else {} end)')"
    [[ -n "$_irj" ]] || return 1
    # #2460, #2462: what changed since the last list, by id.
    if [[ -n "${_INTAKE_PREV_REQ_JSON:-}" ]]; then
        _INTAKE_REQ_CHANGES="$(jq -c --argjson p "$_INTAKE_PREV_REQ_JSON" --argjson c "$_IREQ_PREV_REMOVED_JSON" '
            ([$p.requirements[]?.id]) as $old | ([$c[]?.id]) as $was
            | {added: [.requirements[] | select(.id as $i | $old | index([$i]) | not)],
               removed: [.removed[] | select(.id as $i | $was | index([$i]) | not)]}' <<< "$_irj" 2>/dev/null || true)"
    fi
    return 0
}

# _intake_write_requirements <artifact_dir> <issue_json> — writes
# <artifact_dir>/requirements.json. rc 1 when it cannot be built or written;
# _INTAKE_REQ_OUTCOME then says why when a model call failed.
_intake_write_requirements() {
    local art="${1:-}" json
    [[ -n "$art" ]] || return 1
    _intake_requirements_json_v json "${2:-}" || return 1
    atomic_write "$art/requirements.json" <<< "$json"
}
