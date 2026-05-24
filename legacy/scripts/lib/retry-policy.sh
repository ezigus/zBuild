#!/usr/bin/env bash
# retry-policy.sh — Single source of truth for all retry caps.
# Source this file to get RETRY_MAX_PIPELINE_STARTS, RETRY_MAX_AUTO_RETRIES,
# RETRY_ABANDON_AFTER_MINUTES read from config/policy.json via policy_get.
# Usage: source "$SCRIPT_DIR/lib/retry-policy.sh"
[[ -n "${_RETRY_POLICY_LOADED:-}" ]] && return 0
_RETRY_POLICY_LOADED=1

_RETRY_POLICY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set REPO_DIR so policy.sh resolves config/policy.json from the repo root.
REPO_DIR="${REPO_DIR:-$(cd "$_RETRY_POLICY_DIR/../.." && pwd)}"
# shellcheck source=scripts/lib/policy.sh
source "$_RETRY_POLICY_DIR/policy.sh"

RETRY_MAX_PIPELINE_STARTS=$(policy_get '.retry.max_pipeline_starts' 6)
RETRY_MAX_AUTO_RETRIES=$(policy_get '.retry.max_auto_retries' 3)
RETRY_ABANDON_AFTER_MINUTES=$(policy_get '.retry.abandon_after_minutes' 120)

export RETRY_MAX_PIPELINE_STARTS RETRY_MAX_AUTO_RETRIES RETRY_ABANDON_AFTER_MINUTES
