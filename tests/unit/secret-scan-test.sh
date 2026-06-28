#!/usr/bin/env bash
# Tests: ADR-040 (#1136) — secret-scan gate plugin.
# Verifies the merge-base..HEAD diff scan: a planted fixture secret → fail (with
# the offending path), a clean diff → pass, an empty diff → skip, and an
# allowlisted fixture → pass. Every secret fixture is ASSEMBLED FROM FRAGMENTS at
# runtime so no matchable pattern ever appears literally in THIS source file —
# that keeps the gate from flagging its own test on this very PR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../plugins/tool/secret-scan/plugin.sh
source "$REPO_ROOT/plugins/tool/secret-scan/plugin.sh"

print_test_header "secret-scan gate — diff secret detection (#1136, ADR-040)"
setup_test_env "secret-scan"

GIT="$(command -v git)"

# Fragments → fixtures (kept out of this file as contiguous literals).
AWS_KEY="AKIA""IOSFODNN7EXAMPLE"                       # AKIA + 16 = AWS doc example
CRED_VAL="aabbccddeeff112233"                          # 18-char quoted value
PEM_HDR="$(printf -- '-----%s RSA %s-----' 'BEGIN' 'PRIVATE KEY')"

# run_scan <repo> [allowlist_file] → echoes the result JSON; sets RESULT_PATH.
run_scan() {
    local repo="$1" allow="${2:-}"
    local work="$repo/.work"; mkdir -p "$work/artifacts"
    RESULT_PATH="$work/artifacts/secret-scan-result.json"
    rm -f "$RESULT_PATH"
    ZBUILD_REPO_ROOT="$repo" ZBUILD_SECRET_SCAN_ALLOWLIST_FILE="$allow" \
        secret_scan_run "secret-scan" "$work/state.json" >/dev/null 2>&1 || true
    cat "$RESULT_PATH"
}

# ── Case 1: planted AWS key on a feature branch → fail (with path) ────────────
REPO1="$(setup_git_temp_repo ss-repo1)"
(
    cd "$REPO1"
    "$GIT" checkout -q -b feature
    mkdir -p src
    printf 'aws_access_key_id = "%s"\n' "$AWS_KEY" > src/config.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: add config"
)
OUT1="$(run_scan "$REPO1")"
assert_json_key "C1: AWS key → verdict=fail" "$OUT1" '.verdict' "fail"
assert_json_key "C1: finding rule is aws_access_key_id" "$OUT1" '.findings[0].rule' "aws_access_key_id"
assert_json_key "C1: offending path reported" "$OUT1" '.findings[0].file' "src/config.sh"

# ── Case 2: quoted credential assignment → fail ──────────────────────────────
REPO2="$(setup_git_temp_repo ss-repo2)"
(
    cd "$REPO2"
    "$GIT" checkout -q -b feature
    printf 'api_key = "%s"\n' "$CRED_VAL" > creds.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: creds"
)
OUT2="$(run_scan "$REPO2")"
assert_json_key "C2: credential assignment → verdict=fail" "$OUT2" '.verdict' "fail"
assert_json_key "C2: rule is credential_assignment" "$OUT2" '.findings[0].rule' "credential_assignment"

# ── Case 3: clean diff → pass ────────────────────────────────────────────────
REPO3="$(setup_git_temp_repo ss-repo3)"
(
    cd "$REPO3"
    "$GIT" checkout -q -b feature
    printf 'greeting="hello world"\nexport COUNT=3\n' > app.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: app"
)
OUT3="$(run_scan "$REPO3")"
assert_json_key "C3: clean diff → verdict=pass" "$OUT3" '.verdict' "pass"
assert_json_key "C3: clean diff → 0 findings" "$OUT3" '.finding_count' "0"

# ── Case 4: empty diff (HEAD == merge-base on main) → skip ────────────────────
REPO4="$(setup_git_temp_repo ss-repo4)"
OUT4="$(run_scan "$REPO4")"
assert_json_key "C4: empty diff → verdict=skip" "$OUT4" '.verdict' "skip"

# ── Case 5: allowlisted fixture → pass ───────────────────────────────────────
# Same planted AWS key as C1, but the path is cleared by the allowlist file.
REPO5="$(setup_git_temp_repo ss-repo5)"
(
    cd "$REPO5"
    "$GIT" checkout -q -b feature
    mkdir -p tests/fixtures
    printf 'aws_access_key_id = "%s"\n' "$AWS_KEY" > tests/fixtures/fake-creds.sh
    "$GIT" add -A; "$GIT" commit -q -m "test: fixture"
)
ALLOW="$TEST_TEMP_DIR/allowlist.txt"
printf '# obvious test fixtures\ntests/fixtures/*\n' > "$ALLOW"
OUT5="$(run_scan "$REPO5" "$ALLOW")"
assert_json_key "C5: allowlisted fixture → verdict=pass" "$OUT5" '.verdict' "pass"

# ── Case 6: .env file path → fail (env_file rule) ────────────────────────────
REPO6="$(setup_git_temp_repo ss-repo6)"
(
    cd "$REPO6"
    "$GIT" checkout -q -b feature
    printf 'FOO=barvalue\n' > .env
    "$GIT" add -A; "$GIT" commit -q -m "chore: env"
)
OUT6="$(run_scan "$REPO6")"
assert_json_key "C6: .env path → verdict=fail" "$OUT6" '.verdict' "fail"
assert_json_key "C6: rule is env_file" "$OUT6" '.findings[0].rule' "env_file"

# ── Case 7: .env.example is NOT flagged (example variant excluded) → pass ─────
REPO7="$(setup_git_temp_repo ss-repo7)"
(
    cd "$REPO7"
    "$GIT" checkout -q -b feature
    printf 'FOO=changeme\n' > .env.example
    "$GIT" add -A; "$GIT" commit -q -m "docs: env example"
)
OUT7="$(run_scan "$REPO7")"
assert_json_key "C7: .env.example → verdict=pass" "$OUT7" '.verdict' "pass"

# ── Case 8: PEM private-key header matcher (direct, fragment-assembled) ───────
set +e; RULE8="$(_ss_scan_content "$PEM_HDR")"; set -e
assert_eq "C8: PEM header → private_key_header rule" "private_key_header" "$RULE8"

# ── Case 9: inline pragma allowlists a line in place → pass ──────────────────
REPO9="$(setup_git_temp_repo ss-repo9)"
(
    cd "$REPO9"
    "$GIT" checkout -q -b feature
    printf 'api_key = "%s"  # allowlist secret\n' "$CRED_VAL" > pragma.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: pragma"
)
OUT9="$(run_scan "$REPO9")"
assert_json_key "C9: inline pragma → verdict=pass" "$OUT9" '.verdict' "pass"

cleanup_test_env
print_test_results  # exits with $FAIL
