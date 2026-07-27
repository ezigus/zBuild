#!/usr/bin/env bash
# tests/unit/plugins-root-hermeticity-test.sh
# #1274: static guard — ZBUILD_PLUGINS_ROOT must NEVER be captured or
# re-exported inside plugins/tool/test/plugin.sh. The three re-exported
# vars in the test-stage fence set are ZBUILD_STATE_ROOT, ZBUILD_COST_LEDGER,
# ZBUILD_CACHE_DIR (and ZBUILD_TEST_TIMING_FILE / optionally
# ZBUILD_TEST_RESULTS_JSON). ZBUILD_PLUGINS_ROOT is intentionally absent:
# leaking a test-run's mock plugins root into the nested runner would resolve
# plugins from the mock tree, not the real installed tree — the same env-leak
# bug class that motivated ADR-024.
#
# SPEC-1 [guard]: scanner precondition — /usr/bin/grep must be executable;
#   a broken scanner returns a false GREEN and is itself a test failure.
# SPEC-2 [guard]: ZBUILD_PLUGINS_ROOT does not appear anywhere in
#   plugins/tool/test/plugin.sh; if it does, the invariant is broken.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# The repo's default `grep` may be ugrep with ERE quirks; use the system
# grep for deterministic matching in a guard scan.
GREP=/usr/bin/grep

print_test_header "plugins-root hermeticity — ZBUILD_PLUGINS_ROOT never captured/re-exported in test plugin (#1274)"

# SPEC-1 [guard]: a safety guard must NEVER pass vacuously. If /usr/bin/grep
# is missing or not executable every scan would silently succeed, and the
# guard would report a false GREEN. Assert the tool up front and FAIL loudly
# instead — a broken scanner is a test failure, not a pass.
if [[ ! -x "$GREP" ]]; then
    assert_fail "[SPEC-1] scanner precondition: $GREP is executable" \
        "the hermeticity scan requires an executable $GREP; refusing to scan-and-pass vacuously"
    print_test_results
fi

assert_pass "[SPEC-1] scanner precondition: $GREP is executable"

# Target file: the test-stage plugin fence where ZBUILD_PLUGINS_ROOT must
# never appear.
_target="$REPO_ROOT/plugins/tool/test/plugin.sh"

# A guard must never pass because its scan target vanished. If the fence file
# is missing or unreadable the scan cannot run — fail loud instead of GREEN.
if [[ ! -r "$_target" ]]; then
    assert_fail "[SPEC-2] scan target is readable: ${_target#"$REPO_ROOT/"}" \
        "cannot scan the test-stage fence file — refusing to pass vacuously (ADR-024, #1274)"
    print_test_results
fi

# SPEC-2 [guard]: scan for any occurrence of the token ZBUILD_PLUGINS_ROOT
# (bare assignment, export, or reference) in the target file. grep rc is
# handled EXPLICITLY: rc=0 means an offender was found, rc=1 means clean, and
# rc>=2 means grep itself errored — which must fail loud, never be silently
# treated as "clean" (the vacuous-pass class Copilot/lenses flagged, #1274).
_offending_lines="$("$GREP" -nE 'ZBUILD_PLUGINS_ROOT' "$_target")"; _scan_rc=$?
if [[ $_scan_rc -eq 0 ]]; then
    printf '  offending lines in %s:\n' "${_target#"$REPO_ROOT/"}" >&2
    printf '    %s\n' "$_offending_lines" >&2
    assert_fail "[SPEC-2] ZBUILD_PLUGINS_ROOT does not appear in plugins/tool/test/plugin.sh" \
        "found ZBUILD_PLUGINS_ROOT reference(s) — this var must not enter the test-stage fence (ADR-024, #1274)"
elif [[ $_scan_rc -eq 1 ]]; then
    assert_pass "[SPEC-2] ZBUILD_PLUGINS_ROOT does not appear in plugins/tool/test/plugin.sh"
else
    assert_fail "[SPEC-2] scanner ran cleanly on plugins/tool/test/plugin.sh" \
        "$GREP exited $_scan_rc (scan error) — refusing to treat a broken scan as clean"
fi

# SPEC-2 (red direction): prove the scan is NOT a no-op. A synthetic copy of
# the fence file with ZBUILD_PLUGINS_ROOT injected MUST trip the scanner
# (rc=0). This is the bidirectional half of the tripwire (#1274 DoD): the
# guard must catch a real fence violation, not just pass on a clean tree.
_synthetic="$(mktemp)"
trap 'rm -f "$_synthetic"' EXIT
{ cat "$_target"; printf '\nexport ZBUILD_PLUGINS_ROOT="%s"\n' '/tmp/mock-plugins'; } > "$_synthetic"
"$GREP" -qE 'ZBUILD_PLUGINS_ROOT' "$_synthetic"; _red_rc=$?
if [[ $_red_rc -eq 0 ]]; then
    assert_pass "[SPEC-2] scanner trips on an injected ZBUILD_PLUGINS_ROOT (red-first, bidirectional)"
