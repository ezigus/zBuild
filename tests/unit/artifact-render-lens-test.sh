#!/usr/bin/env bash
# Tests: scripts/lib/artifact-render.sh — lens renderers (Issue OUT, ADR-015/039)
# Covers the human-readable review_lenses output surface:
#   - render_lens_one_line: ONE terminal line per lens (glyph, name, score,
#     finding count, highest-severity top finding), no raw JSON.
#   - render_lens_md + registry: review-lens / security-lens dispatch to a prose
#     renderer so render_artifact never passes raw JSON through.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# test-helpers.sh sets colors unconditionally; strip ANSI so line-shape regexes
# are stable (the render helpers wrap the line in DIM/RESET).
_strip_ansi() { LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g'; }

print_test_header "artifact-render lens renderers (Issue OUT)"
setup_test_env "artifact-render-lens"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

adir="$TEST_TEMP_DIR/artifacts"
mkdir -p "$adir"

# ─── T1: render_lens_one_line emits exactly one line ─────────────────────────
print_test_section "T1: one line, score + count + top finding"
cat > "$adir/lens-security.json" <<'EOF'
{"schema_version":1,"name":"security","score":7,"findings":[
  {"file":"core/a.sh","severity":"low","line":3,"message":"minor nit"},
  {"file":"core/b.sh","severity":"high","line":42,"message":"unquoted expansion allows word-splitting on attacker input"},
  {"file":"core/c.sh","severity":"medium","line":9,"message":"prefer printf"}
]}
EOF
out="$(render_lens_one_line security "$adir" 2>&1 | _strip_ansi)"
lines="$(printf '%s\n' "$out" | grep -c .)"
assert_eq "T1 exactly one line" "1" "$lines"
if grep -qE '^✓ security — 7/10, 3 findings \(top: ' <<< "$out"; then
    assert_pass "T1 one-liner shape matches (✓ security — 7/10, 3 findings (top: …))"
else
    assert_fail "T1 one-liner shape" "got: $out"
fi

# ─── T2: highest-severity finding is chosen as "top" ─────────────────────────
print_test_section "T2: top finding = highest severity (critical > … > low)"
cat > "$adir/lens-red-team.json" <<'EOF'
{"schema_version":1,"name":"red-team","score":4,"findings":[
  {"file":"x.sh","severity":"low","line":1,"message":"style"},
  {"file":"y.sh","severity":"critical","line":2,"message":"command injection via eval"}
]}
EOF
out="$(render_lens_one_line red-team "$adir" 2>&1)"
assert_contains "T2 picks critical as top" "$out" "top: critical"

# ─── T3: zero findings ───────────────────────────────────────────────────────
print_test_section "T3: zero findings → 'no findings'"
cat > "$adir/lens-performance.json" <<'EOF'
{"schema_version":1,"name":"performance","score":9,"findings":[]}
EOF
out="$(render_lens_one_line performance "$adir" 2>&1)"
lines="$(printf '%s\n' "$out" | grep -c .)"
assert_eq "T3 one line" "1" "$lines"
assert_contains "T3 no-findings shape" "$out" "✓ performance — 9/10, no findings"

# ─── T4: missing artifact → ⚠ no result ──────────────────────────────────────
print_test_section "T4: missing artifact → ⚠ <name> — no result"
set +e
out="$(render_lens_one_line scope "$adir" 2>&1)"
rc=$?
set -e
assert_eq "T4 rc=0 (best-effort)" "0" "$rc"
assert_contains "T4 missing-artifact shape" "$out" "⚠ scope — no result"

# ─── T5: render_lens_md registered for review-lens AND security-lens ─────────
print_test_section "T5: renderers registered"
assert_eq "T5 review-lens → render_lens_md"   "render_lens_md" "$(artifact_renderer_for review-lens)"
assert_eq "T5 security-lens → render_lens_md" "render_lens_md" "$(artifact_renderer_for security-lens)"

# ─── T6: render_artifact review-lens does NOT passthrough raw JSON ───────────
print_test_section "T6: render_artifact never leaks raw JSON"
_blob='{"score":7,"name":"security","findings":[{"file":"core/b.sh","severity":"high","line":42,"message":"bad"}]}'
out="$(render_artifact review-lens "$_blob")"
if grep -q '{"score"' <<< "$out"; then
    assert_fail "T6 no raw JSON in rendered review-lens" "raw JSON leaked: $out"
else
    assert_pass "T6 render_artifact review-lens does not echo raw JSON"
fi
assert_contains "T6 rendered output has a severity bullet" "$out" "[high]"

# ─── T7: render_lens_md tolerates security-lens schema (no score, plugin_id) ─
print_test_section "T7: security-lens schema (no score) renders without error"
_sec='{"plugin_id":"security-lens","findings":[{"file":"z.sh","severity":"critical","line":1,"message":"eval user input"}]}'
set +e
out="$(render_artifact security-lens "$_sec")"
rc=$?
set -e
assert_eq "T7 render_artifact rc=0" "0" "$rc"
if grep -q '{"plugin_id"' <<< "$out"; then
    assert_fail "T7 no raw JSON for security-lens" "raw JSON leaked: $out"
else
    assert_pass "T7 security-lens (no score) rendered to prose, no raw JSON"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
