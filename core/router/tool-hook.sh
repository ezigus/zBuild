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
#   --gh-read            (#2584, read-github) the shell runs zbuild-gh-get
#                        <endpoint> [jq-filter] (core/router/gh-get.sh, which
#                        builds gh's argv itself) and no gh command line: one or
#                        two plain or quoted words, nothing chained, expanded or
#                        redirected, nothing that looks like a secret
#   --secret-dir <dir>   the folder holding the call's GitHub token: no tool
#                        reads in it or searches a folder holding it, and no git
#                        command names it, an ancestor, a path through .., ~ or $
#   git's --no-index (it reads any file) is refused under --git-only
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

git_only=0 gh_read=0 secret_dir="" code_copy="" repo="" done_word="" time_limit="" turn_limit=""
globs=()
while [[ $# -gt 2 ]]; do
    case "$1" in
        --git-only)   git_only=1; shift ;;
        --gh-read)    gh_read=1; shift ;;
        --secret-dir) secret_dir="${2%/}"; shift 2 ;;
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

# The one JSON string writer (scripts/lib/json-text.sh). A hook that cannot load
# it refuses every tool: a guard fails closed.
# shellcheck source=../../scripts/lib/json-text.sh
source "${BASH_SOURCE[0]%/*}/../../scripts/lib/json-text.sh" 2>/dev/null || {
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Refused: the tool hook could not load its library, so no tool may run."}}'
    exit 0
}
_deny() {
    local r; zb_json_str_v r "$1"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$r"
    exit 0
}

# _gh_get_form <command> — rc 0 when <command> is `zbuild-gh-get` and one or
# two words, each plain ([A-Za-z0-9._/,:%+@-], = past its first character) or
# quoted: in single quotes anything, in double quotes no $ or `, and a backslash
# only before " or \. Nothing else reaches the shell, so nothing is chained,
# expanded or redirected; the wrapper checks the words themselves. Otherwise
# rc 1, and gh_why says what was wrong when it can.
gh_why=""
_gh_get_form() {
    local c="$1" i=0 n=${#1} ch nx q="" w="" inw=0 wq=0 first="" firstq=0 nw=0
    gh_why=""
    [[ "$c" == zbuild-gh-get || "$c" == "zbuild-gh-get"[[:space:]]* ]] || return 1
    while (( i < n )); do
        ch="${c:i:1}"
        if [[ "$q" == "'" ]]; then
            if [[ "$ch" == "'" ]]; then q=""; else w+="$ch"; fi
        elif [[ "$q" == '"' ]]; then
            case "$ch" in
                '"') q="" ;;
                '\') nx="${c:i+1:1}"
                     [[ "$nx" == '"' || "$nx" == '\' ]] || { gh_why="a backslash in double quotes may only come before \" or \\"; return 1; }
                     w+="$nx"; i=$(( i + 1 )) ;;
                '$'|'`') gh_why="nothing may be expanded (\$ or \`): put the words in single quotes"; return 1 ;;
                $'\n'|$'\r') gh_why="a command is one line"; return 1 ;;
                *) w+="$ch" ;;
            esac
        else
            case "$ch" in
                ' '|$'\t')
                    if (( inw )); then
                        nw=$(( nw + 1 )); (( nw == 1 )) && { first="$w"; firstq=$wq; }
                        w="" inw=0 wq=0
                    fi ;;
                "'"|'"') q="$ch"; inw=1; wq=1 ;;
                [A-Za-z0-9._/,:%+@-]) w+="$ch"; inw=1 ;;
                '=') (( inw )) || { gh_why="a word may not start with ="; return 1; }; w+="$ch" ;;
                '?'|'*'|'['|']'|'{'|'}'|'&'|'|')
                    gh_why="an endpoint with a query (?, &) and a filter (|, [, ], *, {, }) go in single quotes, as data"; return 1 ;;
                *) gh_why="\"$ch\" may not stand outside quotes: nothing may be chained, expanded or redirected"; return 1 ;;
            esac
        fi
        i=$(( i + 1 ))
    done
    [[ -z "$q" ]] || { gh_why="a quote is not closed"; return 1; }
    if (( inw )); then nw=$(( nw + 1 )); (( nw == 1 )) && { first="$w"; firstq=$wq; }; fi
    [[ "$first" == zbuild-gh-get ]] && (( !firstq )) || return 1
    (( nw >= 2 && nw <= 3 )) || { gh_why="zbuild-gh-get takes an endpoint and, if wanted, one jq filter"; return 1; }
    return 0
}