else
    assert_fail "[SPEC-2] scanner trips on an injected ZBUILD_PLUGINS_ROOT (red-first, bidirectional)" \
        "injected offender not detected (rc=$_red_rc) — the guard would miss a real fence violation"
fi

# SPEC-3 [change]: ADR-024 must carry the Amendment (#1274) section that
# documents why ZBUILD_PLUGINS_ROOT is intentionally absent from the fence set.
# Match the section heading by its stable issue tag rather than an exact date
# string, so a later reformat/date-correction does not silently break the test.
# Still fails at merge-base (the section is new) and passes at HEAD.
_adr="$REPO_ROOT/docs/adr/ADR-024-subprocess-env-isolation.md"
if "$GREP" -qE '^#+[[:space:]]+Amendment.*#1274' "$_adr" 2>/dev/null; then
    assert_pass "[SPEC-3] ADR-024 contains the Amendment (#1274) section"
else
    assert_fail "[SPEC-3] ADR-024 contains the Amendment (#1274) section" \
        "amendment heading not found in ${_adr#"$REPO_ROOT/"} — add it per #1274"
fi

# SPEC-7 [change]: ADR-024 hermeticity — resolve_persona must not mutate
# ZBUILD_PLUGINS_ROOT when scanning the repo overlay. The overlay root is
# derived from ZBUILD_REPO_ROOT/.zbuild/plugins via a LOCAL variable; the
# installed-root var (ZBUILD_PLUGINS_ROOT) must remain unchanged throughout.
# Fails at merge-base (resolve_persona does not exist yet); passes at HEAD.
if ! declare -F resolve_persona >/dev/null 2>&1; then
    source "$REPO_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
fi

if declare -F resolve_persona >/dev/null 2>&1; then
    _spec7_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/spec7-hermeticity.XXXXXX")"
    trap 'rm -rf "$_spec7_tmpdir"' EXIT

    # Installed root with the generic persona.
    _spec7_inst="$_spec7_tmpdir/installed"
    mkdir -p "$_spec7_inst/persona/generic"
    cat > "$_spec7_inst/persona/generic/manifest.yaml" <<'MEOF'
id: generic
name: Generic
kind: persona
version: 0.1.0
persona:
  role: a baseline contributor
  perspective: "Implement the task as specified."
MEOF

    # Repo root with an overlay dir (triggers the two-root scan).
    _spec7_repo="$_spec7_tmpdir/repo"
    mkdir -p "$_spec7_repo/.zbuild/plugins/persona/security"
    cat > "$_spec7_repo/.zbuild/plugins/persona/security/manifest.yaml" <<'MEOF'
id: security
name: Security
kind: persona
version: 0.1.0
persona:
  role: a security engineer
  perspective: "Examine trust boundaries."
MEOF

    _spec7_before="${_spec7_inst}"
    export ZBUILD_PLUGINS_ROOT="$_spec7_before"
    export ZBUILD_REPO_ROOT="$_spec7_repo"
    unset ZBUILD_BUILD_PERSONA 2>/dev/null || true

    # Run resolve_persona (will scan overlay) and then check ZBUILD_PLUGINS_ROOT.
    resolve_persona "build" >/dev/null 2>&1 || true
    _spec7_after="${ZBUILD_PLUGINS_ROOT:-}"

    unset ZBUILD_REPO_ROOT 2>/dev/null || true
    unset ZBUILD_PLUGINS_ROOT 2>/dev/null || true

    if [[ "$_spec7_after" == "$_spec7_before" ]]; then
        assert_pass "[SPEC-7] ZBUILD_PLUGINS_ROOT is unchanged after resolve_persona scans the overlay (ADR-024 hermeticity)"
    else
        assert_fail "[SPEC-7] ZBUILD_PLUGINS_ROOT is unchanged after resolve_persona scans the overlay (ADR-024 hermeticity)" \
            "ZBUILD_PLUGINS_ROOT mutated: before='$_spec7_before' after='$_spec7_after' — overlay scan must use a local var, never touch ZBUILD_PLUGINS_ROOT"
    fi
else
    assert_fail "[SPEC-7] resolve_persona is defined (persona-resolve.sh loaded)" \
        "resolve_persona not found — scripts/lib/persona-resolve.sh may not exist or failed to source"
fi

print_test_results
