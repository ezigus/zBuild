#!/usr/bin/env bash
# Tests: scripts/install-remote.sh
# Verifies the curl installer logic (issues #88, #89).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild remote installer — unit tests (issues #88, #89)"

setup_test_env "installer"

# ─── PATH / environment setup ────────────────────────────────────────────────
# We need two bin directories:
#   _mock_path   — where we place mocks for git/jq/curl/gh (the tools the
#                  installer checks for with `command -v`).
#   _sys_path    — symlinks to the low-level system utilities the installer
#                  actually runs (tar, mkdir, cp, ln, rm, mktemp, printf).
#                  These are NOT the checked prerequisites; they are always
#                  present so extraction/symlinking works.
#
# For "binary missing" tests we simply don't place the binary in _mock_path;
# and _sys_path never contains git/jq/curl/gh, so they won't be found.

_mock_path="$TEST_TEMP_DIR/bin"
_sys_path="$TEST_TEMP_DIR/sysbin"
_real_bash="$(/usr/bin/which bash)"

mkdir -p "$_sys_path"
# Symlink exactly the low-level tools the installer uses internally.
# Include bash itself so the subprocess can run.
for _b in mkdir cp tar ln rm mktemp bash touch gzip gunzip; do
    _bp="$(/usr/bin/which "$_b" 2>/dev/null || true)"
    [[ -n "$_bp" ]] && ln -sf "$_bp" "$_sys_path/$_b"
done
unset _b _bp

# Installer subprocess PATH: mock tools shadow checked prereqs; sysbin provides
# low-level utilities and bash. No other directories are included, so only
# binaries we explicitly place in _mock_path or _sys_path are visible.
_INST_PATH="$_mock_path:$_sys_path"

_run_installer() {
    # Usage: _run_installer [VAR=val ...] [--path PATH_OVERRIDE]
    # Forwards VAR=val pairs as environment overrides to the installer.
    local run_path="$_INST_PATH"
    local -a env_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path) run_path="$2"; shift 2 ;;
            *)      env_args+=("$1"); shift ;;
        esac
    done
    env PATH="$run_path" "${env_args[@]}" "$_real_bash" "$REPO_ROOT/scripts/install-remote.sh"
}

# ─── Mock tarball ─────────────────────────────────────────────────────────────
# GitHub release tarballs have a top-level directory like zBuild-v0.1.0/ so
# after `tar --strip-components=1` you get the repo contents in INSTALL_DIR.
# We mirror that structure: staging/top/scripts/zbuild → strips to scripts/zbuild.
_make_mock_tarball() {
    local dest="$1"
    local staging="$TEST_TEMP_DIR/tarball-staging"
    local top="$staging/top"
    mkdir -p "$top/scripts"
    printf '#!/usr/bin/env bash\necho "zbuild 0.1.0"\n' > "$top/scripts/zbuild"
    chmod +x "$top/scripts/zbuild"
    # Archive the top/ dir so paths in tarball are top/scripts/zbuild;
    # --strip-components=1 removes 'top/' leaving scripts/zbuild.
    tar -czf "$dest" -C "$staging" top
}
_make_mock_tarball "$TEST_TEMP_DIR/mock-zbuild.tar.gz"

# ─── curl mock (standard) ─────────────────────────────────────────────────────
# The installer calls curl two ways:
#   curl -sSf <url>              → stdout (API JSON)
#   curl -sSfL <url> -o <dest>  → write tarball to dest
# We parse -o explicitly; URL is the last non-flag non-dest argument.
_write_curl_mock() {
    local tarball="$1"
    cat > "$_mock_path/curl" <<CURLEOF
#!/usr/bin/env bash
out=""
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
    if [[ "\${args[\$i]}" == "-o" ]]; then
        out="\${args[\$((i+1))]}"
        i=\$((i+2))
    else
        i=\$((i+1))
    fi
done
url=""
for arg in "\${args[@]}"; do
    [[ "\$arg" != -* ]] && [[ "\$arg" != "\$out" ]] && url="\$arg"
done
if [[ "\$url" == *"releases/latest"* ]]; then
    printf '{"tag_name":"v0.1.0"}'
elif [[ "\$url" == *"archive"* ]] && [[ -n "\$out" ]]; then
    /bin/cp "${tarball}" "\$out"
fi
exit 0
CURLEOF
    chmod +x "$_mock_path/curl"
}
_write_curl_mock "$TEST_TEMP_DIR/mock-zbuild.tar.gz"

# ─── jq mock (standard — echoes tag) ─────────────────────────────────────────
_write_jq_mock() {
    local tag="${1:-v0.1.0}"
    cat > "$_mock_path/jq" <<EOF
#!/usr/bin/env bash
echo "$tag"
EOF
    chmod +x "$_mock_path/jq"
}

