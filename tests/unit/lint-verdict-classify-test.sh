#!/usr/bin/env bash
# tests/unit/lint-verdict-classify-test.sh — the manifest↔verdict_classify guard (#1708).
#
# The defect: verdict_classify hardcodes the verdicts it understands, plugins
# independently choose the strings they write, and NOTHING checked the two agree.
# The table drifted five times (#775, #1208, #1219, #1532, #1687) and every drift
# was found the same way — a spurious unknown_verdict in a dogfood, patched after
# the fact. This lint closes the loop at build time.
#
#   SPEC-1 [change]: a manifest declaring a verdict verdict_classify does not
#                    classify → rc=1, naming BOTH the manifest and the verdict
#   SPEC-2 [change]: a manifest whose declared verdicts all classify → rc=0
#   SPEC-3 [change]: a manifest with a `primary: true` output and NO
#                    valid_verdicts key → rc=1 (an absent declaration is the
#                    defect; adoption was 1-of-25 precisely because it was optional)
#   SPEC-4 [change]: an explicit `valid_verdicts: []` is a valid declaration → rc=0
#   SPEC-5 [change]: a manifest with no `primary: true` output is not required
#                    to declare anything (gates the rule to the verdict-bearing set)
#   SPEC-6 [guard] : the shipped tree passes — every real manifest is compliant
#   SPEC-7 [guard] : a vacuous scan (no primary manifests found) FAILS rather
#                    than reporting a pass over zero files
#   SPEC-8 [change]: healthy / deployed / skipped classify pass, degraded warns
#   SPEC-9 [guard] : `*)` → unknown survives for UNDECLARED runtime values
#
# Plus wiring: a linter nothing invokes is inert (#1682 one-definition rule).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-verdict-classify — manifest verdicts are classified (#1708)"
setup_test_env "lint-verdict-classify"

CHECKER="$REPO_ROOT/scripts/lib/lint-verdict-classify.sh"

# ─── Fixture factory ─────────────────────────────────────────────────────────
# Writes a minimal manifest. $2 = "primary"|"noprimary"; remaining args are the
# valid_verdicts items, or the literal token NONE (omit the key) / EMPTY (`[]`).
_mk_manifest() {
    local dir="$1" primary="$2"; shift 2
    mkdir -p "$dir"
    {
        printf 'id: %s\n' "$(basename "$dir")"
        printf 'name: Fixture\nkind: tool\nversion: 0.1.0\n\n'
        printf 'config:\n'
        case "${1:-}" in
            NONE)  : ;;
            EMPTY) printf '  valid_verdicts: []\n' ;;
            *)     printf '  valid_verdicts:\n'
                   for v in "$@"; do printf '    - %s\n' "$v"; done ;;
        esac
        printf '  tier_default: T0\n\n'
        printf 'outputs:\n  - id: result\n    path: ${artifact_dir}/result.json\n'
        printf '    type: result.json\n    required: true\n'
        if [[ "$primary" == "primary" ]]; then printf '    primary: true\n'; fi
    } > "$dir/manifest.yaml"
}

# Sets LINT_OUT + LINT_RC and always returns 0, so `set -e` at the top of this
# file can never abort on an intentionally-failing lint run.
_run_lint() {
    LINT_OUT="$(bash "$CHECKER" "$1" 2>&1)" && LINT_RC=0 || LINT_RC=$?
    return 0
}

# ─── SPEC-1: an unclassified declared verdict fails, and says which ──────────
print_test_section "1. unclassified verdict -> rc=1, names manifest + verdict"
R1="$TEST_TEMP_DIR/r1"
_mk_manifest "$R1/good" primary pass fail
_mk_manifest "$R1/bad"  primary pass xyzzy_bogus
_run_lint "$R1"; rc1=$LINT_RC
assert_eq "[SPEC-1] lint exits 1 when a declared verdict is unclassified" "1" "$rc1"
assert_contains "[SPEC-1] the failure names the offending verdict" "$LINT_OUT" "xyzzy_bogus"
assert_contains "[SPEC-1] the failure names the offending manifest" "$LINT_OUT" "bad/manifest.yaml"

# ─── SPEC-2: all-classified passes ───────────────────────────────────────────
print_test_section "2. every declared verdict classified -> rc=0"
R2="$TEST_TEMP_DIR/r2"
_mk_manifest "$R2/a" primary pass fail skip
_mk_manifest "$R2/b" primary complete incomplete error
_run_lint "$R2"; rc2=$LINT_RC
assert_eq "[SPEC-2] lint exits 0 when all declared verdicts are classified" "0" "$rc2"

