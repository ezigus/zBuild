#!/usr/bin/env bash
# Tests: core/router/route.sh + scripts/lib/router-rc-classify.sh
# DSEND-1: the _ROUTE_LOOP_TERMINATED_REASON comment in route_to_model_loop
#   lists every concrete reason assigned in route_to_model_loop and every
#   reason _router_rc_classify returns, with no shorthand for the classify
#   subset.
#   The scan reads all of route.sh, not only route_to_model_loop's body: the
#   signal handler sets the same variable while the call runs, so `signal` is a
#   value the comment must list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "route-loop terminated-reasons — comment vs code (#1769)"
setup_test_env "route-loop-terminated-reasons"

_route_sh="$REPO_ROOT/core/router/route.sh"
_classify_sh="$REPO_ROOT/scripts/lib/router-rc-classify.sh"

# ─── DSEND-1 ─────────────────────────────────────────────────────────────────
# Given: the route.sh file and router-rc-classify.sh file exist

# When: a test extracts every _ROUTE_LOOP_TERMINATED_REASON= assignment from
# route.sh and every reason= string from _router_rc_classify in
# router-rc-classify.sh

# Step 1: collect all concrete string values assigned to
# _ROUTE_LOOP_TERMINATED_REASON in route.sh (the loop and its signal handler).
# Match only double-quoted concrete identifiers (not empty string, not vars).
_route_reasons="$(grep -oE '_ROUTE_LOOP_TERMINATED_REASON="[a-z_]+"' \
    "$_route_sh" | \
    sed 's/.*="\([^"]*\)"/\1/' | \
    grep -v '^$' | \
    sort -u)"

# Step 2: collect all reason values that _router_rc_classify can assign.
# The function uses: printf -v "$reason_var"  '%s' "value"
# Exit in_fn on (a) any top-level function definition that follows, OR
# (b) a bare closing brace at column 0, whichever comes first. This prevents
# a column-0 '}' inside the function body (e.g. from a here-doc delimiter or
# an outer compound command) from truncating the extraction early.
_classify_reasons="$(awk '
    /^_router_rc_classify\(\)/ { in_fn=1; next }
    in_fn && /^[a-z_][a-z0-9_]*[[:space:]]*\(\)/ { in_fn=0 }
    in_fn && /^}[[:space:]]*$/ { in_fn=0 }
    in_fn && /printf.*reason_var/ {
        if (match($0, /"[a-z_]+"[ ]*$/)) {
            val = substr($0, RSTART+1, RLENGTH-2)
            if (val != "") print val
        }
    }
' "$_classify_sh" | sort -u)"

# Step 3: union of both sets = required set
_required="$(printf '%s\n%s\n' "$_route_reasons" "$_classify_reasons" | \
    sort -u | grep -v '^$')"

# Guard: if extraction returned an empty set, the membership loops below would
# pass vacuously for any comment content — an empty required set means the grep
# or awk patterns failed to match, not that there are genuinely zero reasons.
if [[ -z "$_required" ]]; then
    assert_fail "[DSEND-1] GUARD: reason extraction produced a non-empty required set" \
        "_required is empty — grep/awk extraction failed; check route.sh and router-rc-classify.sh"
fi

# Step 4: extract tokens from the _ROUTE_LOOP_TERMINATED_REASON comment in
# route.sh. The comment spans multiple continuation lines starting with '#'.
# It ends when a new field's comment (^#   _ROUTE_LOOP_[A-Z]) appears.
_comment_tokens="$(awk '
    /TERMINATED_REASON/ && /—/ && /^#/ {
        in_block=1
        t=$0
        gsub(/^#[[:space:]]*/,"",t)
        gsub(/.*—[[:space:]]*/,"",t)
        printf "%s\n", t
        next
    }
    in_block && /^#/ && !/^#[[:space:]]+_ROUTE_LOOP_[A-Z]/ {
        t=$0
        gsub(/^#[[:space:]]*/,"",t)
        printf "%s\n", t
        next
    }
    in_block { in_block=0; exit }
' "$_route_sh" | grep -oE '[a-z][a-z_]+' | sort -u)"

# Then: the set of concrete reason values equals exactly the set of tokens on
# the _ROUTE_LOOP_TERMINATED_REASON comment line in route.sh.

# (a) Every required reason must appear in the comment
_missing=""
while IFS= read -r _r; do
    [[ -z "$_r" ]] && continue
    if ! grep -qxF "$_r" <<< "$_comment_tokens"; then
        _missing="${_missing:+$_missing, }$_r"
    fi
done <<< "$_required"

if [[ -z "$_missing" ]]; then
    assert_pass "[DSEND-1] every required reason value is listed in the TERMINATED_REASON comment"
else
    assert_fail "[DSEND-1] every required reason value is listed in the TERMINATED_REASON comment" \
        "missing from comment: $_missing"
fi

# (b) No comment token may fall outside the required set.
# A comment using shorthand (e.g. 'a _router_rc_classify reason') adds tokens
# like 'classify' and 'reason' that are not valid reason identifiers.
_extra=""
while IFS= read -r _c; do
    [[ -z "$_c" ]] && continue
    if ! grep -qxF "$_c" <<< "$_required"; then
        _extra="${_extra:+$_extra, }$_c"
    fi
done <<< "$_comment_tokens"

if [[ -z "$_extra" ]]; then
    assert_pass "[DSEND-1] no extra tokens in the comment beyond the required set (no shorthand)"
else
    assert_fail "[DSEND-1] no extra tokens in the comment beyond the required set (no shorthand)" \
        "extra tokens: $_extra"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