# setup_test_env may have symlinked real jq; overwrite with our mock.
rm -f "$_mock_path/jq"
_write_jq_mock "v0.1.0"

# git mock — required prerequisite; installer just checks presence.
cat > "$_mock_path/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$_mock_path/git"

# gh mock — optional; installer only warns if absent.
cat > "$_mock_path/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$_mock_path/gh"

# ─── TC-1: All prereqs present → script succeeds ────────────────────────────
print_test_section "TC-1: successful install exits 0"
set +e
output="$(_run_installer \
    ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/zbuild-install-1" \
    ZBUILD_BIN_DIR="$TEST_TEMP_DIR/usr-bin-1" \
    2>&1)"
rc=$?
set -e
assert_eq "TC-1: successful install exits 0" "0" "$rc"

# ─── TC-2: jq missing → exits 1 ─────────────────────────────────────────────
print_test_section "TC-2: missing jq exits 1"
rm -f "$_mock_path/jq"
set +e
output="$(_run_installer 2>&1)"
rc=$?
set -e
assert_eq "TC-2: missing jq exits 1" "1" "$rc"
_write_jq_mock "v0.1.0"

# ─── TC-3: curl missing → exits 1 ───────────────────────────────────────────
print_test_section "TC-3: missing curl exits 1"
rm -f "$_mock_path/curl"
set +e
output="$(_run_installer 2>&1)"
rc=$?
set -e
assert_eq "TC-3: missing curl exits 1" "1" "$rc"
_write_curl_mock "$TEST_TEMP_DIR/mock-zbuild.tar.gz"

# ─── TC-4: git missing → exits 1 ────────────────────────────────────────────
print_test_section "TC-4: missing git exits 1"
rm -f "$_mock_path/git"
set +e
output="$(_run_installer 2>&1)"
rc=$?
set -e
assert_eq "TC-4: missing git exits 1" "1" "$rc"
# Restore git mock
cat > "$_mock_path/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$_mock_path/git"

# ─── TC-5: Multiple missing deps → lists all in output ──────────────────────
print_test_section "TC-5: multiple missing deps listed in output"
rm -f "$_mock_path/jq" "$_mock_path/git"
set +e
output="$(_run_installer 2>&1)"
rc=$?
set -e
assert_eq "TC-5: multiple missing → exits 1" "1" "$rc"
if grep -qE "jq|git" <<< "$output"; then
    assert_pass "TC-5: missing tools mentioned in output"
else
    assert_fail "TC-5: missing tools mentioned in output" "output: $output"
fi
_write_jq_mock "v0.1.0"
cat > "$_mock_path/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$_mock_path/git"

# ─── TC-6: GitHub API returns null tag → exits 1 ────────────────────────────
print_test_section "TC-6: null tag from API exits 1"
_write_jq_mock "null"
set +e
output="$(_run_installer 2>&1)"
rc=$?
set -e
assert_eq "TC-6: null tag → exits 1" "1" "$rc"
_write_jq_mock "v0.1.0"

# ─── TC-7: Symlink created at BIN_DIR/zbuild after successful install ────────
print_test_section "TC-7: symlink created"
set +e
_run_installer \
    ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/zbuild-install-7" \
    ZBUILD_BIN_DIR="$TEST_TEMP_DIR/usr-bin-7" \
    >/dev/null 2>&1
rc=$?
set -e
assert_eq "TC-7: install exits 0" "0" "$rc"
if [[ -L "$TEST_TEMP_DIR/usr-bin-7/zbuild" ]]; then
    assert_pass "TC-7: symlink exists at ZBUILD_BIN_DIR/zbuild"
else
    assert_fail "TC-7: symlink exists at ZBUILD_BIN_DIR/zbuild" \
        "expected symlink at $TEST_TEMP_DIR/usr-bin-7/zbuild"
fi

# ─── TC-8: ZBUILD_INSTALL_DIR override respected ────────────────────────────
print_test_section "TC-8: ZBUILD_INSTALL_DIR override"
custom_dir="$TEST_TEMP_DIR/custom-install-8"
set +e
_run_installer \
    ZBUILD_INSTALL_DIR="$custom_dir" \
    ZBUILD_BIN_DIR="$TEST_TEMP_DIR/usr-bin-8" \
    >/dev/null 2>&1
rc=$?
set -e
assert_eq "TC-8: exits 0 with custom INSTALL_DIR" "0" "$rc"
if [[ -f "$custom_dir/scripts/zbuild" ]]; then
    assert_pass "TC-8: content extracted to ZBUILD_INSTALL_DIR"
else
    assert_fail "TC-8: content extracted to ZBUILD_INSTALL_DIR" \
        "expected $custom_dir/scripts/zbuild to exist"
fi

