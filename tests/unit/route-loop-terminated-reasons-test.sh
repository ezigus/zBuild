#!/usr/bin/env bash
# Tests: core/router/route.sh + scripts/lib/router-rc-classify.sh
# DSEND-1: the _ROUTE_LOOP_TERMINATED_REASON comment in route_to_model_loop
#   lists every concrete reason assigned in route_to_model_loop and every
#   reason _router_rc_classify returns, with no shorthand for the classify
#   subset.
# DSLOCK-1: no_done_sentinel and router_out_of_turns are pre-existing reason
#   values; this change reads them without defining new ones.
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
_build_summary_sh="$REPO_ROOT/plugins/agent/build/lib/summary.sh"
_build_plugin_sh="$REPO_ROOT/plugins/agent/build/plugin.sh"

# ─── DSEND-1 ─────────────────────────────────────────────────────────────────
# Given: the route.sh file and router-rc-classify.sh file exist

# When: a test extracts every _ROUTE_LOOP_TERMINATED_REASON= assignment from
# route.sh and every reason= string from _router_rc_classify in
# router-rc-classify.sh

# Step 1: collect all concrete string values assigned to
# _ROUTE_LOOP_TERMINATED_REASON inside route_to_model_loop in route.sh.
# Match only double-quoted concrete identifiers (not empty string, not vars).
_route_reasons="$(grep -oE '_ROUTE_LOOP_TERMINATED_REASON="[a-z_]+"' \
    "$_route_sh" | \
    sed 's/.*="\([^"]*\)"/\1/' | \
    grep -v '^$' | \
    sort -u)"

# Step 2: collect all reason values that _router_rc_classify can assign.
# The function uses: printf -v "$reason_var"  '%s' "value"
_classify_reasons="$(awk '
    /^_router_rc_classify\(\)/ { in_fn=1 }
    in_fn && /printf.*reason_var/ {
        if (match($0, /"[a-z_]+"[ ]*$/)) {
            val = substr($0, RSTART+1, RLENGTH-2)
            if (val != "") print val
        }
    }
    /^}/ { in_fn=0 }
' "$_classify_sh" | sort -u)"

# Step 3: union of both sets = required set
_required="$(printf '%s\n%s\n' "$_route_reasons" "$_classify_reasons" | \
    sort -u | grep -v '^$')"

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

# ─── DSLOCK-1 ────────────────────────────────────────────────────────────────

# Source the build plugin's summary module so _build_emit_changed_files_summary
# can be called in the When step below.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" || true
# shellcheck source=../../scripts/lib/numstat-format.sh
source "$REPO_ROOT/scripts/lib/numstat-format.sh" || true
# shellcheck source=../../plugins/agent/build/lib/summary.sh
source "$REPO_ROOT/plugins/agent/build/lib/summary.sh" || true

# Given — no_done_sentinel and router_out_of_turns already exist as pre-existing
# reason values in route.sh and _router_rc_classify; this change reads them.
# (Verified in the Then assertions below by static analysis of source files.)

# When — _build_emit_changed_files_summary is called with terminated_reason set
# to no_done_sentinel and router_out_of_turns; it reads these values without
# assigning any new _ROUTE_LOOP_TERMINATED_REASON.
_dslock1_repo="$TEST_TEMP_DIR/dslock1-repo"
mkdir -p "$_dslock1_repo"
( cd "$_dslock1_repo" \
  && git init -q \
  && git config user.email "test@zbuild" \
  && git config user.name "zbuild-test" \
  && printf 'seed\n' > seed.txt \
  && git add seed.txt \
  && git commit -q -m "seed" )
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/dslock1-state"
mkdir -p "$ZBUILD_STATE_DIR"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
_BUILD_PLAN_FILES_CSV=""
: > "$ZBUILD_EVENTS_JSONL"
_build_emit_changed_files_summary "$_dslock1_repo" "no_done_sentinel" "false" "" \
    >/dev/null 2>&1 || true
_build_emit_changed_files_summary "$_dslock1_repo" "router_out_of_turns" "false" "" \
    >/dev/null 2>&1 || true

# Then — no new _ROUTE_LOOP_TERMINATED_REASON value is assigned anywhere in the
# changed files (the build plugin files do not add new loop-reason assignments)

# no_done_sentinel is a pre-existing reason assigned in route.sh
_dslock1_nds="$(grep -c '_ROUTE_LOOP_TERMINATED_REASON="no_done_sentinel"' \
    "$_route_sh" 2>/dev/null || true)"
if [[ "${_dslock1_nds:-0}" -ge 1 ]]; then
    assert_pass "[DSLOCK-1] no_done_sentinel is a pre-existing reason assigned in route.sh"
else
    assert_fail "[DSLOCK-1] no_done_sentinel is a pre-existing reason assigned in route.sh"
fi

# router_out_of_turns is a pre-existing reason returned by _router_rc_classify
_dslock1_rot="$(grep -c '"router_out_of_turns"' "$_classify_sh" 2>/dev/null || true)"
if [[ "${_dslock1_rot:-0}" -ge 1 ]]; then
    assert_pass "[DSLOCK-1] router_out_of_turns is a pre-existing reason in router-rc-classify.sh"
else
    assert_fail "[DSLOCK-1] router_out_of_turns is a pre-existing reason in router-rc-classify.sh"
fi

# The build plugin's summary.sh must not assign _ROUTE_LOOP_TERMINATED_REASON
# (it only reads the value; assigning would add a new reason)
_dslock1_sum="$(grep -v '^[[:space:]]*#' "$_build_summary_sh" 2>/dev/null | \
    grep '_ROUTE_LOOP_TERMINATED_REASON=' || true)"
if [[ -z "$_dslock1_sum" ]]; then
    assert_pass "[DSLOCK-1] build plugin summary.sh does not assign _ROUTE_LOOP_TERMINATED_REASON"
else
    assert_fail "[DSLOCK-1] build plugin summary.sh does not assign _ROUTE_LOOP_TERMINATED_REASON" \
        "found: $_dslock1_sum"
fi

# The main build plugin.sh must not assign _ROUTE_LOOP_TERMINATED_REASON
_dslock1_plug="$(grep -v '^[[:space:]]*#' "$_build_plugin_sh" 2>/dev/null | \
    grep '_ROUTE_LOOP_TERMINATED_REASON=' || true)"
if [[ -z "$_dslock1_plug" ]]; then
    assert_pass "[DSLOCK-1] build plugin.sh does not assign _ROUTE_LOOP_TERMINATED_REASON"
else
    assert_fail "[DSLOCK-1] build plugin.sh does not assign _ROUTE_LOOP_TERMINATED_REASON" \
        "found: $_dslock1_plug"
fi

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
