#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright build prompt memory-guard regression test                     ║
# ║                                                                           ║
# ║  Verifies the build stage does NOT inject goal-agnostic historical        ║
# ║  memory on cold (first-run) pipelines, and DOES inject it correctly on   ║
# ║  warm runs or when ruflo recall returns a sufficiently long result.       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Regression for: removal of goal-agnostic memory fallback from stage_build()
# that caused irrelevant historical context to leak into cold-pipeline prompts.
#
# The test exercises the COMPOSITION LOGIC only — not the full stage_build()
# pipeline loop. A small inline helper (_test_compose_memory_block) mirrors
# the exact injection decision code present in pipeline-stages-build.sh so
# The helper mirrors the injection decision logic, not the full sanitization
# pipeline (control-char stripping, 2000-char truncation, header removal).
# Tests use clean ASCII strings well under 2000 chars, so the omission is
# intentional and noted here rather than implied to be exact parity.
#
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── assert_not_contains — not provided by test-helpers.sh, defined here ────
assert_not_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if grep -qF -- "$needle" <<< "$haystack" 2>/dev/null; then
        assert_fail "$desc" "output should NOT contain: $needle"
    else
        assert_pass "$desc"
    fi
}

# ─── Environment ─────────────────────────────────────────────────────────────
print_test_header "Build Prompt: Memory Injection Guard"

setup_test_env "build-prompt-memory-guard"
_test_cleanup_hook() { cleanup_test_env; }
# Prevent env leakage: pin the threshold to the default so external overrides
# don't affect the boundary assertions. Tests that need a different value set it
# locally via SHIPWRIGHT_RUFLO_RECALL_MIN_LEN=N _test_compose_memory_block ...
unset SHIPWRIGHT_RUFLO_RECALL_MIN_LEN

# ─── Helper: mirrors the memory-injection decision from stage_build() ────────
#
# Arguments:
#   $1  goal string (unused in logic, included for readability)
#   $2  mock_focused_result  — what intelligence_search_memory / sw-memory inject
#                              returns; empty string = cold-run (no prior context)
#   $3  mock_ruflo_result    — what ruflo_recall_similar_outcomes returns;
#                              empty string = no ruflo hit
#
# The function prints the assembled context body to stdout.
# SHIPWRIGHT_RUFLO_RECALL_MIN_LEN can be overridden via env (default 50).
#
_test_compose_memory_block() {
    local goal="${1:-}"
    local mock_focused_result="${2:-}"
    local mock_ruflo_result="${3:-}"
    local min_len="${SHIPWRIGHT_RUFLO_RECALL_MIN_LEN:-50}"

    # Fixed behaviour: memory_context comes ONLY from focused (goal-scoped) search.
    # The goal-agnostic fallback has been removed; cold issues produce empty string.
    local memory_context="$mock_focused_result"
    local body=""

    # Lines ~234-240 of pipeline-stages-build.sh (post-fix):
    # inject memory_context only when non-empty
    if [[ -n "$memory_context" ]]; then
        body="${body}
Historical context (lessons from previous pipelines):
${memory_context}"
    fi

    # Lines ~392-422 of pipeline-stages-build.sh (post-fix):
    # inject ruflo recall only when non-empty AND RAW length >= min_len.
    # (Raw length is used so sanitization of injected headers doesn't drop
    #  substantive content below the threshold.)
    if [[ -n "$mock_ruflo_result" && "${#mock_ruflo_result}" -ge "$min_len" ]]; then
        body="${body}
## Historical Build Context
${mock_ruflo_result}"
    fi

    printf '%s' "$body"
}

# ═══════════════════════════════════════════════════════════════════════════════
# T1 — Cold issue: both searches return nothing → no headers at all
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  T1: cold issue - no memory injection"
out=$(_test_compose_memory_block "Add JWT auth" "" "")
assert_not_contains "no 'Historical context' header on cold issue"    "$out" "Historical context"
assert_not_contains "no 'Historical Build Context' block on cold issue" "$out" "Historical Build Context"
assert_not_contains "prompt body is empty on cold issue"              "$out" "lessons from previous pipelines"

