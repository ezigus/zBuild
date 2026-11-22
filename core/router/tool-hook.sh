#!/usr/bin/env bash
# core/router/tool-hook.sh [guard...] <deadline_epoch> <notes_file> — Claude
# Code's PreToolUse hook for one model call: it is asked before every tool the
# call (or a subagent it starts) uses, and allows it or refuses it with a reason
# the model reads as the tool's result.
#
# Time is up (ADR-063, amended 2026-11-08, #2503; 2026-11-10, #2517): the
# deadline is the call's time limit; --time-limit and --turn-limit (#2584) are
# the limits it was given, which the warning states. From the first tool call after it, every
# tool but reading, writing or editing the stage's notes file is refused, and
# the model is told to write its notes and give its final reply; the router
# kills the call only a grace later. A deadline of 0 is none. #2543: the notes
# file may be read, since Claude Code refuses to overwrite a file the call has
# not read; a loop call is given its done word (--done-word) and told it has
# not finished, so must not end with it.
#
# Guards (#2507, ADR-017 §12), before the deadline:
#   --git-only           the shell runs only git diff, git log, git show and
#                        git status, with nothing chained and no --output
#   --gh-read            (#2584, read-github) the shell runs only gh's reading
#                        commands: gh api GET (no other method, no field, input
#                        or header; not graphql), gh issue view/list, gh pr
#                        view/list/diff/checks, gh label list, gh repo view, gh
#                        release view/list, gh run view/list; never --web,
#                        nothing chained, nothing that looks like a secret
#   --repo <dir> --code-copy <dir> --test-glob <glob>
#                        reading or searching a file of the working copy
#                        outside the test folders is refused, naming the same
#                        file in the copy of the code from before the change
#                        (ADR-072 §2); files in the test folders and the copy
#                        stay readable
# And always: a subagent asked for by its own model is refused — it runs on the
# call's model (ADR-003); a web search or fetch holding text that looks like a
# secret is refused (ADR-004).
#
# MEASURED on CLI 2.1.319 (#2503, #2507): under --permission-mode
# bypassPermissions a PreToolUse `deny` is honoured and its reason reaches the
# model; the hook sees a subagent's tool calls too; the subagent tool is named
# Agent in the hook's input (Task in --tools).
#
# Claude runs it with the call's tool input as JSON on stdin; it prints nothing
# to allow, or a deny decision. Builtins but for one jq, and only for a tool a
# guard reads.

git_only=0 gh_read=0 code_copy="" repo="" done_word="" time_limit="" turn_limit=""
globs=()
while [[ $# -gt 2 ]]; do
    case "$1" in
        --git-only)   git_only=1; shift ;;
        --gh-read)    gh_read=1; shift ;;
        --repo)       repo="${2%/}"; shift 2 ;;
        --code-copy)  code_copy="${2%/}"; shift 2 ;;
        --test-glob)  globs+=("$2"); shift 2 ;;
        --done-word)  done_word="$2"; shift 2 ;;
        --time-limit) time_limit="$2"; shift 2 ;;
        --turn-limit) turn_limit="$2"; shift 2 ;;
        *) shift ;;
    esac
done
deadline="${1:-0}" notes="${2:-}"
input=""; IFS= read -r -d '' input || true

_deny() {
    local r="$1"
    local LC_ALL=C
    r="${r//\\/\\\\}"; r="${r//\"/\\\"}"
    r="${r//$'\n'/\\n}"; r="${r//$'\r'/\\r}"; r="${r//$'\t'/\\t}"
    r="${r//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/ }"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$r"
    exit 0
}

