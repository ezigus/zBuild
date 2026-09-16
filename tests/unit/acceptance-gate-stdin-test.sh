#!/usr/bin/env bash
# tests/unit/acceptance-gate-stdin-test.sh — #2108
# A test file that reads stdin must not eat the gate's SPEC-id stream: every
# SPEC gets a verdict, and reachability still sees the flip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"
# shellcheck source=../../scripts/lib/acceptance-reachability.sh
source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh"

print_test_header "acceptance gate — a stdin-reading TESTFILE does not truncate the SPEC roster (#2108)"
setup_test_env "acceptance-gate-stdin"
GIT="$(command -v git)"

REPO="$(setup_git_temp_repo gate-stdin)"   # main @ seed (baseline)
(
    cd "$REPO"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nfeature_a() { return 0; }\n' > impl.sh
    # The FIRST thing the file does is drain stdin — exactly what a plugin test
    # that pipes a prompt into a mocked model does.
    cat > tests/drain-test.sh <<'EOS'
#!/usr/bin/env bash
cat >/dev/null
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
FAIL=0
ok() { printf '  ✓ %s\n' "$1"; }; bad() { printf '  ✗ %s\n' "$1"; FAIL=1; }
if [[ -f "$impl" ]]; then source "$impl"; fi
for n in 1 2 3 4; do
    if declare -F feature_a >/dev/null; then ok "[SPEC-$n] feature_a exists"; else bad "[SPEC-$n] feature_a exists"; fi
done
exit "$FAIL"
EOS
    chmod +x tests/drain-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl + stdin-draining test"
)
DM="$REPO/design.md"
cat > "$DM" <<'EOF2'
```scope
impl.sh
```
```acceptance
SPEC-1[change]: feature_a exists (1)
SPEC-2[change]: feature_a exists (2)
SPEC-3[change]: feature_a exists (3)
SPEC-4[change]: feature_a exists (4)
WIRING: impl.sh
TESTFILES:
SPEC-1: tests/drain-test.sh
SPEC-2: tests/drain-test.sh
SPEC-3: tests/drain-test.sh
SPEC-4: tests/drain-test.sh
```
EOF2

# Bounded: before #2108 a stdin-draining TESTFILE run outside a read loop
# blocks on the engine's own stdin (a TTY locally) — a hang, not a verdict.
_TOUT=""; command -v gtimeout >/dev/null 2>&1 && _TOUT=gtimeout; [[ -z "$_TOUT" ]] && command -v timeout >/dev/null 2>&1 && _TOUT=timeout
_bounded() { if [[ -n "$_TOUT" ]]; then "$_TOUT" 60 bash -c "$1"; else bash -c "$1"; fi; }
export DM REPO REPO_ROOT
set +e; OUT="$(_bounded 'source "$REPO_ROOT/scripts/lib/helpers.sh"; source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"; acceptance_negctl_check "$DM" "$REPO"')"; RC=$?; set -e
assert_eq "[#2108] negctl completes (no hang on the caller stdin)" "not-124" "$([[ $RC -eq 124 ]] && echo 124 || echo not-124)"
n_verdicts="$(grep -c '^NEGCTL \(PASS\|FAIL\|ERROR\) ' <<<"$OUT" || true)"
assert_eq "[#2108] every SPEC gets a verdict when the TESTFILE drains stdin" "4" "$n_verdicts"
for n in 1 2 3 4; do
    assert_eq "[#2108] SPEC-$n is a valid control" "NEGCTL PASS SPEC-$n" "$(grep "SPEC-$n\$" <<<"$OUT" || true)"
done
assert_eq "[#2108] negctl rc=0" "0" "$RC"

set +e; ROUT="$(_bounded 'source "$REPO_ROOT/scripts/lib/helpers.sh"; source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh"; acceptance_reachability_check "$DM" "$REPO"')"; RRC=$?; set -e
assert_eq "[#2108] reachability completes (no hang on the caller stdin)" "not-124" "$([[ $RRC -eq 124 ]] && echo 124 || echo not-124)"
assert_eq "[#2108] reachability judges the WIRING target with a stdin-draining TESTFILE" \
    "REACHABILITY PASS impl.sh" "$ROUT"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
