#!/usr/bin/env bash
# Integration: zbuild deferred / manifest CLI passthrough (#589).
#
# zbuild dispatches to the underlying scanner scripts; --help passes
# through so the script's own help is the canonical surface.
# Z5/Z7/Z9b lock the script-level help quality (no internal-comment leaks).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild deferred/manifest CLI e2e (#589)"
setup_test_env "zbuild-cli-scanners-e2e"

ZBUILD="$REPO_ROOT/scripts/zbuild"

export RUNNER_TEMP="$TEST_TEMP_DIR"
export LLM_TIEBREAKER_ENABLED=0   # deterministic; no claude CLI needed

# Mock gh: empty arrays for all list calls; repo view returns sane string.
mock_binary "gh" '
case "${1:-} ${2:-}" in
    "repo view") echo "ezigus/zBuild" ;;
    "pr list") echo "[]" ;;
    "issue list") echo "[]" ;;
    "issue view") echo "{}" ;;
    "issue create"|"issue close"|"issue edit"|"issue comment") true ;;
    "auth status") echo "Logged in" ;;
    "api"*) echo "[]" ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 0 ;;
esac
'

# Section heading list used by Z4/Z5/Z9 to assert structured help
SECTIONS_PATTERN='^(What it does|When to use it|Invocation styles|Modes|Flags|Examples|See also):'

# ─── Z1: top-level --help lists the new groups ─────────────────────────────
out="$("$ZBUILD" --help 2>&1)"; rc=$?
assert_eq "Z1: zbuild --help exits 0" "0" "$rc"
assert_contains "Z1: lists deferred" "$out" "deferred"
assert_contains "Z1: lists manifest" "$out" "manifest"

# ─── Z2: `zbuild deferred` no-sub prints group help ────────────────────────
out="$("$ZBUILD" deferred 2>&1)"; rc=$?
assert_eq "Z2: zbuild deferred no-sub exits 0" "0" "$rc"
assert_contains "Z2: lists backfill" "$out" "backfill"
assert_contains "Z2: lists tracker" "$out" "tracker"

# ─── Z3: `zbuild deferred --help` mirrors Z2 ───────────────────────────────
out="$("$ZBUILD" deferred --help 2>&1)"; rc=$?
assert_eq "Z3: zbuild deferred --help exits 0" "0" "$rc"
assert_contains "Z3: lists backfill" "$out" "backfill"
assert_contains "Z3: lists tracker" "$out" "tracker"

# ─── Z4: passthrough — `zbuild deferred backfill --help` shows 7 sections ──
out="$("$ZBUILD" deferred backfill --help 2>&1)"; rc=$?
assert_eq "Z4: backfill --help passthrough exits 0" "0" "$rc"
n="$(grep -cE "$SECTIONS_PATTERN")" <<< "$out"
if (( n >= 6 )); then
    assert_pass "Z4: passthrough shows $n structured sections"
else
    assert_fail "Z4: only $n sections found (expected >= 6)"
fi

# ─── Z5 REGRESSION LOCK: direct script help has same structure (canonical) ─
out="$(bash "$REPO_ROOT/scripts/deferred-backfill.sh" --help 2>&1)"; rc=$?
assert_eq "Z5: direct backfill --help exits 0" "0" "$rc"
n="$(grep -cE "$SECTIONS_PATTERN")" <<< "$out"
if (( n >= 6 )); then
    assert_pass "Z5 REGRESSION LOCK: script-level help has $n sections"
else
    assert_fail "Z5 LOCK: only $n sections found"
fi

# ─── Z6: `zbuild deferred tracker --help` includes state-machine summary ───
out="$("$ZBUILD" deferred tracker --help 2>&1)"; rc=$?
assert_eq "Z6: tracker --help exits 0" "0" "$rc"
assert_contains "Z6: What it does present" "$out" "What it does"
assert_contains "Z6: state machine — 0 open" "$out" "0 open"
assert_contains "Z6: state machine — comments/boxes" "$out" "comments/boxes"

# ─── Z7 REGRESSION LOCK: tracker direct help no longer leaks internals ─────
out="$(bash "$REPO_ROOT/scripts/deferred-tracker.sh" --help 2>&1)"
if grep -qE "ReDoS|shellcheck source=" <<< "$out"; then
    assert_fail "Z7 LOCK: deferred-tracker --help still leaks internal comments"
else
    assert_pass "Z7 REGRESSION LOCK: no internal comments in deferred-tracker --help"
fi

