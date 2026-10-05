#!/usr/bin/env bash
# tests/unit/acceptance-negctl-plugin-tests-test.sh — a change that touches only
# test files is test-only, wherever the tests live (#2300, ADR-036).
#
# Why: the negative control skips with `no_prod_delta` when no production code
# changed, because there is no old code to run the tests against. It counted a
# path as a test only when it started with `tests/`. Plugin tests live under
# `plugins/<kind>/<id>/tests/`, so #2035 (plugin tests + tests/unit) was judged
# as a code change, and every test file "passed on the old code".
#
# P1 [change] plugin tests + tests/unit only → NEGCTL SKIP no_prod_delta
# P2 [guard]  the same change plus plugins/<kind>/<id>/plugin.sh → no skip; the
#             full control runs and finds the test load-bearing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

print_test_header "acceptance negctl — plugin tests count as tests (#2300)"
setup_test_env "acceptance-negctl-plugin-tests"

GIT="$(command -v git)"

# ── P1: plugin tests + tests/unit only → skip ─────────────────────────────────
REPO_P1="$(setup_git_temp_repo negctl-plugin-tests-p1)"
(
    cd "$REPO_P1"
    "$GIT" checkout -q -b feature
    mkdir -p plugins/agent/x/tests tests/unit
    printf '#!/usr/bin/env bash\n# [SPEC-1] plugin test\nexit 0\n' > plugins/agent/x/tests/a-test.sh
    printf '#!/usr/bin/env bash\n# [SPEC-1] unit test\nexit 0\n' > tests/unit/b-test.sh
    chmod +x plugins/agent/x/tests/a-test.sh tests/unit/b-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "test: plugin + unit tests only"
)
DM_P1="$REPO_P1/design.md"
cat > "$DM_P1" <<'EOF'
```acceptance
SPEC-1: plugin tests change
TESTFILES:
plugins/agent/x/tests/a-test.sh
tests/unit/b-test.sh
```
EOF
set +e; OUT_P1="$(acceptance_negctl_check "$DM_P1" "$REPO_P1")"; RC_P1=$?; set -e
assert_eq "[SPEC-1] P1: plugin tests + tests/unit only → NEGCTL SKIP SPEC-1 no_prod_delta" \
    "NEGCTL SKIP SPEC-1 no_prod_delta" "$(grep 'SPEC-1' <<<"$OUT_P1" || true)"
assert_eq "[SPEC-1] P1: the skip is not a failure (rc=0)" "0" "$RC_P1"

# ── P2: the same plus the plugin's own code → no skip ─────────────────────────
REPO_P2="$(setup_git_temp_repo negctl-plugin-tests-p2)"
(
    cd "$REPO_P2"
    "$GIT" checkout -q -b feature
    mkdir -p plugins/agent/x/tests tests/unit
    printf '#!/usr/bin/env bash\nx_feature() { return 0; }\n' > plugins/agent/x/plugin.sh
    # Load-bearing: needs plugin.sh, which the old code does not have.
    cat > plugins/agent/x/tests/a-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] plugin code is present
impl="$(cd "$(dirname "$0")/.." && pwd)/plugin.sh"
[[ -f "$impl" ]] || exit 1
exit 0
EOF
    printf '#!/usr/bin/env bash\n# unit test\nexit 0\n' > tests/unit/b-test.sh
    chmod +x plugins/agent/x/tests/a-test.sh tests/unit/b-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: plugin code + tests"
)
DM_P2="$REPO_P2/design.md"
cat > "$DM_P2" <<'EOF'
```acceptance
SPEC-1: plugin code is present
TESTFILES:
plugins/agent/x/tests/a-test.sh
```
EOF
set +e; OUT_P2="$(acceptance_negctl_check "$DM_P2" "$REPO_P2")"; set -e
assert_eq "[SPEC-2] P2: a change to plugin.sh is production code → no no_prod_delta skip" \
    "" "$(grep 'no_prod_delta' <<<"$OUT_P2" || true)"
assert_eq "[SPEC-2] P2: the full control runs → NEGCTL PASS SPEC-1" \
    "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<<"$OUT_P2" || true)"

cleanup_test_env
print_test_results  # exits with $FAIL