# _near_secret <path> [above] — rc 0 when <path> is the secret folder, inside
# it, passes through .., or (with [above]) is a folder that holds it. A path
# not absolute is the working folder's; /private is macOS's alias of /var.
_near_secret() {
    local p="$1" above="${2:-}" v
    [[ "$p" == /* ]] || p="$PWD/$p"
    [[ "/$p/" == */../* ]] && return 0
    while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
    while [[ "$p" == */./* ]]; do p="${p//\/.\//\/}"; done
    p="${p%/.}"; p="${p%/}"
    for v in "$secret_dir" "${secret_dir#/private}" "/private$secret_dir"; do
        while [[ "$v" == *//* ]]; do v="${v//\/\//\/}"; done
        [[ "$p" == "$v" || "$p" == "$v"/* ]] && return 0
        [[ -n "$above" && ( -z "$p" || "$v" == "$p"/* ) ]] && return 0
    done
    return 1
}

# _git_spares_secret <command> — rc 0 when no word of the git command (quotes
# aside, and each --opt=value's value) could name the secret folder: no ~ or $,
# no path into it, above it or through .., no glob in a full path.
_git_spares_secret() {
    local s="$1" w v
    [[ "$s" == *'$'* || "$s" == *'~'* ]] && return 1
    s="${s//[\"\'\\]/}"
    local -a ws=()
    local IFS=$' \t'
    read -ra ws <<< "$s"
    for w in "${ws[@]}"; do
        for v in "$w" "${w#*=}"; do
            [[ "$v" == /* && "$v" == *[\*\?\[]* ]] && return 1
            _near_secret "$v" 1 && return 1
        done
    done
    return 0
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
    Read|Grep|Glob)                [[ -n "$code_copy" || -n "$secret_dir" ]] || exit 0 ;;
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
        (( gh_read )) && ok+="${ok:+, and }zbuild-gh-get <endpoint> [jq-filter] (a GET of GitHub's REST API; put an endpoint with a query, and a filter, in single quotes)"
        ok="Only $ok may run here, one at a time, with nothing before or after them."
        if (( gh_read )) && _gh_get_form "$c"; then
            source "${BASH_SOURCE[0]%/*}/../../scripts/lib/secret-patterns.sh" 2>/dev/null \
                || _deny "Refused: the check for secrets could not be loaded, so nothing may leave this machine."
            shopt -s nocasematch
            if [[ "$c" =~ $_ZB_SECRET_AWS_RE || "$c" =~ $_ZB_SECRET_PEM_RE || "$c" =~ $_ZB_SECRET_CRED_RE ]]; then
                _deny "Refused: this holds text that looks like a secret (a key, token or password), which must not leave this machine. Look it up without it."
            fi
            exit 0
        fi
        (( gh_read )) && [[ -n "$gh_why" ]] && _deny "Refused: $gh_why. $ok"
        case "$c" in
            *';'*|*'&'*|*'|'*|*'$('*|*'`'*|*'>'*|*'<'*|*$'\n'*)
                _deny "Refused: this command chains or redirects. $ok" ;;
            *--output*)
                _deny "Refused: git may not write a file here (--output). $ok" ;;
            *--no-ind*)
                _deny "Refused: git diff --no-index reads any file on the machine. $ok" ;;
        esac
        if (( git_only )) && [[ "$c" =~ ^git([[:space:]]+(--no-pager|-C[[:space:]]+[^[:space:]]+))*[[:space:]]+(diff|log|show|status)([[:space:]]|$) ]]; then
            [[ -n "$secret_dir" ]] && ! _git_spares_secret "$c" \
                && _deny "Refused: this git command could reach the folder of the engine's GitHub token ($secret_dir): no path in it, above it or through .., and no ~ or \$. $ok"
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

# Read, Grep or Glob. Glob lists names, never content.
[[ "$tool" == Glob ]] && exit 0
if [[ -n "$secret_dir" ]]; then
    sp="$f_path" above=""
    [[ "$tool" == Grep ]] && { above=1; sp="${sp:-$PWD}"; }
    [[ -n "$sp" ]] && _near_secret "$sp" "$above" \
        && _deny "Refused: $sp holds, or is above, the folder of the engine's GitHub token, which no tool reads. Read or search elsewhere."
fi
[[ -n "$code_copy" ]] || exit 0
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
