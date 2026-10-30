#!/usr/bin/env bash
# Tests: a lens's findings send the run back to the stage that can fix them
# (#2433, ADR-038, ADR-040, ADR-071 §1).
#
#   R1 [change]: the lens charter defines the four severity levels, once, and
#                asks each finding what would fix it (code, test, design, issue)
#   R1b [change]: each lens persona gives examples of each level for its lens
#   R2 [change]: with fail_on [medium, high, critical], an introduced medium
#                finding fails the lens; a low one, or a pre-existing one, does not
#   R3 [change]: the lens writes its findings that send the run back to one
#                output per topic: code and test findings to code-findings,
#                design findings to requirement-findings — never the other
#   R7 [change]: a finding that the issue itself is wrong stops the run: the
#                lens's outcome is misconfigured and it says so
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "plugin: review-lens — findings send the run back (#2433)"
setup_test_env "plugin-review-lens-loop"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
# shellcheck source=../../../../plugins/agent/review-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

_RLL_REPLY=""
# shellcheck disable=SC2329  # invoked by the sourced plugin
route_to_model() { printf '%s' "$_RLL_REPLY"; }

artifact_dir="$TEST_TEMP_DIR/artifacts"; mkdir -p "$artifact_dir"
scope_manifest="$TEST_TEMP_DIR/scope-manifest.md"; printf '+ core/\n' > "$scope_manifest"
evidence="$artifact_dir/diff.patch"; printf 'diff --git a/core/x.sh b/core/x.sh\n+ new line\n' > "$evidence"
export ZBUILD_CURRENT_STAGE=review_lenses
export _TPL_STAGE_FAIL_ON_review_lenses="medium high critical"
_f() {   # _f <severity> <introduced> <fix> <message>
    printf '{"file":"core/x.sh","line":3,"category":"logic","severity":"%s","introduced":%s,"fix":"%s","message":"%s"}' "$1" "$2" "$3" "$4"
}
_lens() {   # _lens <id> <finding-json>... — run one lens on a reply holding those findings
    local id="$1"; shift
    local IFS=,; _RLL_REPLY="{\"score\":5,\"findings\":[$*]}"
    _review_lens_run_inner "$id" "$scope_manifest" "$evidence" "$artifact_dir/lens-$id.json" "$artifact_dir" >/dev/null 2>&1
}
_out() { jq -r "$2" "$artifact_dir/lens-$1.json" 2>/dev/null; }

# ─── R1 ──────────────────────────────────────────────────────────────────────
_p="$(_rl_build_lens_prompt correctness "diff" "")"
assert_contains "R1: critical is defined" "$_p" '`critical`: the change makes the program unsafe or wrong for everyone: data loss, a security hole, or the run breaking on a normal path.'
assert_contains "R1: high is defined" "$_p" '`high`: the change is wrong on a path the issue cares about, or breaks something it should not touch.'
assert_contains "R1: medium is defined" "$_p" '`medium`: the change works, but a realistic case gets it wrong, a test does not prove what it claims, or the design leaves a gap that will cause the next bug.'
assert_contains "R1: low is defined" "$_p" '`low`: style, wording, a small inefficiency, or hardening against an unlikely case.'
assert_contains "R1: each finding says what would fix it" "$_p" '"fix": "<one of: code, test, design, issue>"'
assert_contains "R1: issue means the issue itself is wrong" "$_p" '`issue`: the issue itself is wrong'
assert_eq "R1: the prompt no longer calls the report advisory" "0" "$(grep -ci 'advisory' <<< "$_p" || true)"

# ─── R1b ─────────────────────────────────────────────────────────────────────
for _pn in security performance red-team correctness scope sre; do
    _pp="$(yaml_get "$REPO_ROOT/plugins/persona/$_pn/manifest.yaml" persona.perspective 2>/dev/null)"
    for _lv in critical high medium low; do
        assert_contains "R1b: $_pn gives an example of $_lv" "$_pp" "$_lv — e.g."
    done
done
assert_eq "R1b: scope no longer says it never blocks" "0" \
    "$(grep -ci 'never blocking\|WARN ONLY' "$REPO_ROOT/plugins/persona/scope/manifest.yaml" || true)"

