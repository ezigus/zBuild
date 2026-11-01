#!/usr/bin/env bash
# plugins/agent/design/lib/coverage.sh — design's second model call: do the
# SPECs cover what the issue asks? (#2369, ADR-040 §5, ADR-070 §4; was the
# spec-coverage stage, #1683.)
#
# Its standard is the issue, which design cannot re-author, so the only way to
# pass is to cover it. The issue reaches the call the way it reaches every
# stage: under Previous work. This file never reads another stage's output.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_DESIGN_COVERAGE_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_COVERAGE_LOADED=1

# The call's three parts, composed with the engine's blocks in the one prompt
# order (ADR-067 §8).
_dcov_prompt_own() {
    cat <<'EOF2'
You are checking whether a DESIGN covers what an ISSUE asked for.

One verdict: what does the issue require that no SPEC covers?

Check EVERY requirement,
and list EVERY one that no SPEC fully covers — not only the first you find — by
its id and words (R-2: <its words>). The design is revised once per round and
fixes only what you list; a gap left out of this answer costs a whole round.

Then look the other way: list EVERY SPEC or scope entry that commits to something
that the issue does not ask for, or that contradicts it.

Then, for every SPEC marked [done], read the code its evidence points at (shown
below): list each one whose code does not do what the SPEC says.

Answer in exactly this form:

VERDICT: covered | uncovered
REASON: <one sentence>
UNCOVERED: <every requirement no SPEC fully covers, separated by semicolons, all on this one line; omit when covered>
OUTSIDE: <every SPEC or scope entry the issue does not ask for or that contradicts it, with why, separated by semicolons, on this one line; omit when none>
DONE_WRONG: <every [done] SPEC whose evidence code does not do what it says, with why, separated by semicolons, on this one line; omit when none>
EOF2
}
# _dcov_done_evidence <design_md> <repo_root> — for each [done] SPEC, the lines
# its evidence points at (a few either side of `file:N`, else the file's start),
# so the check judges the code itself, not the claim (#2445, ADR-069 §2).
_dcov_done_evidence() {
    local design="$1" root="$2" sid item path n from to
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        [[ "$(acceptance_spec_status "$design" "$sid" 2>/dev/null)" == "done" ]] || continue
        while IFS= read -r item; do
            [[ -n "$item" ]] || continue
            path="$item"; n=""
            if [[ "$item" =~ ^(.+):([0-9]+)$ ]]; then path="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"; fi
            [[ "$path" != /* && "/$path/" != *"/../"* && -f "$root/$path" ]] || continue
            if [[ -n "$n" ]]; then from=$(( n > 5 ? n - 5 : 1 )); to=$(( n + 5 )); else from=1; to=30; fi
            printf '%s — %s (lines %s-%s):\n' "$sid" "$item" "$from" "$to"
            sed -n "${from},${to}p" "$root/$path" 2>/dev/null
            printf '\n'
        done < <(acceptance_spec_evidence "$design" "$sid" 2>/dev/null)
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
}

# _dcov_prompt_judge <acceptance> <requirements> [scope] [done_evidence]
_dcov_prompt_judge() {
    cat <<EOF2
Two things, shown at the end of this part, and the issue:

REQUIREMENTS — the issue's requirements, numbered R-1, R-2, … by the pipeline.
ACCEPTANCE — the SPEC sentences the design commits to.
The issue itself, in the requester's own words, is under Previous work.

Judge every requirement in REQUIREMENTS by its words. Read the issue for what a
requirement means. A SPEC may say which requirements it covers; check its
words, not only the ids it names.

An issue contains more than requirements — context, rationale, links, history.
Those are not requirements and their absence from the SPECs is not a gap. Judge
what the issue REQUIRES, not everything it mentions.

Several SPECs may cover one requirement together, one thing each: judge every
SPEC that names it, together.

Mapping is not enough: those SPECs together must demand ALL of the requirement.
A set of SPECs that demands less than the requirement — a subset of the cases,
a weaker condition, some of the files, a narrower scope — leaves it uncovered. Name the
requirement as uncovered and say what the SPECs leave out.

You judge the design before any code exists, so your part of each requirement
is the BEHAVIOUR it asks of the software. A requirement about how the change is
verified — that the tests fail on the code from before the change, that the
full suite is green, that the mutation tests run, that the tree is committed
first — can only be judged once the change and its tests exist, and the check
that compares the finished change with the issue judges it there. It does not
go in UNCOVERED.

A SPEC tagged [done] says the code already does it. A requirement it covers
counts as covered: the claim is judged against the code once the change is
built.

REQUIREMENTS:
$2

ACCEPTANCE:
$1

SCOPE — the files the design plans to change:
${3:-(none named)}

CODE THE [done] SPECS' EVIDENCE POINTS AT:
${4:-(no SPEC is marked [done])}
EOF2
}
_dcov_prompt_limits() {
    cat <<'EOF2'
- Do not suggest SPEC text.
- Do not rewrite the design.
- Answer only, in the form above.
EOF2
}

# _design_coverage <design_md> <requirements_text>
# Sets _DESIGN_UNCOVERED (one entry per uncovered requirement) and
# _DESIGN_COV_OUTCOME: empty when the call judged the design, otherwise the
# outcome word for how the call failed (rate_limited, unavailable, unusable,
# misconfigured, broken). rc 0 always.
_design_coverage() {
    local design_md="$1" reqs="$2" tier="${3:-T2}"
    _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_DONE_WRONG=(); _DESIGN_COV_OUTCOME=""
    local acc; acc="$(extract_acceptance_block "$design_md" 2>/dev/null || true)"
    [[ -n "$acc" ]] || return 0

    local framed
    local _scope _done_ev
    _scope="$(acceptance_list_scope "$design_md" 2>/dev/null || true)"
    _done_ev="$(_dcov_done_evidence "$design_md" "${ZBUILD_REPO_ROOT:-$PWD}")"
    if ! framed="$(stage_prompt_compose_text "$(_dcov_prompt_own)" "$(_dcov_prompt_judge "$acc" "$reqs" "$_scope" "$_done_ev")" "$(_dcov_prompt_limits)")"; then
        _DESIGN_COV_OUTCOME=misconfigured
        return 0
    fi
    local raw="" rc=0 rc_file ask="$framed" _try v="" u_line item
    # ADR-060 §6: an answer with no verdict is asked again once, at once, with
    # what was wrong and the answer. A failed call is not asked again.
    for _try in 1 2; do
        rc=0
        # Without a file to keep the call's exit code in, a failed call would read
        # as a verdict (review on PR #2393): the check cannot run.
        if ! rc_file="$(mktemp)" || [[ -z "$rc_file" ]]; then
            _DESIGN_COV_OUTCOME=broken
            return 0
        fi
        # No 2>/dev/null on this call: the stage-io input banner writes to fd 2 and
        # suppressing it breaks ADR-015 §v4's ordering (the #491 defect).
        raw="$(route_to_model "$tier" "$ask"; printf '%s' "$?" > "$rc_file" || true)"
        if [[ -n "$rc_file" && -f "$rc_file" ]]; then
            rc="$(cat "$rc_file" 2>/dev/null || echo 0)"; rm -f "$rc_file" 2>/dev/null || true
        fi

        # The call's rc is classified on every path: a call that printed a readable
        # verdict and then failed still failed (review on PR #2262).
        if [[ "$rc" -ne 0 ]]; then
            local _rv _rr
            _router_rc_classify "$rc" _rv _rr 2>/dev/null || true
            # disposition-ok: the model router is not responding
            _DESIGN_COV_OUTCOME="$(router_reason_disposition "${_rr:-}" 2>/dev/null || true)"
            [[ -n "$_DESIGN_COV_OUTCOME" ]] || _DESIGN_COV_OUTCOME=unavailable
            return 0
        fi

        # No `| head`: SIGPIPE kills the writer under errexit (#1886).
        v="$(grep -oE 'VERDICT:[[:space:]]*(covered|uncovered)' <<< "$raw" || true)"
        v="${v%%$'\n'*}"; v="${v##*[[:space:]]}"
        [[ -n "$v" ]] && break
        ask="$(stage_prompt_reask "$framed" "it has no VERDICT: line saying covered or uncovered" "$raw")"
    done
    if [[ -z "$v" ]]; then
        _DESIGN_COV_OUTCOME=unusable
        return 0
    fi
    # #2445: what lies outside the issue, and [done] claims the code does not
    # bear out, are read whatever the coverage verdict.
    _dcov_list _DESIGN_OUTSIDE OUTSIDE "$raw"
    _dcov_list _DESIGN_DONE_WRONG DONE_WRONG "$raw"
    [[ "$v" == covered ]] && return 0
    u_line="$(grep -E '^UNCOVERED:' <<< "$raw" || true)"
    u_line="${u_line%%$'\n'*}"; u_line="${u_line#UNCOVERED:}"
    while IFS= read -r item; do
        item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] && _DESIGN_UNCOVERED+=("$item")
    done < <(tr ';' '\n' <<< "$u_line")
    # An uncovered verdict that names nothing is still uncovered.
    [[ ${#_DESIGN_UNCOVERED[@]} -gt 0 ]] || _DESIGN_UNCOVERED+=("a requirement (the check did not say which)")
    return 0
}

# _dcov_list <array> <LABEL> <answer> — the ;-separated items on the answer's
# `LABEL:` line, one entry each.
_dcov_list() {
    local -n _dl="$1"
    local line item
    line="$(grep -E "^$2:" <<< "$3" || true)"
    line="${line%%$'\n'*}"; line="${line#"$2":}"
    while IFS= read -r item; do
        item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] && _dl+=("$item")
    done < <(tr ';' '\n' <<< "$line")
    return 0
}

# _design_coverage_findings — the check's answer as design's findings, one per line.
_design_coverage_findings() {
    local x
    for x in ${_DESIGN_UNCOVERED[@]+"${_DESIGN_UNCOVERED[@]}"}; do printf 'The issue asks for this and no SPEC covers it: %s\n' "$x"; done
    for x in ${_DESIGN_OUTSIDE[@]+"${_DESIGN_OUTSIDE[@]}"}; do printf 'the issue does not ask for this, or the design gets it wrong: %s\n' "$x"; done
    for x in ${_DESIGN_DONE_WRONG[@]+"${_DESIGN_DONE_WRONG[@]}"}; do printf 'marked [done], but the code its evidence points at does not do it: %s\n' "$x"; done
    return 0
}