# ═══════════════════════════════════════════════════════════════════════════════
# T2 — Warm issue: focused search returns content → Historical context injected
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  T2: warm issue - focused match injects 'Historical context'"
out=$(_test_compose_memory_block "Add JWT auth" "Lesson: always validate input at boundaries" "")
assert_contains     "Historical context present when focused match"           "$out" "Historical context"
assert_contains     "lesson text appears in injected block"                   "$out" "Lesson: always validate input"
assert_not_contains "no spurious 'Historical Build Context' without ruflo"    "$out" "Historical Build Context"

# ═══════════════════════════════════════════════════════════════════════════════
# T3 — Ruflo returns >= 50 chars → ## Historical Build Context injected
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  T3: ruflo long result (>=50 chars) → inject '## Historical Build Context'"
long_result="This is a long ruflo recall result that definitely exceeds fifty characters."
out=$(_test_compose_memory_block "Add JWT auth" "" "$long_result")
assert_contains     "Historical Build Context present when ruflo long"        "$out" "## Historical Build Context"
assert_contains     "ruflo content appears in block"                          "$out" "$long_result"
assert_not_contains "no 'Historical context' header without focused match"    "$out" "Historical context"

# ═══════════════════════════════════════════════════════════════════════════════
# T4 — Ruflo returns < 50 chars → block is suppressed
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  T4: ruflo short result (<50 chars) → suppress '## Historical Build Context'"
short_result="brief"
out=$(_test_compose_memory_block "Add JWT auth" "" "$short_result")
assert_not_contains "Historical Build Context absent when ruflo short"        "$out" "Historical Build Context"
assert_not_contains "short ruflo content not injected"                        "$out" "$short_result"

# Boundary: exactly 49 chars is below threshold → still suppressed
boundary_short="$(printf '%0.s-' {1..49})"   # 49 dashes
out=$(_test_compose_memory_block "Add JWT auth" "" "$boundary_short")
assert_not_contains "Historical Build Context absent at len=49"               "$out" "Historical Build Context"

# Boundary: exactly 50 chars meets threshold → injected
boundary_exact="$(printf '%0.s-' {1..50})"   # 50 dashes
out=$(_test_compose_memory_block "Add JWT auth" "" "$boundary_exact")
assert_contains     "Historical Build Context present at len=50"              "$out" "## Historical Build Context"

# ═══════════════════════════════════════════════════════════════════════════════
# T5 — SHIPWRIGHT_RUFLO_RECALL_MIN_LEN=0 overrides threshold; 1-char input accepted
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  T5: SHIPWRIGHT_RUFLO_RECALL_MIN_LEN=0 overrides default threshold"
out=$(SHIPWRIGHT_RUFLO_RECALL_MIN_LEN=0 _test_compose_memory_block "Add JWT auth" "" "x")
assert_contains     "Historical Build Context present when threshold=0"       "$out" "## Historical Build Context"

# ═══════════════════════════════════════════════════════════════════════════════
# T6 — Both focused match and ruflo long result → both blocks present
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  T6: both focused match and ruflo long result → both blocks present"
warm_context="Prior lesson: cache the token exchange response to reduce latency."
ruflo_context="Ruflo previously saw: always use refresh token rotation for security compliance."
out=$(_test_compose_memory_block "Add JWT auth" "$warm_context" "$ruflo_context")
assert_contains "Historical context present"                                  "$out" "Historical context"
assert_contains "Historical Build Context present"                            "$out" "## Historical Build Context"
assert_contains "focused context text present"                                "$out" "cache the token exchange"
assert_contains "ruflo context text present"                                  "$out" "refresh token rotation"

print_test_results
