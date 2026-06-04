#!/usr/bin/env bash
# scripts/lib/env-scrub.sh — fresh-user-shell env scrub helper (ADR-024, #671)
#
# Provides _zbuild_make_fresh_shell — the single semantic contract used at
# every fresh-user-shell spawn site (per ADR-024). Replaces the per-variable
# `unset ZBUILD_STAGE_IO_FD && exec 3>&-` ritual that Wave 11A (#645) and
# Wave 11C (#647) shipped as tactical fixes; those tactical fixes did not
# generalize across new ZBUILD_* variables (Wave 13 dogfood discovered
# ZBUILD_RUN_ID + ZBUILD_EVENTS_JSONL leaks triggering the router's C6
# precondition refusal). The wildcard scrub here strictly supersets the
# narrow scrubs — every variable they touched is included.
#
# Sourced library: no set -euo pipefail (would mutate caller options).

[[ -n "${_ZBUILD_ENV_SCRUB_LOADED:-}" ]] && return 0
_ZBUILD_ENV_SCRUB_LOADED=1

# _zbuild_make_fresh_shell
#
# Preamble call for subshells that should look like a fresh user terminal
# (per ADR-024 fresh-user-shell class). Scrubs all runner-internal env vars
# in the current shell — both ZBUILD_*-prefixed (session/runner state) and
# _TPL_*-prefixed (template per-stage state exported by load_template,
# added Wave 15-I / #683) — and closes the runner's stage-io fd 3 (opened
# by runner via `exec 3>&2`).
#
# Preserves: PATH, HOME, USER, SHELL, TERM, TMPDIR and any other non-
# (ZBUILD_|_TPL_) parent env vars — the user-shell vars the spawned process
# legitimately needs.
#
# Why wildcard scrub instead of per-var unsets:
#   #645/Wave 11A unset only ZBUILD_STAGE_IO_FD and missed ZBUILD_RUN_ID
#   + ZBUILD_EVENTS_JSONL. The router's C6 precondition reads those and
#   refuses to spawn claude when they leak. Per-var scrub doesn't generalize.
#
# Wave 15-I (#683): _TPL_* namespace added to the scrub. core/pipeline/template.sh
# `load_template` EXPORTS per-stage settings as `_TPL_STAGE_*_<safe_id>` env vars
# (router timeouts, io destinations, roles, strategy). Pre-Wave 15-I those env
# vars survived `npm test` fork boundary and contaminated integration tests
# running under the pipeline test stage:
#   - tests/integration/test-plugin-fresh-shell-test.sh saw a leaked
#     _TPL_STAGE_IO_DESTS_test=file,stdout → stage_io_begin emitted a banner
#     to the test's mock fd 3 sentinel → assertion "sentinel empty" failed.
#   - tests/integration/core-router-route-test.sh Tr-5 saw a leaked
#     _TPL_STAGE_ROUTER_TIMEOUT_plan=300 → _route_resolve_timeout returned 300
#     instead of expected 450 (env value), because template_stage_router_timeout
#     plan returned the leaked value instead of empty-fallthrough.
# Both tests passed in direct `bash <test>` runs (no parent runner → no leak)
# but failed in pipeline dogfoods. The scrub is the right boundary: _TPL_* is
# runner-internal template state and must not survive into fresh-user-shell.
_zbuild_make_fresh_shell() {
    # Clear shell options that a fresh user shell would not have inherited.
    # The runner sets `set -euo pipefail` at the top of its scripts; that
    # leaks into $(...) subshells. A real user terminal runs `npm test`
    # (or `claude`) without -e / -u / -o pipefail. Restore that posture so
    # the spawned process sees the same option set the user would. Without
    # this, any unbound non-ZBUILD_* var or any nonzero-rc command in a
    # spawned wrapper script kills the subshell before the real spawn.
    set +e +u +o pipefail 2>/dev/null || true
    local _v
    while IFS= read -r _v; do
        [[ -z "$_v" ]] && continue
        unset "$_v"
    done < <(compgen -v 2>/dev/null | grep -E '^(ZBUILD_|_TPL_)' || true)
    exec 3>&-
}