# ─── SPEC-3: a primary output with no declaration is a failure ───────────────
print_test_section "3. primary output, absent valid_verdicts -> rc=1"
R3="$TEST_TEMP_DIR/r3"
_mk_manifest "$R3/undeclared" primary NONE
_run_lint "$R3"; rc3=$LINT_RC
assert_eq "[SPEC-3] lint exits 1 when valid_verdicts is absent" "1" "$rc3"
assert_contains "[SPEC-3] the failure names the manifest" "$LINT_OUT" "undeclared/manifest.yaml"

# ─── SPEC-4: an explicit empty declaration is valid ─────────────────────────
print_test_section "4. explicit valid_verdicts: [] -> rc=0"
R4="$TEST_TEMP_DIR/r4"
_mk_manifest "$R4/writes-none" primary EMPTY
_run_lint "$R4"; rc4=$LINT_RC
assert_eq "[SPEC-4] an explicit [] is a valid declaration" "0" "$rc4"

# ─── SPEC-5: no primary output -> not subject to the rule ───────────────────
print_test_section "5. no primary output -> exempt"
R5="$TEST_TEMP_DIR/r5"
_mk_manifest "$R5/nonprimary" noprimary NONE
_mk_manifest "$R5/withprimary" primary pass
_run_lint "$R5"; rc5=$LINT_RC
assert_eq "[SPEC-5] a manifest with no primary output needs no declaration" "0" "$rc5"

# ─── SPEC-6 [guard]: the shipped tree is compliant ──────────────────────────
# Holds at the merge-base ONLY after the backfill lands; before it, adoption was
# 1-of-25. Tagged [guard] because from this commit forward it must never regress.
print_test_section "6. the shipped plugins/ tree passes"
_run_lint "$REPO_ROOT/plugins"; rc6=$LINT_RC
if [[ "$rc6" -eq 0 ]]; then
    assert_pass "[SPEC-6] every shipped manifest with a primary output is compliant"
else
    assert_fail "[SPEC-6] every shipped manifest with a primary output is compliant" "$LINT_OUT"
fi

# ─── SPEC-7: a vacuous scan fails ───────────────────────────────────────────
print_test_section "7. zero primary manifests -> rc=1, not a vacuous pass"
R7="$TEST_TEMP_DIR/r7"
_mk_manifest "$R7/only-nonprimary" noprimary NONE
_run_lint "$R7"; rc7=$LINT_RC
assert_eq "[SPEC-7] a scan finding no primary manifests fails" "1" "$rc7"

# ─── SPEC-11: a YAML flow sequence is parsed, not mis-split ─────────────────
# PR #1876 review: `valid_verdicts: [pass, fail]` is valid YAML. Passing the raw
# string through word-splitting yields "[pass," and "fail]" — both unknown — so a
# structurally CORRECT manifest would fail the lint. Parse the flow form instead.
print_test_section "11. YAML flow-sequence declarations"
_mk_flow() {
    mkdir -p "$1"
    printf 'id: %s\nkind: tool\n\nconfig:\n  valid_verdicts: %s\n\noutputs:\n  - id: r\n    path: ${artifact_dir}/r.json\n    primary: true\n' \
        "$(basename "$1")" "$2" > "$1/manifest.yaml"
}
R11="$TEST_TEMP_DIR/r11"; _mk_flow "$R11/p" '[pass, fail]'
_run_lint "$R11"; assert_eq "[SPEC-11] flow sequence [pass, fail] is accepted" "0" "$LINT_RC"
R11b="$TEST_TEMP_DIR/r11b"; _mk_flow "$R11b/p" '["pass", "skip"]'
_run_lint "$R11b"; assert_eq "[SPEC-11] quoted flow sequence is accepted" "0" "$LINT_RC"
R11c="$TEST_TEMP_DIR/r11c"; _mk_flow "$R11c/p" '[ ]'
_run_lint "$R11c"; assert_eq "[SPEC-11] '[ ]' is the empty declaration, not a verdict" "0" "$LINT_RC"
R11d="$TEST_TEMP_DIR/r11d"; _mk_flow "$R11d/p" '[pass, nonsense_verdict]'
_run_lint "$R11d"; assert_eq "[SPEC-11] a bad verdict inside a flow sequence still fails" "1" "$LINT_RC"
assert_contains "[SPEC-11] and it names the offending token, not the raw list" \
    "$LINT_OUT" "'nonsense_verdict'"