# ─── Z8: `zbuild manifest --help` lists sub-commands ───────────────────────
out="$("$ZBUILD" manifest --help 2>&1)"; rc=$?
assert_eq "Z8: manifest --help exits 0" "0" "$rc"
assert_contains "Z8: lists sync" "$out" "sync"
assert_contains "Z8: mentions drift" "$out" "drift"

# ─── Z9: `zbuild manifest sync --help` shows structured sections ───────────
out="$("$ZBUILD" manifest sync --help 2>&1)"; rc=$?
assert_eq "Z9: manifest sync --help exits 0" "0" "$rc"
n="$(grep -cE "$SECTIONS_PATTERN")" <<< "$out"
if (( n >= 6 )); then
    assert_pass "Z9: sync passthrough shows $n sections"
else
    assert_fail "Z9: only $n sections found"
fi

# ─── Z9b REGRESSION LOCK: direct manifest-sync help is structured ──────────
out="$(bash "$REPO_ROOT/scripts/manifest-sync.sh" --help 2>&1)"
assert_contains "Z9b LOCK: manifest-sync has 'What it does' section" "$out" "What it does"
if grep -qE "ReDoS|shellcheck source=" <<< "$out"; then
    assert_fail "Z9b LOCK: manifest-sync --help leaks internals"
else
    assert_pass "Z9b REGRESSION LOCK: no internal-comment leak in manifest-sync --help"
fi

# ─── Z10: unknown deferred subcommand → exit 2 + helpful stderr ────────────
# `set -e` would abort on the expected non-zero exit; capture rc via || pattern.
rc=0
err="$("$ZBUILD" deferred bogus 2>&1 1>/dev/null)" || rc=$?
assert_eq "Z10: unknown deferred subcommand exits 2" "2" "$rc"
assert_contains "Z10: stderr names the bad command" "$err" "Unknown deferred subcommand"
assert_contains "Z10: stderr points at --help" "$err" "zbuild deferred --help"

# ─── Z11: unknown manifest subcommand → exit 2 + stderr ────────────────────
rc=0
err="$("$ZBUILD" manifest bogus 2>&1 1>/dev/null)" || rc=$?
assert_eq "Z11: unknown manifest subcommand exits 2" "2" "$rc"
assert_contains "Z11: stderr names the bad command" "$err" "Unknown manifest subcommand"
assert_contains "Z11: stderr points at --help" "$err" "zbuild manifest --help"

# ─── Z12: `zbuild deferred backfill --report` works with mocked gh ─────────
PRESENTED="$TEST_TEMP_DIR/presented.md"
out="$("$ZBUILD" deferred backfill --report --presented-log "$PRESENTED" 2>&1)"; rc=$?
assert_eq "Z12: backfill --report exits 0 (mocked empty gh)" "0" "$rc"
assert_contains "Z12: 'no candidates' surfaced" "$out" "no candidates"

# ─── Z13: `zbuild deferred tracker --report` works with mocked gh ──────────
LOG="$TEST_TEMP_DIR/scanned.md"
cat > "$LOG" <<EOF
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF
out="$("$ZBUILD" deferred tracker --report --log "$LOG" 2>&1)"; rc=$?
assert_eq "Z13: tracker --report exits 0" "0" "$rc"
assert_contains "Z13: 'no candidates' surfaced" "$out" "no candidates"

# ─── Z14: `zbuild manifest sync --report` with minimal fixture ─────────────
MANIFEST="$TEST_TEMP_DIR/manifest.yaml"
cat > "$MANIFEST" <<EOF
labels: []
milestones: []
issues:
  - id: trivial
    title: "trivial entry that doesn't match anything live"
    milestone: ""
    labels: []
    state: open
    body: ""
EOF
rc=0
"$ZBUILD" manifest sync --report --manifest "$MANIFEST" >/dev/null 2>&1 || rc=$?
# Report mode is exit 0 whether or not drift was found.
assert_eq "Z14: manifest sync --report exits 0" "0" "$rc"

# ─── Z15 REGRESSION: existing `zbuild plugin list` still works ─────────────
rc=0
"$ZBUILD" plugin list >/dev/null 2>&1 || rc=$?
assert_eq "Z15 REGRESSION: plugin list still works" "0" "$rc"

# ─── Z16 REGRESSION: `zbuild --version` still works ────────────────────────
out="$("$ZBUILD" --version 2>&1)"; rc=$?
assert_eq "Z16 REGRESSION: --version exits 0" "0" "$rc"
if grep -qE "zbuild [0-9]+\.[0-9]+\.[0-9]+" <<< "$out"; then
    assert_pass "Z16: version format matches zbuild X.Y.Z"
else
    assert_fail "Z16: unexpected version format: $out"
fi

print_test_results