# ─── TC-9: zbuild doctor called at end (mock zbuild writes sentinel) ─────────
print_test_section "TC-9: zbuild doctor is called after install"
# The installer does: ln -sf "$INSTALL_DIR/scripts/zbuild" "$BIN_DIR/zbuild"
# then calls "$BIN_DIR/zbuild" doctor.
# We make the tarball contain a doctor-sentinel zbuild script so that after
# the ln -sf, calling "$BIN_DIR/zbuild" doctor writes the sentinel file.
sentinel="$TEST_TEMP_DIR/doctor-called"
doctor_staging="$TEST_TEMP_DIR/tarball-staging-doctor"
mkdir -p "$doctor_staging/top/scripts"
cat > "$doctor_staging/top/scripts/zbuild" <<ZBEOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "doctor" ]]; then
    /usr/bin/touch "${sentinel}"
fi
exit 0
ZBEOF
chmod +x "$doctor_staging/top/scripts/zbuild"
tar -czf "$TEST_TEMP_DIR/mock-doctor.tar.gz" -C "$doctor_staging" top

_write_curl_mock "$TEST_TEMP_DIR/mock-doctor.tar.gz"
doctor_bin="$TEST_TEMP_DIR/doctor-bin-9"
mkdir -p "$doctor_bin"
set +e
_run_installer \
    ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/zbuild-install-9" \
    ZBUILD_BIN_DIR="$doctor_bin" \
    >/dev/null 2>&1
rc=$?
set -e
if [[ -f "$sentinel" ]]; then
    assert_pass "TC-9: zbuild doctor was called"
else
    assert_fail "TC-9: zbuild doctor was called" "sentinel file not created"
fi
# Restore standard curl mock
_write_curl_mock "$TEST_TEMP_DIR/mock-zbuild.tar.gz"

# ─── TC-10: gh missing → warns but does not exit 1 ──────────────────────────
print_test_section "TC-10: gh missing → only a warning, not a hard failure"
rm -f "$_mock_path/gh"
set +e
output="$(_run_installer \
    ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/zbuild-install-10" \
    ZBUILD_BIN_DIR="$TEST_TEMP_DIR/usr-bin-10" \
    2>&1)"
rc=$?
set -e
assert_eq "TC-10: missing gh still exits 0" "0" "$rc"
if grep -qi "gh" <<< "$output"; then
    assert_pass "TC-10: gh warning present in output"
else
    assert_fail "TC-10: gh warning present in output" "no mention of gh in output"
fi
# Restore gh mock
cat > "$_mock_path/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$_mock_path/gh"

# ─── TC-11: ZBUILD_BIN_DIR already on PATH → no advisory printed ─────────────
print_test_section "TC-11: BIN_DIR on PATH → no PATH advisory"
bin_11="$TEST_TEMP_DIR/usr-bin-11"
mkdir -p "$bin_11"
set +e
output="$(env PATH="$bin_11:$_INST_PATH" \
    ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/zbuild-install-11" \
    ZBUILD_BIN_DIR="$bin_11" \
    "$_real_bash" "$REPO_ROOT/scripts/install-remote.sh" 2>&1)"
rc=$?
set -e
assert_eq "TC-11: exits 0 when BIN_DIR on PATH" "0" "$rc"
if grep -q "not on your PATH" <<< "$output"; then
    assert_fail "TC-11: no PATH advisory when BIN_DIR already on PATH" \
        "advisory was printed unexpectedly"
else
    assert_pass "TC-11: no PATH advisory when BIN_DIR already on PATH"
fi

# ─── TC-12: BIN_DIR NOT on PATH → advisory printed ───────────────────────────
print_test_section "TC-12: BIN_DIR not on PATH → advisory printed"
offpath_bin="$TEST_TEMP_DIR/offpath-bin-12"
mkdir -p "$offpath_bin"
set +e
output="$(_run_installer \
    ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/zbuild-install-12" \
    ZBUILD_BIN_DIR="$offpath_bin" \
    2>&1)"
# rc may be non-zero if zbuild doctor can't run; that's acceptable here.
set -e
if grep -q "not on your PATH" <<< "$output"; then
    assert_pass "TC-12: PATH advisory printed when BIN_DIR absent from PATH"
else
    assert_fail "TC-12: PATH advisory printed when BIN_DIR absent from PATH" \
        "advisory not found in output"
fi

# ─── TC-13: Install complete message present ─────────────────────────────────
print_test_section "TC-13: installation complete message"
set +e
output="$(_run_installer \
    ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/zbuild-install-13" \
    ZBUILD_BIN_DIR="$TEST_TEMP_DIR/usr-bin-13" \
    2>&1)"
rc=$?
set -e
assert_eq "TC-13: exits 0" "0" "$rc"
if grep -qi "installation complete\|Install.*complete" <<< "$output"; then
    assert_pass "TC-13: completion message present"
else
    assert_fail "TC-13: completion message present" "output: $output"
fi

# ─── Teardown ────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