# ─── SPEC-12: a verdict token is never glob-expanded ────────────────────────
# PR #1876 review: the declared set was expanded unquoted, so a token containing
# * ? or [ would be pathname-expanded against the CWD before classification.
print_test_section "12. verdict tokens are not globbed against the filesystem"
R12="$TEST_TEMP_DIR/r12"
_mk_manifest "$R12/starry" primary 'pass*'
# Decoys a leaked glob would expand onto. The lint MUST run with the decoy dir as
# CWD — pathname expansion resolves against the process's working directory, so
# running from anywhere else would let the assertion pass with the bug present.
( cd "$TEST_TEMP_DIR" && touch pass_decoy_1 pass_decoy_2 )
LINT_OUT="$(cd "$TEST_TEMP_DIR" && bash "$CHECKER" "$R12" 2>&1)" || true
assert_contains "[SPEC-12] the literal token is reported, not a glob expansion" \
    "$LINT_OUT" "'pass*'"
if grep -q "pass_decoy" <<<"$LINT_OUT"; then
    assert_fail "[SPEC-12] the token must not expand against the filesystem" \
        "glob leaked: $LINT_OUT"
else
    assert_pass "[SPEC-12] the token must not expand against the filesystem"
fi

# ─── SPEC-8 / SPEC-9: the classifications this issue adds, and the backstop ──
print_test_section "8. new classifications + the runtime backstop"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
for pair in "healthy:pass" "deployed:pass" "skipped:pass" "degraded:warn"; do
    raw="${pair%%:*}"; want="${pair##*:}"
    assert_eq "[SPEC-8] verdict_classify($raw) -> $want" "$want" "$(verdict_classify "$raw")"
done
# SPEC-9: the *) arm must survive — it is the runtime backstop for values no
# manifest declares (a corrupt artifact, a target-repo string). Removing it would
# make this lint the ONLY defence, and a runtime value has no manifest to lint.
assert_eq "[SPEC-9] an undeclared runtime value still classifies unknown" \
    "unknown" "$(verdict_classify "totally_unexpected_value")"
assert_eq "[SPEC-9] skip and skipped remain DISTINCT strings, both pass" \
    "pass:pass" "$(verdict_classify skip):$(verdict_classify skipped)"

# ─── SPEC-10: ADR-019's table is checked, not hand-maintained ───────────────
# The DoD asks for the ADR table to be "regenerated or checked against the
# manifests rather than hand-maintained". The lint pins manifests↔verdict_classify;
# this pins verdict_classify↔the ADR, so a verdict cannot be added to the engine
# and the manifests while the documented table silently goes stale — which is how
# the table came to be wrong five times.
print_test_section "10. ADR-019's verdict table covers every declared verdict"
ADR019="$REPO_ROOT/docs/adr/ADR-019-review-fail-closed-on-test-failure.md"
adr_body="$(cat "$ADR019")"
missing_from_adr=""
while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    # route_* is documented as a wildcard family, not one row per target.
    case "$v" in route_*) continue ;; esac
    grep -qF -- "\`$v\`" <<<"$adr_body" || missing_from_adr+="$v "
done < <(
    find "$REPO_ROOT/plugins" -name manifest.yaml -type f -print0 \
      | xargs -0 awk '
          /^config:[[:space:]]*$/ { c=1; next }
          c && /^[a-zA-Z_]/ { c=0 }
          c && /^[[:space:]]*valid_verdicts:/ { l=1; next }
          c && l && /^[[:space:]]*#/ { next }
          c && l && /^[[:space:]]+-[[:space:]]*[^[:space:]]/ {
              v=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",v); sub(/[[:space:]]*#.*$/,"",v)
              print v; next
          }
          c && l && /^[[:space:]]+[^-[:space:]]/ { l=0 }
      ' | sort -u
)
if [[ -z "$missing_from_adr" ]]; then
    assert_pass "[SPEC-10] every manifest-declared verdict appears in ADR-019's table"
else
    assert_fail "[SPEC-10] every manifest-declared verdict appears in ADR-019's table" \
        "absent from ADR-019: $missing_from_adr"
fi

# ─── Wiring: the lint is reachable from both entrypoints (#1682) ────────────
print_test_section "9. wiring — npm run lint and the CI Lint job"
assert_contains "[wiring] package.json lint chain invokes the checker" \
    "$(cat "$REPO_ROOT/package.json")" "lint-verdict-classify.sh"
assert_contains "[wiring] CI Lint job invokes the checker" \
    "$(cat "$REPO_ROOT/.github/workflows/test.yml")" "lint-verdict-classify.sh"

cleanup_test_env
print_test_results
