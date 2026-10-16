#!/usr/bin/env bash
# [#1801/SPEC-9] A configured orchestrator backend that cannot be found, or
# whose config is unreadable, fails the run as `misconfigured` naming the
# backend — tested from the installed tree.
#
# Before this change, orch_load_backend silently fell back to orch-sequential
# rather than failing with a clear error. After the change, a missing or
# unreadable backend causes the run to end as `misconfigured` with the backend
# name in the reason.
#
# These tests FAIL on pre-change code (where a missing backend silently falls
# back instead of failing) and PASS after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-9] missing/unreadable orch backend → misconfigured"
setup_test_env "orch-backend-misconfigured"

# ─── [#1801/SPEC-9] non-existent backend alias fails as misconfigured ─────────
print_test_section "[#1801/SPEC-9] orch_load_backend with unknown alias → misconfigured"

# Use a plugins root that has no backend with alias `no-such-backend`.
_out1=""
_rc1=0
_out1="$(
    ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" \
    bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/core/orch/contract.sh" 2>/dev/null || true
        orch_load_backend "no-such-backend" 2>&1
        echo "exit:$?"
    ' 2>&1)" || _rc1=$?

# After the change: the output or exit code signals misconfigured, and the
# backend name appears in the message.
if grep -qiE 'misconfigured|not found|cannot' <<< "$_out1" \
        && grep -q 'no-such-backend' <<< "$_out1"; then
    assert_pass "[#1801/SPEC-9] unknown backend alias produces misconfigured + names the backend"
else
    assert_fail "[#1801/SPEC-9] unknown backend alias produces misconfigured + names the backend" \
        "output did not name the backend or did not signal misconfigured:" \
        "$(printf '%s' "$_out1" | head -5 | tr '\n' '|')"
fi

# ─── [#1801/SPEC-9] the contract.sh fallback logic is gone ───────────────────
print_test_section "[#1801/SPEC-9] contract.sh has no fallback to orch-sequential"

_contract="$REPO_ROOT/core/orch/contract.sh"
if [[ ! -f "$_contract" ]]; then
    assert_fail "[#1801/SPEC-9] core/orch/contract.sh exists" "file not found"
else
    # The old code: "Fallback: try built-in orch-sequential plugin by known path"
    # After the change this fallback is removed.
    if grep -q 'orch-sequential' "$_contract"; then
        assert_fail "[#1801/SPEC-9] contract.sh has no fallback to orch-sequential" \
            "orch-sequential still referenced in contract.sh — the fallback was not removed"
    else
        assert_pass "[#1801/SPEC-9] contract.sh has no fallback to orch-sequential"
    fi
fi

# ─── [#1801/SPEC-9] orch_load_backend does not silently continue on missing ───
print_test_section "[#1801/SPEC-9] orch_load_backend fails (does not return 0) on missing backend"

_out2=""
_rc2=0
_out2="$(
    ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/empty-plugins" \
    bash -c '
        mkdir -p "'"$TEST_TEMP_DIR"'/empty-plugins"
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/core/orch/contract.sh" 2>/dev/null || true
        orch_load_backend "missing-alias" 2>&1
        echo "exit:$?"
    ' 2>&1)" || _rc2=$?

# Extract the exit code the subshell reported
_reported_exit=""
_reported_exit="$(grep '^exit:' <<< "$_out2" | tail -1 | cut -d: -f2 || true)"

# After the change: orch_load_backend must not return 0 for a missing backend.
# (Old code: warns and returns 0, so the engine continued without a backend.)
if [[ "$_reported_exit" == "0" ]]; then
    assert_fail "[#1801/SPEC-9] orch_load_backend returns non-zero on missing backend" \
        "returned 0 — a missing backend was silently accepted (pre-change fallback behaviour)"
else
    assert_pass "[#1801/SPEC-9] orch_load_backend returns non-zero on missing backend"
fi

# ─── [#1801/SPEC-9] unreadable backend config fails as misconfigured ─────────
print_test_section "[#1801/SPEC-9] unreadable backend manifest → misconfigured"

# Create a backend whose manifest.yaml is present but unreadable (chmod 000).
# contract.sh scans with find -type f, so the file is found; then grep for the
# orchestrator-backend role fails (permission denied, suppressed), the entry is
# skipped, and no backend is matched → misconfigured. This tests the
# "whose config is unreadable" arm of the SPEC-9 requirement.
_unreadable_plugins="$TEST_TEMP_DIR/unreadable-plugins"
mkdir -p "$_unreadable_plugins/tool/bad-backend"
cat > "$_unreadable_plugins/tool/bad-backend/manifest.yaml" <<'EOF'
id: bad-backend
name: Bad Backend
kind: tool
version: 0.0.1
roles:
  - orchestrator-backend
