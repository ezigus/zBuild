#!/usr/bin/env bash
# tests/unit/doc-status-test.sh — a doc change is its own status, [doc], and has
# no test (#2525, ADR-069 §1 §4 §6 §7 §9).
#
# Why: on #1805 run 43093018140 design wrote "ADR-006 … amended with step 3.6"
# as [no-code]. Every requirement needs a test (#2517), and no requirement may
# say what a file contains (#2474): a doc change can meet only one of the two.
# Test-author's check called it "ok" in round 2 and "untestable" in round 3,
# and the run ended.
#
# D1 [change] `[doc]` is a status of its own
# D2 [change] the acceptance check does not run a [doc] requirement
# D3 [change] the acceptance check asks a [doc] requirement for no test;
#    [guard] a [no-code] one still needs one
# D4 [change] design's check accepts a [doc] requirement with no parts and no
#    evidence, does not read it for file contents, and refuses one with parts;
#    [guard] a [no-code] requirement about what a file contains is still refused
# D5 [change] issue-acceptance is told to judge a [doc] requirement by reading
#    the doc
# D6 [change] scripts/lib/acceptance-block.sh, which reads the statuses, is
#    under 500 lines (CLAUDE.md), and sourcing it alone still gives every
#    function it gave before the split
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"
# shellcheck source=../../plugins/agent/design/lib/checks.sh
source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"

print_test_header "a doc change is its own status, [doc], and has no test (#2525)"
setup_test_env "doc-status"
_test_cleanup_hook() { cleanup_test_env; }
unset ZBUILD_ISSUE 2>/dev/null || true