# _gh_reads <command> — rc 0 when <command> is one of gh's reading commands
# (the --gh-read list above), read word by word; any write is rc 1.
_gh_reads() {
    local IFS=$' \t' i=1 a sub verb m=GET
    local -a w=()
    read -ra w <<< "$1"
    [[ "${w[0]:-}" == gh ]] || return 1
    while [[ "${w[i]:-}" == -R || "${w[i]:-}" == --repo || "${w[i]:-}" == --repo=* ]]; do
        [[ "${w[i]}" == --repo=* ]] && i=$(( i + 1 )) || i=$(( i + 2 ))
    done
    sub="${w[i]:-}" verb="${w[i+1]:-}"
    for a in "${w[@]:i}"; do [[ "$a" == --web || "$a" == -w ]] && return 1; done
    case "$sub $verb" in
        "issue view"|"issue list"|"pr view"|"pr list"|"pr diff"|"pr checks"|"label list"|"repo view"|\
        "release view"|"release list"|"run view"|"run list") return 0 ;;
        "api "*) ;;
        *) return 1 ;;
    esac
    local next="" ep=""
    for a in "${w[@]:i+1}"; do
        if [[ -n "$next" ]]; then m="$a"; next=""; continue; fi
        case "$a" in
            -X|--method) next=1 ;;
            -X*) m="${a#-X}" ;;
            --method=*) m="${a#--method=}" ;;
            -f*|-F*|-H*|--field|--field=*|--raw-field|--raw-field=*|--input|--input=*|--header|--header=*) return 1 ;;
            -*) ;;
            *) [[ -z "$ep" ]] && ep="$a" ;;
        esac
    done
    [[ -z "$next" && "$m" == [Gg][Ee][Tt] && -n "$ep" && "$ep" != graphql ]]
}

tool=""
[[ "$input" =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_]+)\" ]] && tool="${BASH_REMATCH[1]}"

printf -v now '%(%s)T' -1
if [[ "$deadline" =~ ^[0-9]+$ ]] && (( deadline > 0 && now >= deadline )); then
    path=""
    [[ "$tool" == Read || "$tool" == Write || "$tool" == Edit ]] && path="$(jq -r '.tool_input.file_path // ""' <<< "$input" 2>/dev/null)"
    [[ -n "$notes" && -n "$path" && "$path" == "$notes" ]] && exit 0
    # core/router/route.sh looks for this first sentence (_ROUTE_TIME_UP_WORDS).
    why="Time is up: this call has reached its time limit."
    # #2584 (ADR-018): the limits the call was given, as its prompt stated them.
    if [[ "$time_limit" =~ ^[0-9]+$ ]]; then
        if [[ "$turn_limit" =~ ^[1-9][0-9]*$ ]]; then why+=" It was given $time_limit seconds and $turn_limit turns."
        else why+=" It was given $time_limit seconds, with no limit on turns."; fi
    fi
    why+=" Stop the work you were doing."
    [[ -n "$notes" ]] && why+=" You may still use Read, Write or Edit on your notes file, $notes: read your notes file, then write what you found there, in one step."
    why+=" Then give your final reply now, with your answer to every finding you were given."
    [[ -n "$done_word" ]] && why+=" This call has not finished, so do not end your reply with $done_word."
    why+=" Every other tool is refused."
    _deny "$why"
fi

case "$tool" in
    Bash)                          (( git_only || gh_read )) || exit 0 ;;
    Agent|Task)                    ;;
    WebSearch|WebFetch)            ;;
    Read|Grep|Glob)                [[ -n "$code_copy" ]] || exit 0 ;;
    *)                             exit 0 ;;
esac