aliases:
  - alias: bad-backend
EOF
chmod 000 "$_unreadable_plugins/tool/bad-backend/manifest.yaml"

_out4=""
_out4="$(
    ZBUILD_PLUGINS_ROOT="$_unreadable_plugins" \
    bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/core/orch/contract.sh" 2>/dev/null || true
        orch_load_backend "bad-backend" 2>&1
        echo "exit:$?"
    ' 2>&1)" || true

# Restore so cleanup_test_env can remove it
chmod 644 "$_unreadable_plugins/tool/bad-backend/manifest.yaml" 2>/dev/null || true

_reported_exit4=""
_reported_exit4="$(grep '^exit:' <<< "$_out4" | tail -1 | cut -d: -f2 || true)"

# After the change: orch_load_backend must not return 0 for an unreadable config.
if [[ "$_reported_exit4" == "0" ]]; then
    assert_fail "[#1801/SPEC-9] unreadable backend config fails as misconfigured (non-zero rc)" \
        "returned 0 — an unreadable backend config was silently accepted"
else
    assert_pass "[#1801/SPEC-9] unreadable backend config fails as misconfigured (non-zero rc)"
fi

# The requirement says: "the output names the backend in both cases."
# For the unreadable-config case the backend alias is "bad-backend"; verify it appears.
if grep -q 'bad-backend' <<< "$_out4"; then
    assert_pass "[#1801/SPEC-9] unreadable backend config output names the backend ('bad-backend')"
else
    assert_fail "[#1801/SPEC-9] unreadable backend config output names the backend ('bad-backend')" \
        "output does not contain 'bad-backend': $(printf '%s' "$_out4" | head -5 | tr '\n' '|')"
fi

# ─── [#1801/SPEC-19] installed-layout variant ────────────────────────────────
# SPEC-19: source contract.sh from a temp install directory produced by rsync
# (mirroring install.sh lines 74-80: scripts/ core/ plugins/ config/).
# The behavior must be identical from the installed layout.
print_test_section "[#1801/SPEC-19] installed layout: sources contract.sh from tmp ZBUILD_HOME"

_zbuild_home="$TEST_TEMP_DIR/zbuild-home-install"
mkdir -p "$_zbuild_home"

if command -v rsync >/dev/null 2>&1; then
    for _d in scripts core plugins config; do
        rsync -a "$REPO_ROOT/$_d/" "$_zbuild_home/$_d/" 2>/dev/null || true
    done

    # Unknown-alias case from the installed layout.
    _out_inst=""
    _out_inst="$(
        ZBUILD_PLUGINS_ROOT="$_zbuild_home/plugins" \
        bash -c '
            source "'"$_zbuild_home"'/scripts/lib/helpers.sh" 2>/dev/null || true
            source "'"$_zbuild_home"'/core/orch/contract.sh" 2>/dev/null || true
            orch_load_backend "no-such-backend-installed" 2>&1
            echo "exit:$?"
        ' 2>&1)" || true

    # After the change: misconfigured output with the backend name.
    if grep -qiE 'misconfigured|not found|cannot' <<< "$_out_inst" \
            && grep -q 'no-such-backend-installed' <<< "$_out_inst"; then
        assert_pass "[#1801/SPEC-19] installed layout: unknown backend → misconfigured naming the backend"
    else
        assert_fail "[#1801/SPEC-19] installed layout: unknown backend → misconfigured naming the backend" \
            "output: $(printf '%s' "$_out_inst" | head -5 | tr '\n' '|')"
    fi

    # The installed contract.sh must not return 0 for a missing backend.
    _inst_exit=""
    _inst_exit="$(grep '^exit:' <<< "$_out_inst" | tail -1 | cut -d: -f2 || true)"
    if [[ "$_inst_exit" == "0" ]]; then
        assert_fail "[#1801/SPEC-19] installed layout: orch_load_backend returns non-zero on missing backend" \
            "returned 0 — installed contract.sh still has pre-change fallback behavior"
    else
        assert_pass "[#1801/SPEC-19] installed layout: orch_load_backend returns non-zero on missing backend"
    fi
else
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}SKIP${RESET}: [#1801/SPEC-19] installed-layout variant (rsync not available)" >&2
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
