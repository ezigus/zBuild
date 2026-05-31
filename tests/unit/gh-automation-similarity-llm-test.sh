#!/usr/bin/env bash
# Tests: scripts/lib/gh-automation.sh::gha_compute_similarity_llm + gha_llm_marker_to_annotation
#
# Behavioral coverage for LLM tiebreaker fail-open contract (#559, sub-6 of #555).
# CRITICAL: helper must NEVER exit non-zero or return empty score, no matter what.
# Every failure mode produces a usable Jaccard score + an operator-readable marker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/gh-automation.sh
source "$REPO_ROOT/scripts/lib/gh-automation.sh"

print_test_header "gh-automation — LLM similarity tiebreaker fail-open (#559)"

setup_test_env() {
    TEST_CACHE_DIR="$TEST_TEMP_DIR/llm-cache"
    export LLM_TIEBREAKER_CACHE_DIR="$TEST_CACHE_DIR"
    # Default disabled to test the easiest fail-open path first
    unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
}
setup_test_env

# ─── L1: Disabled via env → fail open with marker ──────────────────────────
export LLM_TIEBREAKER_ENABLED=0
got="$(gha_compute_similarity_llm "phase cleanup" "phase router" "0.25")"
assert_eq "L1: disabled env → score|_LLM_UNAVAILABLE_DISABLED" "0.25|_LLM_UNAVAILABLE_DISABLED" "$got"

# ─── L2: REGRESSION LOCK — disabled path NEVER returns non-zero exit ──────
export LLM_TIEBREAKER_ENABLED=0
rc=0
gha_compute_similarity_llm "a" "b" "0.50" >/dev/null || rc=$?
assert_eq "L2 LOCK: disabled path returns rc=0" "0" "$rc"

# ─── L3: REGRESSION LOCK — disabled path NEVER returns empty score ────────
export LLM_TIEBREAKER_ENABLED=0
got="$(gha_compute_similarity_llm "a" "b" "0.33")"
score="${got%%|*}"
[[ "$score" == "0.33" ]] && assert_pass "L3 LOCK: disabled path preserves Jaccard score" \
    || assert_fail "L3 LOCK: disabled path dropped score (got: $score)"

# ─── L4: claude CLI missing → fail open ──────────────────────────────────
# Shim out claude by creating a fake PATH without it
export LLM_TIEBREAKER_ENABLED=1
ORIG_PATH="$PATH"
ISOLATED_BIN="$TEST_TEMP_DIR/isolated-bin"
mkdir -p "$ISOLATED_BIN"
# Copy essential utilities the helper uses but NOT claude
for util in awk jq shasum sha256sum gtimeout timeout cat printf bash sed; do
    if command -v "$util" >/dev/null 2>&1; then
        ln -sf "$(command -v "$util")" "$ISOLATED_BIN/$util" 2>/dev/null || true
    fi
done
export PATH="$ISOLATED_BIN"
got="$(gha_compute_similarity_llm "a" "b" "0.40")"
export PATH="$ORIG_PATH"
[[ "$got" == "0.40|_LLM_UNAVAILABLE_NO_CLI" ]] && assert_pass "L4: missing claude → _LLM_UNAVAILABLE_NO_CLI" \
    || assert_fail "L4: expected _LLM_UNAVAILABLE_NO_CLI, got: $got"

# ─── L5: Credentials missing (claude exists but no API key) → fail open ──
export LLM_TIEBREAKER_ENABLED=1
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
# Stub claude that would succeed if reached
mock_binary "claude" 'echo "{\"result\":\"{\\\"score\\\":0.75}\"}"; exit 0'
got="$(gha_compute_similarity_llm "a" "b" "0.30")"
assert_eq "L5: no creds → _LLM_UNAVAILABLE_NO_CREDS" "0.30|_LLM_UNAVAILABLE_NO_CREDS" "$got"

# ─── L6: claude returns success → LLM score extracted ────────────────────
export LLM_TIEBREAKER_ENABLED=1
export ANTHROPIC_API_KEY="test-key"
mock_binary "claude" 'echo "{\"result\":\"{\\\"score\\\":0.85}\"}"; exit 0'
got="$(gha_compute_similarity_llm "phase a" "phase b" "0.30")"
assert_eq "L6: successful LLM call returns refined score|_LLM_OK" "0.85|_LLM_OK" "$got"

# ─── L7: REGRESSION LOCK — cache hit doesn't re-invoke LLM ───────────────
export LLM_TIEBREAKER_ENABLED=1
export ANTHROPIC_API_KEY="test-key"
CALL_COUNT_FILE="$TEST_TEMP_DIR/claude-call-count"
echo "0" > "$CALL_COUNT_FILE"
mock_binary "claude" "
n=\$(cat '$CALL_COUNT_FILE')
echo \$((n+1)) > '$CALL_COUNT_FILE'
echo '{\"result\":\"{\\\"score\\\":0.60}\"}'
exit 0
"
# Clear cache for fresh start
rm -rf "$TEST_CACHE_DIR" 2>/dev/null || true
gha_compute_similarity_llm "cache test a" "cache test b" "0.30" > /dev/null
gha_compute_similarity_llm "cache test a" "cache test b" "0.30" > /dev/null
count=$(cat "$CALL_COUNT_FILE")
assert_eq "L7 LOCK: cache hit prevents re-invoke (1 call across 2 reads)" "1" "$count"