# The fields a guard reads, one jq, split by the unit separator.
IFS=$'\x1f' read -r -d '' f_cmd f_model f_text f_path < <(jq -j '.tool_input // {} |
    [(.command // ""), (.model // ""), ((.query // "") + " " + (.url // "")),
     (.file_path // .path // "")] | map(tostring) | join("\u001f")' <<< "$input" 2>/dev/null; printf '\0')

case "$tool" in
    Bash)
        c="$f_cmd"
        c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
        ok=""
        (( git_only )) && ok="git diff, git log, git show and git status"
        (( gh_read )) && ok+="${ok:+, and }gh's reading commands — gh api (GET only) with no field, input or header, gh issue view or list, gh pr view, list, diff or checks, gh label list, gh repo view, gh release view or list, gh run view or list, never with --web"
        ok="Only $ok may run here, one at a time, with nothing before or after them."
        case "$c" in
            *';'*|*'&'*|*'|'*|*'$('*|*'`'*|*'>'*|*'<'*|*$'\n'*)
                _deny "Refused: this command chains or redirects. $ok" ;;
            *--output*)
                _deny "Refused: git may not write a file here (--output). $ok" ;;
        esac
        if (( git_only )) && [[ "$c" =~ ^git([[:space:]]+(--no-pager|-C[[:space:]]+[^[:space:]]+))*[[:space:]]+(diff|log|show|status)([[:space:]]|$) ]]; then
            exit 0
        fi
        if (( gh_read )) && _gh_reads "$c"; then
            source "${BASH_SOURCE[0]%/*}/../../scripts/lib/secret-patterns.sh" 2>/dev/null \
                || _deny "Refused: the check for secrets could not be loaded, so nothing may leave this machine."
            shopt -s nocasematch
            if [[ "$c" =~ $_ZB_SECRET_AWS_RE || "$c" =~ $_ZB_SECRET_PEM_RE || "$c" =~ $_ZB_SECRET_CRED_RE ]]; then
                _deny "Refused: this holds text that looks like a secret (a key, token or password), which must not leave this machine. Look it up without it."
            fi
            exit 0
        fi
        _deny "Refused: $c. $ok"
        ;;
    Agent|Task)
        [[ -n "$f_model" ]] && _deny "Refused: a subagent runs on this call's model. Ask for it again without naming a model."
        exit 0
        ;;
    WebSearch|WebFetch)
        # The definitions of what looks like a secret: scripts/lib/secret-patterns.sh.
        # Unreadable, nothing is checked: refuse rather than let it through.
        source "${BASH_SOURCE[0]%/*}/../../scripts/lib/secret-patterns.sh" 2>/dev/null \
            || _deny "Refused: the check for secrets could not be loaded, so nothing may leave this machine."
        shopt -s nocasematch
        if [[ "$f_text" =~ $_ZB_SECRET_AWS_RE || "$f_text" =~ $_ZB_SECRET_PEM_RE || "$f_text" =~ $_ZB_SECRET_CRED_RE ]]; then
            _deny "Refused: this holds text that looks like a secret (a key, token or password), which must not leave this machine. Search without it."
        fi
        exit 0
        ;;
esac

# Read, Grep or Glob under --code-copy. Glob lists names, never content.
[[ "$tool" == Glob ]] && exit 0
p="$f_path"
if [[ -z "$p" ]]; then
    [[ "$tool" == Read ]] && exit 0
    _deny "Refused: a search with no folder searches the working copy, which holds this branch's new code. Search the copy of the code from before this change, $code_copy, or the test folders."
fi
[[ "$p" == /* ]] || p="${repo:-$PWD}/$p"
p="${p%/}"
[[ "$p" == "$code_copy" || "$p" == "$code_copy"/* ]] && exit 0
[[ -n "$repo" && ( "$p" == "$repo" || "$p" == "$repo"/* ) ]] || exit 0
[[ "$p" == "$repo" ]] && _deny "Refused: searching the whole working copy searches this branch's new code. Search the copy of the code from before this change, $code_copy, or the test folders."
rel="${p#"$repo"/}"
for g in ${globs[@]+"${globs[@]}"}; do
    # shellcheck disable=SC2053  # the glob is meant to match; a test folder itself matches as <folder>/
    [[ "$rel" == $g || "$rel/" == $g ]] && exit 0
done
_deny "Refused: $rel in the working copy holds this branch's new code. Read the existing code in the copy of the code from before this change: $code_copy/$rel. Files in the test folders can be read where they are."