GIT="$(command -v git)"
REPO="$(setup_git_temp_repo doc-status)"
MARK="$TEST_TEMP_DIR/ran"; mkdir -p "$MARK"
(
    cd "$REPO" || exit 1
    "$GIT" checkout -q -b feature
    mkdir -p tests docs
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    printf 'The feature is described here.\n' > docs/feature.md
    cat > tests/new-test.sh <<EOF
#!/usr/bin/env bash
[[ -f "\$(dirname "\$0")/../impl.sh" ]] && echo "✓ [SPEC-1] works" || { echo "✗ [SPEC-1] works"; exit 1; }
EOF
    # A test tagged for the doc requirement, which would fail if it were run.
    cat > tests/doc-test.sh <<EOF
#!/usr/bin/env bash
: > "$MARK/doc"
echo "✗ [SPEC-2] x"; exit 1
EOF
    chmod +x tests/*.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feature"
) >/dev/null 2>&1

DM="$REPO/design.md"
cat > "$DM" <<'EOF'
```acceptance
SPEC-1[code]: the feature works
SPEC-2[doc]: the feature doc says how to turn the feature on
WIRING: none
```
EOF

print_test_section "D1: [doc] is a status of its own"
assert_eq "[D1] a [doc] requirement's status is doc" "doc" "$(acceptance_spec_status "$DM" SPEC-2)"

print_test_section "D2: the acceptance check does not run a [doc] requirement"
OUT="$(acceptance_negctl_check "$DM" "$REPO" 2>&1)"
assert_eq "[D2] a [doc] requirement → NEGCTL SKIP SPEC-2 doc" \
    "NEGCTL SKIP SPEC-2 doc" "$(grep 'SPEC-2' <<< "$OUT" || true)"
assert_eq "[D2] ...and no test of it ran" "absent" \
    "$([[ -e "$MARK/doc" ]] && echo present || echo absent)"
assert_eq "[D2] the [code] requirement is still checked" "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<< "$OUT" || true)"

print_test_section "D3: a [doc] requirement needs no test; a [no-code] one still does"
CV="$TEST_TEMP_DIR/cov"; mkdir -p "$CV/tests"; "$GIT" -C "$CV" init -q
printf 'echo "[SPEC-1] tagged"\n' > "$CV/tests/a-test.sh"
cat > "$CV/design.md" <<'EOF'
```acceptance
SPEC-1[code]: tagged
SPEC-2[doc]: the doc says how to turn it on
SPEC-3[no-code]: a refactor with no test
```
EOF
COV="$(acceptance_coverage_check "$CV/design.md" "$CV" 2>&1 || true)"
assert_eq "[D3] only the [no-code] requirement is reported as having no test" \
    "UNTAGGED SPEC-3" "$(tr '\n' ' ' <<< "$COV" | sed 's/ $//')"

print_test_section "D4: design's check reads a [doc] requirement as a doc"
ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ROOT/scripts"; : > "$ROOT/scripts/wire.sh"
export ZBUILD_REPO_ROOT="$ROOT"
_n=0
_gate() {   # <requirement lines>... — sets _V, the violations, one per line
    _n=$((_n + 1)); local d="$TEST_TEMP_DIR/d$_n.md"
    { printf '# Design\n\n```acceptance\nDSWORK-1[code]: it works\n  When: it runs\n  Then: it is done\n'
      printf '%s\n' "$@"; printf 'WIRING: scripts/wire.sh\n```\n'; } > "$d"
    _design_checks "$d" "$ROOT" "" >/dev/null 2>&1 || true
    _V="$(printf '%s\n' ${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"})"
}
_gate 'DSDOCS-1[doc]: docs/adr/ADR-006.md says a resume puts back what every finished stage wrote'
assert_eq "[D4] a [doc] requirement with no parts and no evidence is accepted" "" "$_V"
_gate 'DSDOCS-1[doc]: docs/adr/ADR-006.md contains the new resume step'
assert_eq "[D4] ...and is not read for file contents: a doc is about what a file says" "" "$_V"
_gate 'DSDOCS-1[doc]: the ADR says how a resume works' '  When: it runs' '  Then: it is done'
assert_contains "[D4] a [doc] requirement with Given/When/Then is refused: no test runs it" "$_V" "DOC_HAS_PARTS DSDOCS-1"
_gate 'DSDOCS-1[no-code]: docs/adr/ADR-006.md contains the new resume step'
assert_contains "[D4] guard: a [no-code] requirement about what a file contains is still refused" "$_V" \
    "CONTENTS_NOT_BEHAVIOUR DSDOCS-1"
assert_contains "[D4] a requirement with no status is told about [doc] too" \
    "$(_dck_plain 'NO_STATUS DSDOCS-1 (x)')" "[doc]"

print_test_section "D5: issue-acceptance judges a [doc] requirement by reading the doc"
_J="$(acceptance_requirements_for_judge "$DM")"
assert_contains "[D5] the doc requirement is listed" "$_J" "- SPEC-2: the feature doc says how to turn the feature on"
assert_contains "[D5] ...with what its status means" "$_J" \
    "Status: a doc change — no test checks it; read the doc on the branch and judge whether it says this"

print_test_section "D6: acceptance-block.sh is split under 500 lines"
for _f in "$REPO_ROOT"/scripts/lib/acceptance-block.sh "$REPO_ROOT"/scripts/lib/acceptance-run.sh "$REPO_ROOT"/scripts/lib/acceptance-testfiles.sh "$REPO_ROOT"/scripts/lib/acceptance-judge.sh; do
    _lc=$(wc -l < "$_f" 2>/dev/null || echo 9999); _lc=${_lc// /}
    assert_eq "[D6] ${_f##*/} is under 500 lines" "yes" "$([[ $_lc -lt 500 ]] && echo yes || echo "no ($_lc)")"
done
_missing="$(bash -c 'source "$1/scripts/lib/acceptance-block.sh"
    for fn in extract_acceptance_block acceptance_spec_status acceptance_list_wiring _acceptance_build_run_cmd \
        _acceptance_file_timeout _acceptance_run_cached _acceptance_run_cache_begin acceptance_list_supersedes \
        acceptance_spec_files_v acceptance_list_testfiles acceptance_spec_desc acceptance_list_testfiles_for_spec \
        design_decisions_prose acceptance_requirements_for_judge; do declare -F "$fn" >/dev/null || printf "%s " "$fn"; done' _ "$REPO_ROOT")"
assert_eq "[D6] sourcing acceptance-block.sh alone still gives every function" "" "$_missing"

print_test_results
exit $((FAIL > 0))
