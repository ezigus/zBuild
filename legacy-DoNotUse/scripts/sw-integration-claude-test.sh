#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright integration-claude test — Budget-limited real Claude smoke   ║
# ║  One minimal API call · Target ~$0.25/PR · Runs in PR gate when secret set║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUDGET_TARGET_USD="0.25"
SCRIPT_TIMEOUT=180

# ─── Skip when no Claude auth (CI without secret, local dev) ─────────────────
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "Skipping integration-claude: no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY (budget-limited PR gate runs only when secret is set)"
    exit 0
fi

if ! command -v claude &>/dev/null; then
    echo "Skipping integration-claude: claude CLI not found (install with: npm install -g @anthropic-ai/claude-code)"
    exit 0
fi

# ─── Pre-flight: verify auth status ──────────────────────────────────────────
echo "Checking claude auth status..."
claude auth status 2>&1 || true

# ─── Single minimal Claude call (tiny prompt, one turn) ────────────────────────
# Target: stay under ~$0.25; one short exchange is well under that.
echo "Running budget-limited Claude smoke (target ~\$${BUDGET_TARGET_USD}/run, one minimal request)..."
out_file=$(mktemp "${TMPDIR:-/tmp}/sw-claude-smoke.XXXXXX")
err_file=$(mktemp "${TMPDIR:-/tmp}/sw-claude-smoke-err.XXXXXX")
cleanup() { rm -f "$out_file" "$err_file"; }
_test_cleanup_hook() { cleanup; }

run_claude() {
    local timeout_cmd=""
    if command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout $SCRIPT_TIMEOUT"
    elif command -v timeout &>/dev/null; then
        timeout_cmd="timeout $SCRIPT_TIMEOUT"
    fi
    # Avoid pipe to preserve exit code; use --output-format to suppress TUI output
    $timeout_cmd claude -p "Reply with exactly: OK" --max-turns 1 \
        > "$out_file" 2>"$err_file"
}
set +e
run_claude
exit_code=$?
set -e

if [[ "$exit_code" -ne 0 ]]; then
    if [[ "$exit_code" -eq 124 ]]; then
        echo "FAIL: Claude smoke timed out after ${SCRIPT_TIMEOUT}s"
    else
        echo "FAIL: Claude call failed (exit $exit_code)"
    fi
    echo "--- stderr ---"
    cat "$err_file" >&2
    echo "--- stdout ---"
    cat "$out_file"
    exit 1
fi

# Truncate to avoid processing excessive output
if [[ "$(wc -c < "$out_file")" -gt 4096 ]]; then
    head -c 4096 "$out_file" > "${out_file}.tmp" && mv "${out_file}.tmp" "$out_file"
fi

if ! grep -q "OK" "$out_file" 2>/dev/null; then
    echo "FAIL: Unexpected response (expected to contain OK):"
    echo "--- stdout ---"
    head -20 "$out_file"
    echo "--- stderr ---"
    cat "$err_file" >&2
    exit 1
fi

echo "PASS: integration-claude smoke completed"
exit 0
