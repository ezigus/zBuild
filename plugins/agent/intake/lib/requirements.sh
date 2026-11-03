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

# _ireq_issue_text <issue_json> — the issue as the calls are shown it.
_ireq_issue_text() {
    jq -r '"TITLE: \(.title // "")\n\n\(.body // "")"' <<< "${1:-}" 2>/dev/null
}

_ireq_write_own() {
    cat <<'EOF'
Your job: list every requirement this issue states — each thing the change must
do or deliver, in the issue's own words. A requirement may be written as a
checkbox, a numbered or bulleted item, or a sentence. Context, background,
rationale, links and history are not requirements.

Answer with one line per requirement, in the order the issue gives them:

REQUIREMENT: <id> <the requirement, in the issue's words>

The id names the requirement: a code of 3 or 4 capital letters or digits,
starting with a letter, that says what the requirement is about, a dash, and a
number — LOOP-1 for a requirement about loop state. Requirements about the same
thing share the code and count up: LOOP-1, LOOP-2. Never use an id the issue
itself writes.
EOF
    # #2460, #2462: a list from the last run is where the work starts, and its
    # ids never move.
    [[ -n "${_IREQ_PREV_SHOWN:-}" ]] && cat <<'EOF'

Your list from the last run is shown below the issue, each requirement with its
id: start from it.
- Keep each requirement the issue still states, with the same id, in the same words.
- A requirement shown without an id gets one.
- Leave out any the issue no longer asks for, and say why on its own line:
  REMOVED: <id> — <why>
- A new requirement's number is one more than the highest its code has ever
  had, the removed ids counted. Never use a removed id again.
EOF
    return 0
}

_ireq_check_own() {
    cat <<'EOF'
Your job: check a list of requirements against the issue it was taken from.
Name every requirement the issue states that the list misses, in the issue's
words. A requirement may be written as a checkbox, a numbered or bulleted item,
or a sentence. Context, background, rationale, links and history are not
requirements.

Answer with one line for each requirement the list misses, in this form:

MISSING: <id> <a requirement the list misses, in the issue's words>

or the one line "MISSING: none" when it misses nothing. The id is a code of 3
or 4 capital letters or digits, starting with a letter, that says what the
requirement is about, a dash, and a number: LOOP-1. A requirement about the same
thing as a listed one shares its code, with the number one more than the
highest that code has had, the removed ids counted. Never use an id the list or
the issue already writes, or a removed one.
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
# id (R-1) is shown without it, so the requirement gets an id that describes it.
_ireq_prev_load() {
    _IREQ_PREV_IDS="" _IREQ_PREV_REMOVED="" _IREQ_PREV_SHOWN="" _IREQ_PREV_REMOVED_JSON="[]"
    declare -gA _IREQ_PREV_TEXT=()
    [[ -n "${1:-}" ]] || return 0
    local kind id text why removed=""
    while IFS=$'\x1f' read -r kind id text why; do
        case "$kind" in
            A)  _IREQ_PREV_IDS+="$id "; _IREQ_PREV_TEXT[$id]="$text"
                if zb_id_new_form "$id"; then _IREQ_PREV_SHOWN+="REQUIREMENT: $id $text"$'\n'
                else _IREQ_PREV_SHOWN+="REQUIREMENT: $text"$'\n'; fi ;;
            R)  _IREQ_PREV_REMOVED+="$id "; removed+="- $id — $text (removed: $why)"$'\n' ;;
            J)  _IREQ_PREV_REMOVED_JSON="$id" ;;
        esac
    done < <(jq -r '(.requirements[]? | "A\u001f\(.id)\u001f\(.text | gsub("[[:cntrl:]]"; " "))\u001f"),
                    (.removed[]? | "R\u001f\(.id)\u001f\(.text | gsub("[[:cntrl:]]"; " "))\u001f\(.reason // "" | gsub("[[:cntrl:]]"; " "))"),
                    "J\u001f\([.removed[]?] | tojson)"' <<< "$1" 2>/dev/null)
    [[ -n "$removed" ]] && _IREQ_PREV_SHOWN+=$'\n'"IDS ALREADY REMOVED (never use them again):"$'\n'"$removed"
    return 0
}