# ─── R2 ──────────────────────────────────────────────────────────────────────
_lens r2a "$(_f medium true code "a realistic case is wrong")"
assert_eq "R2: an introduced medium finding fails the lens" "fail" "$(_out r2a .outcome)"
_lens r2b "$(_f low true code "a nit")"
assert_eq "R2: a low finding does not" "pass" "$(_out r2b .outcome)"
_lens r2c "$(_f high false code "was already wrong")"
assert_eq "R2: a pre-existing finding does not" "pass" "$(_out r2c .outcome)"

# ─── R3 ──────────────────────────────────────────────────────────────────────
_lens r3 "$(_f medium true code "the code misses ne")" "$(_f high true test "the test proves nothing")" \
         "$(_f medium true design "the design leaves the empty op open")" "$(_f low true design "a design nit")"
_c="$artifact_dir/lens-r3-code-result.json"; _d="$artifact_dir/lens-r3-design-result.json"
assert_file_exists "R3: a code-findings result is written" "$_c"
assert_file_exists "R3: a requirement-findings result is written" "$_d"
_ct="$(jq -r '[.data.findings[].text] | join("\n")' "$_c" 2>/dev/null)"
_dt="$(jq -r '[.data.findings[].text] | join("\n")' "$_d" 2>/dev/null)"
assert_contains "R3: a code finding goes to code-findings" "$_ct" "the code misses ne"
assert_contains "R3: a test finding goes to code-findings" "$_ct" "the test proves nothing"
assert_contains "R3: a design finding goes to requirement-findings" "$_dt" "the design leaves the empty op open"
assert_eq "R3: no design finding in code-findings" "0" "$(grep -c 'design leaves' <<< "$_ct" || true)"
assert_eq "R3: no code finding in requirement-findings" "0" "$(grep -c 'code misses\|test proves' <<< "$_dt" || true)"
assert_eq "R3: a finding that does not send the run back goes to neither" "0" "$(grep -c 'a design nit' <<< "$_ct$_dt" || true)"
assert_eq "R3: findings are numbered" "1 2" "$(jq -r '[.data.findings[].n] | map(tostring) | join(" ")' "$_c" 2>/dev/null)"
assert_contains "R3: a finding names its lens and severity" "$_ct" "r3 lens, medium"
assert_eq "R3: code-findings fails when it holds a finding" "fail" "$(jq -r .outcome "$_c" 2>/dev/null)"
_lens r3b "$(_f low true code "a nit")"
assert_eq "R3: with nothing to send back, both pass" "pass|pass" \
    "$(jq -r .outcome "$artifact_dir/lens-r3b-code-result.json" 2>/dev/null)|$(jq -r .outcome "$artifact_dir/lens-r3b-design-result.json" 2>/dev/null)"
_m="$(cat "$PLUGIN_DIR/manifest.yaml")"
assert_contains "R3: the manifest declares the code-findings result" "$_m" 'lens-${ZBUILD_REVIEW_LENS_ID}-code-result.json'
assert_contains "R3: the manifest declares the requirement-findings result" "$_m" 'lens-${ZBUILD_REVIEW_LENS_ID}-design-result.json'
_topics="$(awk '/^outputs:/{f=1;next} f&&/^[a-zA-Z_]/{f=0} f&&/^  - id:/{id=$3} f&&/^    topic:/{print id "=" $2}' "$PLUGIN_DIR/manifest.yaml" | tr '\n' ' ')"
assert_contains "R3: the design result's topic is requirement-findings" "$_topics" "review_lens_design=requirement-findings"
assert_contains "R3: the code result's topic is code-findings" "$_topics" "review_lens_code=code-findings"

# ─── R7 ──────────────────────────────────────────────────────────────────────
_lens r7 "$(_f medium true issue "R3 contradicts ADR-027")"
assert_eq "R7: the issue being wrong stops the run" "misconfigured" "$(_out r7 .outcome)"
assert_contains "R7: ...and the lens says so" "$(_out r7 .reason)" "the issue itself is wrong: R3 contradicts ADR-027"
assert_contains "R7: the finding is in the requirement-findings result" \
    "$(jq -r '[.data.findings[].text] | join("\n")' "$artifact_dir/lens-r7-design-result.json" 2>/dev/null)" "R3 contradicts ADR-027"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
