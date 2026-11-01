#!/usr/bin/env bash
# Tests: every manifest-declared `primary: true` output is written through
# atomic_write in the plugin's plugin.sh. Grep-based static check (#507).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "primary-output atomicity guard (#507)"

# Extract the basename of a manifest path (e.g. "${artifact_dir}/x.json" -> "x.json")
_basename_path() {
    local p="$1"
    p="${p##*/}"
    printf '%s' "$p"
}

shopt -s nullglob
checked=0
violations=0
for manifest in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    plugin_dir="$(dirname "$manifest")"
    plugin_sh="$plugin_dir/plugin.sh"
    [[ -f "$plugin_sh" ]] || continue

    row="$(manifest_graph_primary_output "$manifest" 2>/dev/null || true)"
    [[ -z "$row" ]] && continue
    IFS='|' read -r p_id p_type _ p_req p_path <<< "$row"
    [[ -z "$p_path" ]] && continue
    base="$(_basename_path "$p_path")"
    [[ -z "$base" ]] && continue

    checked=$((checked + 1))

    # Accept any of:
    #   (a) direct: `atomic_write "...<base>..."` literal
    #   (b) indirect-via-var: `atomic_write "$..."` invocation AND the
    #       basename appears literally somewhere in the file
    #   (c) indirect-via-var + suffix: `atomic_write "$..."` AND the basename's
    #       trailing word (e.g. "findings.json") appears — covers manifests
    #       whose path interpolates a prefix (security${infix}-findings.json).
    #   (d) stage_result_write / stage_result_add AND the basename appears (#2366)
    # Search plugin.sh AND lib/*.sh (decomposed plugins store logic in lib/).
    base_suffix="${base#*-}"  # strip leading "prefix-" if present
    # shellcheck disable=SC2207
    plugin_srcs=("$plugin_sh")
    # shellcheck disable=SC2206
    if compgen -G "$plugin_dir/lib/*.sh" >/dev/null 2>&1; then
        plugin_srcs+=( "$plugin_dir"/lib/*.sh )
    fi
    if grep -E "atomic_write[^|]*${base//./\\.}" "${plugin_srcs[@]}" >/dev/null 2>&1; then
        assert_pass "$plugin_dir: primary $base written via atomic_write"
    elif grep -E '^[^#]*stage_result_(write|add)[[:space:]]' "${plugin_srcs[@]}" >/dev/null 2>&1 \
        && grep -F "$base" "${plugin_srcs[@]}" >/dev/null 2>&1; then
        # #2366: the one result writer (scripts/lib/stage-result.sh) writes via atomic_write.
        assert_pass "$plugin_dir: primary $base written via stage_result_write (atomic)"
    elif grep -E 'atomic_write[[:space:]]+"\$' "${plugin_srcs[@]}" >/dev/null 2>&1 \
        && grep -F "$base" "${plugin_srcs[@]}" >/dev/null 2>&1; then
        assert_pass "$plugin_dir: primary $base (indirect atomic_write reference)"
    elif grep -E 'atomic_write[[:space:]]+"\$' "${plugin_srcs[@]}" >/dev/null 2>&1 \
        && [[ -n "$base_suffix" && "$base_suffix" != "$base" ]] \
        && grep -F "$base_suffix" "${plugin_srcs[@]}" >/dev/null 2>&1; then
        assert_pass "$plugin_dir: primary $base (indirect via *-${base_suffix})"
    elif grep -E 'stage_result_(write|add)[[:space:]]' "${plugin_srcs[@]}" >/dev/null 2>&1 \
        && grep -F "$base" "${plugin_srcs[@]}" >/dev/null 2>&1; then
        # #2366: the one result writer writes through atomic_write.
        assert_pass "$plugin_dir: primary $base (via stage_result_write)"
    else
        assert_fail "$plugin_dir: primary $base NOT written via atomic_write" \
            "see ${plugin_sh#$REPO_ROOT/}"
        violations=$((violations + 1))
    fi
done

if [[ $checked -eq 0 ]]; then
    assert_fail "no primary outputs found across plugins" "manifest scan returned 0"
fi

# ─── [#1754/SPEC-5] lint-atomic-write-unchecked detects a bare | atomic_write ─
# Before #1754: scripts/lib/lint-atomic-write-unchecked.sh does not exist.
# After #1754: it exists and exits non-zero with the violating line in its output
# when given a .sh file that pipes to atomic_write without an error check.
print_test_section "[#1754/SPEC-5] lint-atomic-write-unchecked exits non-zero for unchecked call"

_LINT_SCRIPT="$REPO_ROOT/scripts/lib/lint-atomic-write-unchecked.sh"
_SPEC5_FIXTURE="$TEST_TEMP_DIR/spec5-unchecked.sh"
cat > "$_SPEC5_FIXTURE" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
_write_it() {
    printf '%s\n' "hello" | atomic_write "/some/output/path"
}
FIXTURE

_spec5_rc=0
_spec5_out="$(bash "$_LINT_SCRIPT" "$_SPEC5_FIXTURE" 2>&1)" || _spec5_rc=$?

if [[ "$_spec5_rc" -ne 0 ]]; then
    assert_pass "[#1754/SPEC-5] lint exits non-zero for unchecked atomic_write"
else
    assert_fail "[#1754/SPEC-5] lint exits non-zero for unchecked atomic_write" \
        "exit code was 0; output: $_spec5_out"
fi

# The output must name the violating line as file:lineno.  The fixture has
# exactly one atomic_write call, on line 4 of the file.  Checking for the
# fixture basename followed by ":4" (fixed-string, so the "." in the filename
# is not a wildcard) proves the lint reported the specific line that contains
# the violation, not merely that the filename appeared somewhere in the output.
_spec5_fixture_base="$(basename "$_SPEC5_FIXTURE")"
if grep -qF "${_spec5_fixture_base}:4" <<< "$_spec5_out"; then
    assert_pass "[#1754/SPEC-5] lint names the violating line in its output"
else
    assert_fail "[#1754/SPEC-5] lint names the violating line in its output" \
        "expected ${_spec5_fixture_base}:4 in output; got: $_spec5_out"
fi

# ─── [#1754/SPEC-6] lint exits 0 for properly-checked atomic_write calls ──────
# The lint script must not flag calls whose exit is checked on the same or next
# physical line via &&, ||, if !, or PIPESTATUS that includes the write index.
print_test_section "[#1754/SPEC-6] lint exits 0 when every atomic_write call is checked"

_SPEC6_FIXTURE="$TEST_TEMP_DIR/spec6-checked.sh"
cat > "$_SPEC6_FIXTURE" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
# Same-line || check.
printf '%s\n' "hello" | atomic_write "/path/a" || exit 1
# Same-line && check.
printf '%s\n' "world" | atomic_write "/path/b" && echo ok
# Next-line || true annotation.
printf '%s\n' "aux" | atomic_write "/path/c" \
    || true
# PIPESTATUS capturing the write index.
printf '%s\n' "data" | atomic_write "/path/d"
local _aw_rc="${PIPESTATUS[1]}"
# if ! check.
if ! printf '%s\n' "val" | atomic_write "/path/e"; then echo "failed"; fi
FIXTURE

_spec6_rc=0
_spec6_out="$(bash "$_LINT_SCRIPT" "$_SPEC6_FIXTURE" 2>&1)" || _spec6_rc=$?

assert_eq "[#1754/SPEC-6] lint exits 0 for properly-checked calls" "0" "$_spec6_rc"

# ─── [#1754/SPEC-7] package.json lint target invokes lint-atomic-write-unchecked ─
# The lint script is wired into `npm run lint` so CI enforces it on every PR.
print_test_section "[#1754/SPEC-7] package.json lint target contains lint-atomic-write-unchecked"

_PACKAGE_JSON="$REPO_ROOT/package.json"
# Extract only the line containing the "lint" key, then check that line
# contains the invocation.  If the invocation were in a different target
# (test, build, etc.) the "lint" line would not contain it and the
# assertion would correctly fail.
_s7_lint_line="$(grep '"lint"' "$_PACKAGE_JSON" 2>/dev/null || true)"
if grep -qF 'bash scripts/lib/lint-atomic-write-unchecked.sh' <<< "$_s7_lint_line"; then
    assert_pass "[#1754/SPEC-7] package.json lint target contains bash scripts/lib/lint-atomic-write-unchecked.sh"
else
    assert_fail "[#1754/SPEC-7] package.json lint target must contain bash scripts/lib/lint-atomic-write-unchecked.sh" \
        "not found in the lint target of $REPO_ROOT/package.json"
fi

# ─── [#1754/SPEC-5b] a PIPESTATUS capture of only the producer is no check ──
# The test stage's bug was exactly this: it read PIPESTATUS[0] (jq) and never
# the write's index, so a failed write passed. The lint must flag it.
print_test_section "[#1754/SPEC-5b] lint flags a PIPESTATUS capture that misses the write"

_SPEC5B_FIXTURE="$TEST_TEMP_DIR/spec5b-producer-only.sh"
cat > "$_SPEC5B_FIXTURE" <<'FIXTURE'
_write_it() {
    jq -n '{}' \
      | atomic_write "/some/output/path"
    local _rc="${PIPESTATUS[0]}"
}
FIXTURE
_spec5b_rc=0
_spec5b_out="$(bash "$_LINT_SCRIPT" "$_SPEC5B_FIXTURE" 2>&1)" || _spec5b_rc=$?
assert_eq "[#1754/SPEC-5b] lint exits non-zero for a PIPESTATUS[0]-only capture" "1" "$_spec5b_rc"
assert_contains "[#1754/SPEC-5b] lint names that line" "$_spec5b_out" "spec5b-producer-only.sh:3"

# ─── [#1754/SPEC-8] the real tree passes the lint ────────────────────────────
# R3: "Existing safe uses pass." Every | atomic_write in core/, plugins/ and
# scripts/ checks its write, so the lint over the whole tree exits 0.
print_test_section "[#1754/SPEC-8] the lint passes on core/, plugins/ and scripts/"

_spec8_rc=0
_spec8_out="$(bash "$_LINT_SCRIPT" 2>&1)" || _spec8_rc=$?
assert_eq "[#1754/SPEC-8] lint exits 0 on the real tree (output: ${_spec8_out:0:400})" "0" "$_spec8_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