# _ireq_parse <LABEL> <reply> — the reply's <LABEL>: lines into _IREQ_IDS,
# _IREQ_TEXTS (parallel arrays) and, for REQUIREMENT, its REMOVED: lines into
# _IREQ_RM_IDS / _IREQ_RM_WHY. A line with no id, or a removal with no reason,
# goes to _IREQ_FORM (plain sentences).
_ireq_parse() {
    local label="$1" line rest re_id='^([A-Za-z][A-Za-z0-9_]*-[0-9]+)[[:space:]]*(—|–|:|-)?[[:space:]]*(.+)$'
    local re_rm='^[[:space:]]*REMOVED:[[:space:]]*([A-Za-z][A-Za-z0-9_]*-[0-9]+)[[:space:]]*(—|–|-|:)?[[:space:]]*(.*[^[:space:]])?[[:space:]]*$'
    _IREQ_IDS=() _IREQ_TEXTS=() _IREQ_RM_IDS=() _IREQ_RM_WHY=() _IREQ_FORM=()
    while IFS= read -r line; do
        if [[ "$label" == REQUIREMENT && "$line" =~ $re_rm ]]; then
            if [[ -n "${BASH_REMATCH[3]}" ]]; then _IREQ_RM_IDS+=("${BASH_REMATCH[1]}"); _IREQ_RM_WHY+=("${BASH_REMATCH[3]}")
            else _IREQ_FORM+=("the REMOVED: line for ${BASH_REMATCH[1]} gives no reason — say why it goes: REMOVED: ${BASH_REMATCH[1]} — <why>"); fi
            continue
        fi
        [[ "$line" =~ ^[[:space:]]*$label:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue
        rest="${BASH_REMATCH[1]}"
        [[ "$label" == MISSING && "${rest,,}" == none ]] && continue
        if [[ "$rest" =~ $re_id ]]; then
            _IREQ_IDS+=("${BASH_REMATCH[1]}"); _IREQ_TEXTS+=("${BASH_REMATCH[3]}")
        else
            _IREQ_FORM+=("\"${rest:0:60}\" has no id — write it as $label: <id> <the requirement>")
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
    local prompt="$1" label="$2" ask="$1" reply _try v plain
    local -a _iv=()
    for _try in 1 2; do
        _ireq_call_v reply "$ask" || return 1
        zb_reply_join_v reply "$reply"
        _ireq_parse "$label" "$reply"
        zb_ids_check_v _iv "$3" "$4" "$6 ${_IREQ_IDS[*]+${_IREQ_IDS[*]}}" "${_IREQ_RM_IDS[*]+${_IREQ_RM_IDS[*]}}" "$5" "" 0
        plain=""
        for v in "${_IREQ_FORM[@]+"${_IREQ_FORM[@]}"}"; do plain+="${plain:+; }$v"; done
        for v in "${_iv[@]+"${_iv[@]}"}"; do plain+="${plain:+; }$(zb_id_plain "$v" requirement)"; done
        [[ -z "$plain" ]] && return 0
        ask="$(stage_prompt_reask "$prompt" "$plain" "$reply")"
    done
    _INTAKE_REQ_OUTCOME=unusable
    return 1
}

# _intake_requirements_json_v <var> <issue_json> — requirements.json for an
# issue fetched as {title, body}, written and checked by the model, into <var>.
# The last run's list (_INTAKE_PREV_REQ_JSON) is where it starts. rc 1, with
# _INTAKE_REQ_OUTCOME set, when a call fails or its answer cannot be used.
# Sets _INTAKE_REQ_CHANGES: what was added and removed since the last list.
_intake_requirements_json_v() {
    local -n _irj="$1"; shift
    _irj=""; _INTAKE_REQ_OUTCOME=""; _INTAKE_REQ_CHANGES=""
    local issue prompt i listed
    local -a ids=() texts=() rm_ids=() rm_why=()
    issue="$(_ireq_issue_text "${1:-}")"
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

    listed=""
    for i in "${!ids[@]}"; do listed+="REQUIREMENT: ${ids[i]} ${texts[i]}"$'\n'; done
    # shellcheck disable=SC2124  # a space-separated list, not an array
    local _removed_now="$_IREQ_PREV_REMOVED${rm_ids[*]+${rm_ids[*]}}"
    [[ -n "${_removed_now// }" ]] && listed+=$'\n'"IDS ALREADY REMOVED (never use them again): $_removed_now"
    prompt="$(stage_prompt_compose_text --fresh "$(_ireq_check_own)" \
        "ISSUE:"$'\n'"$issue"$'\n\n'"THE LIST:"$'\n'"$listed" "$(_ireq_limits)")" \
        || { _INTAKE_REQ_OUTCOME=misconfigured; return 1; }
    _ireq_call_parsed "$prompt" MISSING "${ids[*]}" "$_removed_now" "$issue" "${ids[*]}" || return 1
    ids+=("${_IREQ_IDS[@]+"${_IREQ_IDS[@]}"}"); texts+=("${_IREQ_TEXTS[@]+"${_IREQ_TEXTS[@]}"}")

    # #2462: the ids the issue's own words write — labels of the issue's, never
    # ours. Kept with the list, so design refuses them as SPEC ids without
    # reading the issue again.
    local _new="" _rm="" _iss="" _s="$issue" _re='[A-Z][A-Z0-9][A-Z0-9][A-Z0-9]?-[0-9]+'
    while [[ "$_s" =~ $_re ]]; do
        [[ "$_iss" == *$'\n'"${BASH_REMATCH[0]}"$'\n'* ]] || _iss+=$'\n'"${BASH_REMATCH[0]}"$'\n'
        _s="${_s#*"${BASH_REMATCH[0]}"}"
    done
    for i in "${!ids[@]}"; do _new+="${ids[i]}"$'\x1f'"${texts[i]}"$'\n'; done
    for i in "${!rm_ids[@]}"; do _rm+="${rm_ids[i]}"$'\x1f'"${_IREQ_PREV_TEXT[${rm_ids[i]}]:-}"$'\x1f'"${rm_why[i]}"$'\n'; done
    _irj="$(jq -nc --arg n "$_new" --arg r "$_rm" --arg iss "$_iss" --argjson carry "$_IREQ_PREV_REMOVED_JSON" '
        def rows($s): $s | split("\n") | map(select(length > 0) | split("\u001f")
            | map(gsub("[[:cntrl:]]"; " ") | gsub("^\\s+|\\s+$"; "")));
        (rows($r) | map({id: .[0], text: .[1], reason: .[2]})) as $now
        | {schema_version: 1, source: "model",
           requirements: (rows($n) | map({id: .[0], text: .[1]})),
           removed: ($carry + $now),
           issue_ids: ($iss | split("\n") | map(select(length > 0)))}')"
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
