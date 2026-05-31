#!/usr/bin/env bash
# Tests: scripts/deferred-tracker.sh::is_bot_author
#
# Behavioral coverage for ADR-020 §Bot-author skip. CRITICAL: must use
# author.type field, not name-substring matching (spoofing-resistant).
# Regression lock: account named "dependabot-helper" with type "User" is NOT a bot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/deferred-tracker.sh
source "$REPO_ROOT/scripts/deferred-tracker.sh"

print_test_header "deferred-tracker — is_bot_author (ADR-020 / #531)"

# ─── Bot type → skip ─────────────────────────────────────────────────────────
if is_bot_author '{"login":"dependabot[bot]","type":"Bot"}'; then
    assert_pass "B1: type=Bot → skip"
else
    assert_fail "B1: type=Bot should skip but didn't"
fi

if is_bot_author '{"login":"github-actions[bot]","type":"Bot"}'; then
    assert_pass "B2: github-actions Bot → skip"
else
    assert_fail "B2: github-actions Bot should skip"
fi

# ─── App type → treat as bot ─────────────────────────────────────────────────
if is_bot_author '{"login":"some-app","type":"App"}'; then
    assert_pass "B3: type=App → skip"
else
    assert_fail "B3: type=App should skip"
fi

# ─── REGRESSION LOCK: spoofing-resistant ─────────────────────────────────────
# A human account with a bot-like login MUST NOT be skipped.
if is_bot_author '{"login":"dependabot-helper","type":"User"}'; then
    assert_fail "B4 REGRESSION: dependabot-helper User type wrongly skipped"
else
    assert_pass "B4: User type with bot-like login NOT skipped (spoofing-resistant)"
fi

if is_bot_author '{"login":"fake-github-actions","type":"User"}'; then
    assert_fail "B5 REGRESSION: fake-github-actions User type wrongly skipped"
else
    assert_pass "B5: fake-github-actions NOT skipped"
fi

# ─── Normal user → not skip ──────────────────────────────────────────────────
if is_bot_author '{"login":"ezigus","type":"User"}'; then
    assert_fail "B6: normal user wrongly skipped"
else
    assert_pass "B6: normal user not skipped"
fi

# ─── Missing/Unknown type → fail-open (not skip) ─────────────────────────────
if is_bot_author '{}'; then
    assert_fail "B7: empty author wrongly skipped"
else
    assert_pass "B7: empty author not skipped (fail-open)"
fi

print_test_results