# ─── L8: claude returns non-zero (network error simulated) → fail open ──
export LLM_TIEBREAKER_ENABLED=1
export ANTHROPIC_API_KEY="test-key"
mock_binary "claude" 'echo "auth error" >&2; exit 1'
got="$(gha_compute_similarity_llm "x" "y" "0.45")"
[[ "$got" == "0.45|_LLM_FAILED_NETWORK" ]] && assert_pass "L8: non-zero exit → _LLM_FAILED_NETWORK" \
    || assert_fail "L8: expected _LLM_FAILED_NETWORK, got: $got"

# ─── L9: claude returns unparseable JSON → fail open ─────────────────────
export LLM_TIEBREAKER_ENABLED=1
export ANTHROPIC_API_KEY="test-key"
mock_binary "claude" 'echo "this is not json at all"; exit 0'
got="$(gha_compute_similarity_llm "x" "y" "0.50")"
[[ "$got" == "0.50|_LLM_FAILED_PARSE" ]] && assert_pass "L9: unparseable response → _LLM_FAILED_PARSE" \
    || assert_fail "L9: expected _LLM_FAILED_PARSE, got: $got"

# ─── L10: REGRESSION LOCK — Jaccard score preserved across all failures ─
export LLM_TIEBREAKER_ENABLED=1
export ANTHROPIC_API_KEY="test-key"
mock_binary "claude" 'exit 1'
for jaccard in "0.00" "0.20" "0.35" "0.99"; do
    got="$(gha_compute_similarity_llm "x" "y" "$jaccard")"
    preserved="${got%%|*}"
    [[ "$preserved" == "$jaccard" ]] || {
        assert_fail "L10 LOCK: failure path dropped Jaccard score ($jaccard → $preserved)"
        break
    }
done
assert_pass "L10 LOCK: failure path preserves Jaccard score across 0.00/0.20/0.35/0.99"

# ─── L11: marker-to-annotation produces human-readable text ──────────────
ann="$(gha_llm_marker_to_annotation "_LLM_OK")"
assert_eq "L11a: _LLM_OK → empty annotation (no marker shown to operator)" "" "$ann"

ann="$(gha_llm_marker_to_annotation "_LLM_UNAVAILABLE_NO_CREDS")"
assert_contains "L11b: NO_CREDS annotation human-readable" "$ann" "credentials"

ann="$(gha_llm_marker_to_annotation "_LLM_FAILED_TIMEOUT")"
assert_contains "L11c: TIMEOUT annotation human-readable" "$ann" "timed out"

ann="$(gha_llm_marker_to_annotation "_LLM_FAILED_PARSE")"
assert_contains "L11d: PARSE annotation human-readable" "$ann" "unparseable"

ann="$(gha_llm_marker_to_annotation "_LLM_UNAVAILABLE_NO_CLI")"
assert_contains "L11e: NO_CLI annotation mentions install" "$ann" "claude CLI"

# ─── L12 REGRESSION LOCK: malformed score strings rejected (Codex review #565) ─
# Without strict regex, awk's numeric coercion would silently accept "0foo" as 0.
export LLM_TIEBREAKER_ENABLED=1
export ANTHROPIC_API_KEY="test-key"
mock_binary "claude" 'echo "{\"result\":\"{\\\"score\\\":\\\"0foo\\\"}\"}"; exit 0'
got="$(gha_compute_similarity_llm "x" "y" "0.40")"
[[ "$got" == "0.40|_LLM_FAILED_PARSE" ]] && assert_pass "L12 LOCK: '0foo' rejected as malformed score" \
    || assert_fail "L12 LOCK: malformed '0foo' wrongly accepted; got: $got"

mock_binary "claude" 'echo "{\"result\":\"{\\\"score\\\":\\\"0.75 likely\\\"}\"}"; exit 0'
got="$(gha_compute_similarity_llm "x" "y" "0.40")"
[[ "$got" == "0.40|_LLM_FAILED_PARSE" ]] && assert_pass "L12 LOCK: '0.75 likely' rejected" \
    || assert_fail "L12 LOCK: '0.75 likely' wrongly accepted; got: $got"

# Sanity: clean decimals still accepted
mock_binary "claude" 'echo "{\"result\":\"{\\\"score\\\":0.65}\"}"; exit 0'
got="$(gha_compute_similarity_llm "x" "y" "0.40")"
assert_eq "L12 sanity: clean 0.65 still accepted" "0.65|_LLM_OK" "$got"

print_test_results
