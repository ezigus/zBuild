#!/usr/bin/env bash
# plugins/agent/intake/lib/requirements.sh — the issue's requirements as one
# fixed, engine-numbered list (#2306, ADR-070 §1, §2; #2445).
#
# Every later stage reads this list instead of re-reading the issue's prose for
# itself. A model call writes it from the issue alone, and a second model call
# checks it against the issue; what the check says is missing is added. Each
# call has one turn and is given only the issue, so neither reads the code. The
# ids are R-1, R-2, … in order, assigned here: no identifier is taken from the
# issue's words (on #2035, "SPEC-2" in the issue meant a test label, and three
# stages read it as design's own SPEC-2).
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_INTAKE_REQUIREMENTS_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_REQUIREMENTS_LOADED=1

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

REQUIREMENT: <the requirement, in the issue's words>
EOF
}

_ireq_check_own() {
    cat <<'EOF'
Your job: check a list of requirements against the issue it was taken from.
Name every requirement the issue states that the list misses, in the issue's
words. A requirement may be written as a checkbox, a numbered or bulleted item,
or a sentence. Context, background, rationale, links and history are not
requirements.

Answer in exactly this form:

MISSING: <every requirement the list misses, separated by semicolons, on this one line; or "none">
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

# _intake_requirements_json_v <var> <issue_json> — requirements.json for an
# issue fetched as {title, body}, written and checked by the model, into <var>.
# rc 1, with _INTAKE_REQ_OUTCOME set, when a call fails or the list is empty.
_intake_requirements_json_v() {
    local -n _irj="$1"; shift
    _irj=""; _INTAKE_REQ_OUTCOME=""
    local issue reply prompt line item
    local -a reqs=()
    issue="$(_ireq_issue_text "${1:-}")"
    prompt="$(stage_prompt_compose_text "$(_ireq_write_own)" "ISSUE:"$'\n'"$issue" "$(_ireq_limits)")" \
        || { _INTAKE_REQ_OUTCOME=misconfigured; return 1; }
    _ireq_call_v reply "$prompt" || return 1
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*REQUIREMENT:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] && reqs+=("${BASH_REMATCH[1]}")
    done <<< "$reply"
    [[ ${#reqs[@]} -gt 0 ]] || { _INTAKE_REQ_OUTCOME=unusable; return 1; }

    local listed; listed="$(printf -- '- %s\n' "${reqs[@]}")"
    prompt="$(stage_prompt_compose_text "$(_ireq_check_own)" \
        "ISSUE:"$'\n'"$issue"$'\n\n'"THE LIST:"$'\n'"$listed" "$(_ireq_limits)")" \
        || { _INTAKE_REQ_OUTCOME=misconfigured; return 1; }
    _ireq_call_v reply "$prompt" || return 1
    line="$(grep -E '^[[:space:]]*MISSING:' <<< "$reply" || true)"
    line="${line%%$'\n'*}"; line="${line#*MISSING:}"
    while IFS= read -r item; do
        item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" && "${item,,}" != none ]] && reqs+=("$item")
    done < <(tr ';' '\n' <<< "$line")

    _irj="$(printf '%s\n' "${reqs[@]}" | jq -Rsc '
        split("\n") | map(gsub("[[:cntrl:]]"; " ") | gsub("^\\s+|\\s+$"; "") | select(length > 0))
        | {schema_version: 1, source: "model",
           requirements: [to_entries[] | {id: "R-\(.key + 1)", text: .value}]}')"
    [[ -n "$_irj" ]]
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
