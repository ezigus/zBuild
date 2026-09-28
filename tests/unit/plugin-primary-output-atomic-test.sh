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
    elif grep -E 'atomic_write[[:space:]]+"\$' "${plugin_srcs[@]}" >/dev/null 2>&1 \
        && grep -F "$base" "${plugin_srcs[@]}" >/dev/null 2>&1; then
        assert_pass "$plugin_dir: primary $base (indirect atomic_write reference)"
    elif grep -E 'atomic_write[[:space:]]+"\$' "${plugin_srcs[@]}" >/dev/null 2>&1 \
        && [[ -n "$base_suffix" && "$base_suffix" != "$base" ]] \
        && grep -F "$base_suffix" "${plugin_srcs[@]}" >/dev/null 2>&1; then
        assert_pass "$plugin_dir: primary $base (indirect via *-${base_suffix})"
    else
        assert_fail "$plugin_dir: primary $base NOT written via atomic_write" \
            "see ${plugin_sh#$REPO_ROOT/}"
        violations=$((violations + 1))
    fi
done

if [[ $checked -eq 0 ]]; then
    assert_fail "no primary outputs found across plugins" "manifest scan returned 0"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
