#!/usr/bin/env bash
# scripts/lib/trace.sh — everything a stage produces traces to the work it was
# handed (#2629, ADR-075). One rule, written once, for every stage that makes a
# model call:
#   - by name, read by script (§2): a changed file lies in a design step's
#     areas; a SPEC's covers: names a requirement intake listed;
#   - by meaning, judged by a model (§3): intake's list against the issue,
#     a test line against the SPECs and steps, the change against the
#     requirements, a lens against the issue — each check is given the rule.
# What traces to nothing is taken out, or the stage answers not mine and names
# the stage that must add what asks for it. It is never kept on a condition
# about how it is done.
#
# Sourced library: no set -euo pipefail. Bash only (ADR-065 §5).

[[ -n "${_ZBUILD_TRACE_LOADED:-}" ]] && return 0
_ZBUILD_TRACE_LOADED=1

# zb_trace_covered <path> <areas> — rc 0 when <path> is one of the
# space-separated <areas>, or lies under one that is a folder; any path when
# there is no area. A path that climbs out (..) or starts at / lies in none.
# An area or path is read as written less its marks: backticks or quotes around
# it, a leading ./ (review on #2629); `.` is the whole repository. An area is a
# path, or a folder ending in / — never a pattern.
zb_trace_covered() {
    local p="$1" a
    zb_trace_path_v p "$p"
    [[ "$p" == /* || "$p" == .. || "$p" == ../* || "$p" == */../* || "$p" == */.. ]] && return 1
    [[ -n "$2" ]] || return 0
    local -a areas=(); read -ra areas <<< "$2"   # no pathname expansion: an area is no glob
    for a in ${areas[@]+"${areas[@]}"}; do
        zb_trace_path_v a "$a"
        [[ "$a" == "." || "$a" == "" ]] && return 0
        [[ "$p" == "$a" || "$p" == "${a%/}/"* ]] && return 0
    done
    return 1
}

# zb_trace_path_v <var> <path> — <path> without the marks around it and a
# leading ./ (or ./ alone: `.`).
zb_trace_path_v() {
    local -n _ztp="$1"; local _p="$2"
    while :; do
        case "$_p" in
            \`*\`|\"*\"|\'*\') _p="${_p:1:${#_p}-2}" ;;
            ./?*) _p="${_p#./}" ;;
            ./) _p="." ;;
            *) break ;;
        esac
    done
    _ztp="$_p"
}

# zb_trace_rule_v <var> <what was handed> <who adds to it> — the rule a check
# of a change is given.
zb_trace_rule_v() {
    printf -v "$1" 'Everything here must trace to %s. A test is asked for by what it tests, and a helper or fixture that test reads is part of it. A change to the code is asked for only by %s itself, never by a test that would pass with it: such a test asks for more than it was given, and neither is asked for. What nothing asks for is taken out, or %s adds what asks for it — it is never kept on a condition about how it is done (its size, its place, its form).' "$2" "$2" "$3"
}

# zb_trace_list_rule_v <var> <what was handed> <who adds to it> — the rule a
# check of a list (intake's) is given: it has no tests or code in it.
zb_trace_list_rule_v() {
    printf -v "$1" 'Everything here must trace to %s. What nothing asks for is taken out, or %s adds what asks for it — it is never kept on a condition about how it is done.' "$2" "$3"
}

# zb_trace_finding_v <var> <piece> <what was handed> <who adds to it> — the
# finding for a piece that traces to nothing, in the rule's words.
zb_trace_finding_v() {
    printf -v "$1" '%s traces to no %s — take it out, or, when it must stay, answer not mine: %s must add what asks for it' "$2" "$3" "$4"
}
