#!/usr/bin/env bash
# core/router/gh-get.sh <endpoint> [jq-filter] — zbuild-gh-get, the one way a
# judging call looks GitHub up (read-github, ADR-017 §12; #2584).
#
# The model never builds a gh command line: a guard that read one let grouped
# and quoted flags through, and gh built POST and DELETE from them (review of
# #2584). This builds gh's argv itself, from two arguments it takes as data:
#   gh api --method GET --paginate [--jq=<filter>] -- <endpoint>
# The endpoint is a REST path: segments of [A-Za-z0-9._-] (or gh's {owner},
# {repo}, {branch}), never `.` or `..`, not graphql; then, optionally, a query
# of key=value pairs joined by & (keys [A-Za-z0-9._-] not starting with -,
# values [A-Za-z0-9._,:%+*-]). Anything else is refused before gh runs.
#
# gh runs under a watchdog (ZB_GH_GET_TIMEOUT, default 30 s: rc 124), with the
# token from ZB_GH_TOKEN_FILE when the call was given one — the model's own
# environment holds none (core/router/call-tools.sh). Its reply is redacted
# (apply_scope_redaction, then the secret mask, and the token itself) and cut at
# ZB_GH_GET_MAX characters (default 60000), saying so, before it is printed.
#
# Run by the model, through the shim core/router/gh-bin/zbuild-gh-get.
set -uo pipefail

_GG_FORM="zbuild-gh-get <endpoint> [jq-filter] — a GET of GitHub's REST API, e.g. zbuild-gh-get 'repos/{owner}/{repo}/labels' '.[].name'"
_gg_refuse() { printf 'zbuild-gh-get: refused: %s. The form: %s\n' "$1" "$_GG_FORM" >&2; exit 2; }

(( $# >= 1 && $# <= 2 )) || _gg_refuse "it takes one or two arguments, got $#"
ep="$1" filter="${2:-}"
ep="${ep#/}"
seg='([A-Za-z0-9._-]+|\{owner\}|\{repo\}|\{branch\})'
pair='[A-Za-z0-9._][A-Za-z0-9._-]*=[A-Za-z0-9._,:%+*-]*'
re="^$seg(/$seg)*(\\?$pair(&$pair)*)?\$"
[[ "$ep" =~ $re ]] || _gg_refuse "'${ep:0:200}' is not a REST path with an optional key=value query"
path="${ep%%\?*}"
[[ "$path" != -* ]] || _gg_refuse "an endpoint may not start with -"
[[ "/$path/" != */../* && "/$path/" != */./* ]] || _gg_refuse "an endpoint may not hold . or .. as a part"
[[ "${path%%/*}" != graphql ]] || _gg_refuse "graphql can write; only the REST API's GET is allowed"
(( ${#filter} <= 4000 )) || _gg_refuse "the jq filter is over 4000 characters"

argv=(api --method GET --paginate)
[[ -n "$filter" ]] && argv+=("--jq=$filter")
argv+=(-- "$ep")

token=""
if [[ -n "${ZB_GH_TOKEN_FILE:-}" && -r "$ZB_GH_TOKEN_FILE" ]]; then
    IFS= read -r token < "$ZB_GH_TOKEN_FILE" || true
fi
secs="${ZB_GH_GET_TIMEOUT:-30}"; [[ "$secs" =~ ^[1-9][0-9]*$ ]] || secs=30
max="${ZB_GH_GET_MAX:-60000}"; [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=60000

tmp="${TMPDIR:-/tmp}"
out="$(mktemp "$tmp/zb-gh-get-out.XXXXXX")" || { echo "zbuild-gh-get: no temporary file" >&2; exit 1; }
err="$out.err" red="$out.red"
trap 'rm -f "$out" "$err" "$red" "$out.fired"' EXIT

# The watchdog of scripts/lib/run-status-comment.sh (rsc_gh): a marker when it
# fires, so a gh that ends as the limit falls is not called timed out.
if [[ -n "$token" ]]; then
    GH_TOKEN="$token" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "${argv[@]}" > "$out" 2> "$err" < /dev/null &
else
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "${argv[@]}" > "$out" 2> "$err" < /dev/null &
fi
pid=$!
( sleep "$secs"; : > "$out.fired"; kill -TERM "$pid" 2>/dev/null || true ) > /dev/null 2>&1 < /dev/null &
wd=$!
rc=0; wait "$pid" 2>/dev/null || rc=$?
kill -TERM "$wd" 2>/dev/null || true
wait "$wd" 2>/dev/null || true
if (( rc != 0 )) && [[ -e "$out.fired" ]]; then
    printf 'zbuild-gh-get: GitHub did not answer within %s seconds.\n' "$secs" >&2
    exit 124
fi

# What leaves gh reaches the model: redacted, masked, capped.
_root="${BASH_SOURCE[0]%/*}/../.."
# shellcheck source=../redaction/scope-redaction.sh
source "$_root/core/redaction/scope-redaction.sh" 2>/dev/null || { echo "zbuild-gh-get: the redaction could not be loaded; nothing is shown" >&2; exit 1; }
# shellcheck source=../../scripts/lib/secret-patterns.sh
source "$_root/scripts/lib/secret-patterns.sh" 2>/dev/null || { echo "zbuild-gh-get: the secret mask could not be loaded; nothing is shown" >&2; exit 1; }
_gg_clean_v() {
    local -n _gc="$1"; local _f="$2" _t=""
    apply_scope_redaction "$_f" "$red" "" "" 0 > /dev/null 2>&1 || { _gc=""; return 1; }
    IFS= read -r -d '' _t < "$red" || true
    zbuild_mask_secrets_v _t "$_t"
    [[ -n "$token" ]] && _t="${_t//"$token"/<secret>}"
    _gc="$_t"
}
text=""
_gg_clean_v text "$out" || { echo "zbuild-gh-get: the reply could not be redacted; nothing is shown" >&2; exit 1; }
if (( ${#text} > max )); then
    printf '%s\n[zbuild-gh-get: the reply was %s characters; the first %s are shown. To see the rest, narrow it with a jq filter.]\n' \
        "${text:0:max}" "${#text}" "$max"
else
    printf '%s' "$text"
fi
if (( rc != 0 )); then
    etext=""; _gg_clean_v etext "$err" || etext=""
    printf 'zbuild-gh-get: gh failed (rc %s): %s\n' "$rc" "${etext:0:600}" >&2
fi
exit "$rc"
