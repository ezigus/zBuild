#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/review — review stage plugin (ADR-013, issue #343)         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Examines diff + plan + test results and produces review.json with a verdict:
#   approve         — diff implements plan; tests pass; safe to open PR
#   request_changes — fixable issues found; not blocking
#   block           — critical issues; must not proceed to PR
#
# Manifest: plugins/agent/review/manifest.yaml
# ADR refs: ADR-001 (plugin contract), ADR-003 (tier), ADR-004 (redaction),
#           ADR-013 (stage list, review = T2 agent)

[[ -n "${_ZBUILD_REVIEW_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_REVIEW_DIR="$_ZBUILD_PLUGIN_DIR"
_REVIEW_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_REVIEW_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_REVIEW_ROOT/core/router/route.sh"
# ADR-028: shared LLM-agent stage framework (PR 3/5 — review migration).
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_REVIEW_ROOT/scripts/lib/llm-agent.sh"
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_REVIEW_ROOT/scripts/lib/artifact-render.sh"
# #506: shared numstat banner formatter (operator-banner override input).
# shellcheck source=../../../scripts/lib/numstat-format.sh
source "$_REVIEW_ROOT/scripts/lib/numstat-format.sh"
# Wave 16-B (#699): sanitize text blocks before splicing into the LLM prompt,
# and prepend a structure-first diff-stat summary so the model orients on
# what-changed before being asked to read full hunks.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_REVIEW_ROOT/scripts/lib/test-output-sanitize.sh"
# shellcheck source=../../../scripts/lib/diff-stat.sh
source "$_REVIEW_ROOT/scripts/lib/diff-stat.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_REVIEW_ROOT/scripts/lib/prompt-overrides.sh"
# 843-H (#923): acceptance-block + coverage helpers for the mechanical
# acceptance-coverage gate (downgrade approve when a design SPEC's tagged test
# is not touched in the diff under review).
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_REVIEW_ROOT/scripts/lib/acceptance-block.sh"
# #896/#952: shared merge-base resolver so review, review-lens and review-report
# judge the SAME full-branch change basis (dedupes the former local twin).
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_REVIEW_ROOT/scripts/lib/merge-base.sh"

# Valid verdict values per manifest config.valid_verdicts
_REVIEW_VALID_VERDICTS="approve request_changes block"

# ─── _review_derive_test_status ──────────────────────────────────────────────
# #485: Map the test plugin's test-results.json into one of three
# review-side states:
#   passed   — tests ran and verdict=pass
#   failed   — tests ran and verdict in {fail, error}
#   unknown  — test-results.json missing or has no usable .verdict
#
# Test plugin (plugins/tool/test) writes `.verdict` (pass|fail|error). Review
# does NOT read `.status`; that field has never been written by the producer.
# Fail-closed: anything we cannot positively interpret as `pass` is treated as
# at-least-`unknown`; verdict=error specifically maps to `failed` so a
# misconfigured run cannot smuggle approve through.
#
# #569 / ADR-019 §7 amendment (#572): when test-assessment.json is also present
# in the artifact dir, PREFER its .verdict over test-results.json. The
# test_assessment LLM stage (#567) interprets test output and is the
# authoritative signal. Mapping:
#   assessment.verdict=pass         → "passed"
#   assessment.verdict=fail|error   → "failed"
#   assessment.verdict=inconclusive → "unknown"
#   assessment absent/malformed/unknown verdict → fall through to test-results
# Fail-closed is preserved: a malformed assessment never coerces approve
# (jq returns empty → fall through, where the test-results check still applies).
#
# Usage: _review_derive_test_status <test_results_json_path>
# Prints: passed | failed | unknown
_review_derive_test_status() {
    local path="$1"

    # #569: precedence — check test-assessment.json first. Resolve from the
    # artifact dir (dirname of test-results path); honor ZBUILD_ARTIFACT_DIR
    # as a fallback when the test-results path is absent or unusable.
    local _art_dir=""
    if [[ -n "$path" ]]; then
        _art_dir="$(dirname "$path")"
    fi
    if [[ -z "$_art_dir" || ! -d "$_art_dir" ]]; then
        _art_dir="${ZBUILD_ARTIFACT_DIR:-}"
    fi
    if [[ -n "$_art_dir" ]]; then
        local _assessment="$_art_dir/test-assessment.json"
        if [[ -s "$_assessment" ]]; then
            local _av
            _av="$(jq -r '.verdict // empty' "$_assessment" 2>/dev/null || true)"
            case "$_av" in
                pass|fail|error|inconclusive)
                    # ADR-019 §7 mandates this telemetry so operators can tell
                    # whether a coerced review came from test_assessment or raw
                    # test-results.json. (Codex P2 on #580.)
                    emit_event "review.test_assessment.consumed" \
                        "source=test_assessment" \
                        "verdict=$_av" \
                        "path=$_assessment" 2>/dev/null || true
                    ;;
            esac
            case "$_av" in
                pass)       printf 'passed\n';  return 0 ;;
                fail|error) printf 'failed\n';  return 0 ;;
                inconclusive)
                    # ADR-019 §7 amendment: inconclusive means the LLM could not
                    # judge convergence semantics, not that tests failed. Fall
                    # through to test-results.json; only a pass there lets approve
                    # stand. Fail-closed is preserved: fail/error → "failed" and
                    # missing/malformed → "unknown", both of which still coerce.
                    ;;
                *) ;;  # fall through to test-results.json
            esac
        fi
    fi

    if [[ -z "$path" || ! -f "$path" ]]; then
        printf 'unknown\n'
        return 0
    fi
    local v jq_err
    # #527 silent-failure CRIT #5: jq parse errors must not be silently swallowed;
    # emit a discoverable event so a malformed test-results.json is visible in the
    # post-mortem event log. Behavior on parse error is preserved (v="" → unknown,
    # which the ADR-019 fail-closed gate coerces approve → request_changes).
    jq_err="$(mktemp 2>/dev/null || printf '/tmp/zb-review-jq.%s' "$$")"
    if v="$(jq -r '.verdict // empty' "$path" 2>"$jq_err")"; then
        :
    else
        local err_msg
        err_msg="$(tr -d '\n' < "$jq_err" 2>/dev/null | head -c 200)"
        emit_event "review.jq.parse_error" \
            "plugin=review" \
            "stage=review" \
            "path=$path" \
            "error=${err_msg:-jq_failed}" 2>/dev/null || true
        v=""
    fi
    rm -f "$jq_err" 2>/dev/null || true
    case "$v" in
        pass)        printf 'passed\n' ;;
        fail|error)  printf 'failed\n' ;;
        *)           printf 'unknown\n' ;;
    esac
    return 0
}

# ─── init ───────────────────────────────────────────────────────────────────
review_init() {
    export ZBUILD_PLUGIN="review"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=review"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: review_run(stage, state_file)
# Derives artifact paths from state_dir and delegates to the inner function.
review_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "review_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    _review_run_inner \
        "$state_dir/scope-manifest.md" \
        "$artifact_dir/plan.json" \
        "$artifact_dir/diff.patch" \
        "$artifact_dir/test-results.json" \
        "$artifact_dir/review.json" \
        "$artifact_dir" \
        "$state_dir/intake.md"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan.json path
#   $3 = diff.patch path
#   $4 = test-results.json path
#   $5 = output review.json path
#   $6 = artifact_dir (for intermediate files)
#   $7 = intake.md path (Wave 19-G, #739 — optional; issue body for DoD verify)

# ─── _review_envelope_schema_ok (#944, ADR-028 v1.2) ─────────────────────────
# Gate function for _llm_envelope_parse --schema-gate. Validates that $1 is a
# structurally correct review envelope. Used by recovery to select the right
# object when LAST-wins picks a brace-bearing postamble instead.
_review_envelope_schema_ok() {
    printf '%s' "${1:-}" | jq -e '
        type == "object"
        and (.schema_version == 1)
        and (.verdict | IN("approve","request_changes","block"))
        and (.confidence | type == "number")
        and (.issues | type == "array")
    ' >/dev/null 2>&1
}

_review_run_inner() {
    local scope_manifest="$1"
    local plan_json_path="$2"
    local diff_patch_path="$3"
    local test_results_json_path="$4"
    local output_review_json="$5"
    local artifact_dir="${6:-$(dirname "$output_review_json")}"
    local intake_md_path="${7:-}"

    if [[ -z "$output_review_json" ]]; then
        error "_review_run_inner: output path required"
        return 2
    fi

    mkdir -p "$artifact_dir"

    # ─── Read input files (missing files handled gracefully) ─────────────────
    local plan_content diff_content test_content
    if [[ -f "$plan_json_path" ]]; then
        plan_content="$(cat "$plan_json_path")"
    else
        warn "review_run: plan.json not found at $plan_json_path; using empty"
        plan_content="{}"
    fi

    # #896: review must judge the CUMULATIVE branch-vs-default-branch diff, not
    # the per-run diff.patch (git diff intake-baseline..HEAD), which is EMPTY on
    # a resumed/green run where build no-ops, or when the implementation was
    # committed before intake. Resolve the merge-base with the default branch
    # (the same basis the operator banner uses) and diff against it. The raw diff
    # is SAFE here: it is spliced into the prompt BEFORE the apply_scope_redaction
    # chokepoint below, so out-of-scope file PATHS are still wrapped
    # <out-of-scope-context> exactly as the diff.patch path was. Fallback chain
    # (never crashes): merge-base diff → diff.patch artifact → sentinel.
    local _mb_base _mb_diff=""
    _mb_base="$(zbuild_resolve_merge_base)"
    if [[ -n "$_mb_base" ]]; then
        _mb_diff="$(git diff "$_mb_base" HEAD 2>/dev/null || true)"
    fi
    if [[ -n "$_mb_diff" ]]; then
        diff_content="$_mb_diff"
    elif [[ -f "$diff_patch_path" ]]; then
        diff_content="$(cat "$diff_patch_path")"
    else
        warn "review_run: no merge-base diff and diff.patch not found at $diff_patch_path; using empty"
        diff_content="(no diff available)"
    fi

    if [[ -f "$test_results_json_path" ]]; then
        test_content="$(cat "$test_results_json_path")"
    else
        warn "review_run: test-results.json not found; treating as test failure"
        test_content='{"status":"unknown","passed":0,"failed":0,"note":"test results missing -- treated as failure"}'
        # #527 silent-failure CRIT #4: ALWAYS emit a discoverable event when
        # test-results.json is missing so operators can spot it in event-log
        # post-mortems regardless of which verdict path runs downstream. The
        # ADR-019 fail-closed coercion still fires below; this event is purely
        # for observability (no behavior change).
        emit_event "review.test_status.missing" \
            "plugin=review" \
            "stage=review" \
            "path=$test_results_json_path" \
            "reason=file_absent"
    fi

    # ─── Build prompt ────────────────────────────────────────────────────────
    # ADR-018 (#469): Pattern 1 — one-shot with tools. Read is available for
    # diff verification; Edit/Write/Bash are forbidden. Final-output contract
    # remains a SINGLE JSON object with no fences and no prose.
    # ADR-028: canonical OUTPUT CONTRACT block from framework. Review's verdict
    # vocab is approve|request_changes|block.
    local _review_schema
    _review_schema="$(cat <<'REVIEW_SCHEMA'
  {
    "schema_version": 1,
    "verdict": "approve" | "request_changes" | "block",
    "confidence": <float 0.0-1.0>,
    "issues": ["<string>", ...],
    "summary": "<string>"
  }
REVIEW_SCHEMA
)"
    local _output_contract_block
    _output_contract_block="$(_llm_output_contract \
        --stage review \
        --verdicts "approve,request_changes,block" \
        --schema-json "$_review_schema" \
        --markdown-fields "summary")"

    local _review_instructions
    _review_instructions="$(cat <<'REVIEW_PROMPT'
You are a code review agent. Examine the diff to determine whether it correctly
implements the plan.

Tool-use policy:
You MAY use the Read tool to inspect files referenced by the diff to verify
the change implements the plan. Do NOT call Edit, Write, or Bash. Limit reads
to paths in the diff or in the scope manifest.

Scope redaction:
Files outside the declared scope appear in the diff as `<out-of-scope-context>`
markers — do NOT attempt to Read those paths.

Rules:
- `schema_version` MUST be present and set to the integer 1 (#944: the
  recovery gate requires it to disambiguate the envelope from any postamble).
- `verdict` MUST be exactly one of: approve, request_changes, block.
- `issues` is an array of strings; empty array [] if no issues found.
- `confidence` is a float between 0.0 and 1.0.
- An approve verdict requires that test results show tests passed; if test results are missing, unknown, or failed, return request_changes (not approve).

Verdict definitions:
  approve         — diff implements the plan; tests pass; safe to open PR
  request_changes — fixable issues found; not blocking but need attention
  block           — critical issues; must not proceed to PR

## Wave 19-G verification discipline (#739)

You may see THREE source-of-truth artifacts that can disagree:
- The Issue body (if present) is AUTHORITATIVE. It states what "done" means.
- The Plan is the plan agent's interpretation of the issue.
- The Diff is the build agent's implementation of the plan.

When the issue body is present, evaluate the DIFF against the ISSUE'S
Definition of done (not just against the plan):

- approve: the DIFF satisfies the ISSUE'S Definition of done AND tests pass.
- request_changes: the diff matches the plan but the plan failed to capture
  the issue's intent (a plan-issue gap). Cite the specific DoD checkbox the
  diff doesn't satisfy in your issues[] array. The build agent will iterate
  on this feedback.
- block: structural defect that no build iteration can fix.

If the issue body contains a "Definition of done" or "5-test trial" section,
you MUST evaluate each checkbox against the actual diff and call out unmet
items in issues[].

If the issue body contains an "Anti-patterns the plan agent MUST refuse"
section, you MUST check the plan AND the diff against each anti-pattern.
Matching any anti-pattern is grounds for request_changes regardless of
plan-conformance.

## Assertion integrity (#840 / ADR-030)

Governed scope expansion lets the build agent edit TEST files it was not
originally scoped for (to fix collateral that pins values the change
invalidates). This opens one hazard: a build could make a red test pass by
WEAKENING it rather than fixing the code. You MUST guard against this.

When the diff modifies test files, scrutinize every changed assertion:
- An assertion may be UPDATED to a new correct expected value (e.g. a stage
  count "8" → "12" because the change genuinely added stages). That is fine.
- An assertion MUST NOT be DELETED, commented out, loosened (tightened →
  loose comparison, exact → "contains", removing edge cases), or have its
  expected value changed to something that no longer reflects real intent
  JUST to make a failing test pass. That is gaming the gate.
- A whole test or test case removed to silence a failure is a `block`-level
  defect unless the issue explicitly retired that behavior.

If you find a weakened/deleted assertion that exists only to pass, set
`request_changes` (or `block` for outright deletion of behavior coverage)
and cite the specific assertion in issues[]. An approve is NOT permitted
while a test was weakened to go green.

REVIEW_PROMPT
)"
    _review_instructions="$_output_contract_block

$_review_instructions"
    # ADR-018: render plan and diff as markdown for LLM consumption. Test
    # results stay as raw fenced text — no test-results renderer (see #470).
    local plan_md diff_md
    plan_md="$(render_artifact plan "$plan_content")"
    diff_md="$(render_artifact diff "$diff_content")"

    # Wave 16-B (#699): sanitize every text block that flows into the LLM
    # prompt — strip framework decoration (redaction-tag wrappers, banner
    # pairs, decorative separators, ANSI codes, truncation footers) that
    # might be present in upstream artifacts. Per #681 dogfood the model
    # ignores ~200 lines of decoration over ~5 lines of signal otherwise.
    local plan_md_clean diff_md_clean
    plan_md_clean="$(printf '%s' "$plan_md" | _zbuild_sanitize_for_llm)"
    diff_md_clean="$(printf '%s' "$diff_md" | _zbuild_sanitize_for_llm)"

    # Build a structured test-results summary from the raw JSON. The previous
    # implementation spliced the whole JSON envelope, which (a) buries the
    # signal (verdict + counts + .test_output) inside JSON syntax the model
    # has to parse and (b) hides framework decoration from the sanitizer
    # because newlines inside .test_output are JSON-escaped, so line-wise
    # transforms can't fire. Extract the fields we actually want the model
    # to see, sanitize the free-text .test_output independently, and splice
    # the result back as bare text.
    local _test_verdict _test_passed _test_failed _test_exit _test_output
    # Single jq pass extracts scalar fields (one per line) so we don't
    # reparse $test_content (which can be large via .test_output) once per
    # field. Scalars are constrained to single-line strings/numbers, so
    # line-delimited output is safe. .test_output is read separately
    # because its multi-line content would break the line split.
    local _scalars
    _scalars="$(printf '%s' "$test_content" | jq -r '
        (.verdict // .status // "unknown"),
        (.passed // 0 | tostring),
        (.failed // 0 | tostring),
        (.exit_code // "" | tostring)
    ' 2>/dev/null || printf 'unknown\n0\n0\n\n')"
    { IFS= read -r _test_verdict
      IFS= read -r _test_passed
      IFS= read -r _test_failed
      IFS= read -r _test_exit
    } <<<"$_scalars"
    _test_output="$(printf '%s' "$test_content" | jq -r '.test_output // ""' 2>/dev/null || echo "")"
    if [[ -n "$_test_output" ]]; then
        _test_output="$(printf '%s' "$_test_output" | _zbuild_sanitize_for_llm)"
    fi
    local test_summary
    if [[ -n "$_test_exit" ]]; then
        printf -v test_summary 'verdict: %s\npassed: %s\nfailed: %s\nexit_code: %s' \
            "$_test_verdict" "$_test_passed" "$_test_failed" "$_test_exit"
    else
        printf -v test_summary 'verdict: %s\npassed: %s\nfailed: %s' \
            "$_test_verdict" "$_test_passed" "$_test_failed"
    fi
    if [[ -n "$_test_output" ]]; then
        printf -v test_summary '%s\n\noutput:\n%s' "$test_summary" "$_test_output"
    fi

    # Wave 16-B (#699): structure-first diff-stat summary.
    # Wave 19-G (#739): diff-stat is intentionally EXCLUDED from the
    # redaction pass below. The previous shape put diff-stat at the top of
    # the prompt, which then ran through apply_scope_redaction — wiping
    # every file path to `<out-of-scope-context>` when the scope manifest
    # didn't list those prefixes. The reviewer LLM literally couldn't see
    # which files changed (see dogfood 20260607140638-60666 where all 30
    # rows rendered as `<out-of-scope-context>`). File paths are public
    # signal (they appear in commits) — the diff CONTENT is what scope
    # redaction protects. So we redact the rest of the prompt, then
    # PREPEND the diff-stat block to the redacted payload before sending.
    # #896: stat the SAME diff the LLM judges (the merge-base diff in
    # diff_content), not the per-run diff.patch — which is empty on a resumed/
    # green run and would mislabel the change as "0 files" while the prompt body
    # shows the full diff. In the fallback case diff_content IS diff.patch, so
    # the stat is unchanged there.
    local diff_stat_block _diff_stat_src
    _diff_stat_src="$(mktemp "${TMPDIR:-/tmp}/zb-review-diffstat-XXXXXX")"
    # Trailing newline matters: diff_content arrives via $(...) which strips it,
    # and `git apply --numstat` miscounts a patch whose final line lacks one.
    printf '%s\n' "$diff_content" > "$_diff_stat_src"
    diff_stat_block="$(_zbuild_diff_stat "$_diff_stat_src")"
    rm -f "$_diff_stat_src"

    # Wave 19-G (#739): read intake.md (the original issue body) so review
    # can verify the diff against the issue's Definition of done — not just
    # the plan. Optional: graceful fallback to empty string when intake stage
    # didn't write a body (legacy template paths).
    local intake_body=""
    if [[ -n "$intake_md_path" && -f "$intake_md_path" ]]; then
        intake_body="$(cat "$intake_md_path" 2>/dev/null || true)"
        intake_body="$(printf '%s' "$intake_body" | _zbuild_sanitize_for_llm)"
    fi

    # Wave 19-G (#739): build the prompt with a placeholder for diff-stat
    # at the same position the legacy prompt used (right after instructions,
    # before plan/diff). Diff-stat itself is substituted in AFTER redaction
    # so file paths in the diff-stat header don't get wiped to
    # `<out-of-scope-context>` markers (dogfood 20260607140638-60666 saw
    # all 30 paths wiped). The placeholder is a string the redactor won't
    # touch.
    local _DIFF_STAT_PLACEHOLDER="__ZBUILD_DIFF_STAT_PLACEHOLDER_19G__"
    local prompt
    if [[ -n "$intake_body" ]]; then
        printf -v prompt '%s\n%s\n\nIssue body (authoritative — what "done" means):\n%s\n\nPlan (plan agent interpretation):\n%s\n\nDiff:\n%s\n\nTest results:\n%s\n' \
            "$_review_instructions" \
            "$_DIFF_STAT_PLACEHOLDER" \
            "$intake_body" \
            "$plan_md_clean" \
            "$diff_md_clean" \
            "$test_summary"
    else
        printf -v prompt '%s\n%s\n\nPlan:\n%s\n\nDiff:\n%s\n\nTest results:\n%s\n' \
            "$_review_instructions" \
            "$_DIFF_STAT_PLACEHOLDER" \
            "$plan_md_clean" \
            "$diff_md_clean" \
            "$test_summary"
    fi

    # Write prompt to a temp file for redaction (apply_scope_redaction takes file paths)
    local prompt_file="$artifact_dir/review-prompt.txt"
    printf '%s\n' "$prompt" > "$prompt_file"

    # ADR-032 (#855): per-repo override appended AFTER the contract (so the
    # operator overlay can never precede or weaken the shipped charter). ADR-043:
    # redaction is owned by the router — it covers this override too.
    append_prompt_override "$prompt_file" "review"

    # ─── Assemble the raw prompt (ADR-043: route_to_model redacts it). ──────
    local redacted_prompt
    redacted_prompt="$(cat "$prompt_file")"

    # Wave 19-G (#739): substitute the diff-stat placeholder with the real
    # diff-stat block (file paths + line counts). ADR-043: the assembled prompt
    # — diff-stat included — is redacted by the router; out-of-scope paths are
    # wrapped (content preserved) rather than passed through as before.
    redacted_prompt="${redacted_prompt//"$_DIFF_STAT_PLACEHOLDER"/$diff_stat_block}"

    # ─── Route to LLM (T2 per manifest config.tier_default) ─────────────────
    # ADR-018 (#476): Pattern 1 stages with tools MUST use JSON envelope mode.
    # Envelope (JSON output mode + .result extraction) is unconditional now;
    # without it the model streams reasoning turns as prose before the final
    # JSON and the parser below rejects the response.
    #
    # ADR-018 (#469): opt-in tool-use audit gated by ZBUILD_REVIEW_AUDIT_TOOL_USE=1
    # additionally exports ZBUILD_ROUTER_TOOL_USES_FILE so the router writes
    # tool_uses[] to a side-channel file we can parse back here ($() discards
    # subshell state otherwise).
    local tier; tier="$(resolve_tier review "$_REVIEW_DIR")" || return 1
    local raw_response="" router_rc=0
    local _audit_enabled=0 _audit_tool_uses_file=""
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    # ADR-018 (#483): tag the router's capture so review's own banner renders
    # the review.json output via render_review_md (mirror #476 save/restore).
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_ARTIFACT_ID=review
    if [[ "${ZBUILD_REVIEW_AUDIT_TOOL_USE:-0}" == "1" ]]; then
        _audit_enabled=1
        _audit_tool_uses_file="$artifact_dir/review-tool-uses.json"
        : > "$_audit_tool_uses_file"
        export ZBUILD_ROUTER_TOOL_USES_FILE="$_audit_tool_uses_file"
    fi

    # ── #506: numstat banner override ───────────────────────────────────────
    # The review LLM needs the full diff (above), but the operator-visible
    # stage_io banner should show a compact numstat-style file-change
    # summary, NOT every diff hunk. Compute `git diff <merge-base> HEAD
    # --numstat` and format it via the shared formatter, then export
    # ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE so _stage_io_stdout_begin uses
    # it for the on-screen banner. The persisted artifact + LLM prompt
    # are unchanged.
    local _prev_banner_override="${ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE-__UNSET__}"
    _review_set_banner_override "$scope_manifest" "$diff_patch_path"

    # #491: do NOT redirect route_to_model's stderr — see ADR-015 §v4.
    raw_response="$(route_to_model "$tier" "$redacted_prompt")" || router_rc=$?

    # Restore env immediately after route returns.
    if [[ "$_prev_banner_override" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE
    else
        export ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE="$_prev_banner_override"
    fi
    if [[ "$_prev_json_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_JSON_OUTPUT
    else
        export ZBUILD_ROUTER_JSON_OUTPUT="$_prev_json_env"
    fi
    if [[ "$_prev_artifact_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_ARTIFACT_ID
    else
        export ZBUILD_ROUTER_ARTIFACT_ID="$_prev_artifact_env"
    fi
    if [[ $_audit_enabled -eq 1 ]]; then
        unset ZBUILD_ROUTER_TOOL_USES_FILE
        _review_audit_tool_use "$_audit_tool_uses_file" "$scope_manifest" || true
    fi

    # #476 finding: distinguish "envelope returned empty .result" from
    # "router rc=non-zero" so an empty model output doesn't masquerade as a
    # legitimate verdict downstream.
    if [[ $router_rc -eq 0 && -z "$raw_response" ]]; then
        # AC-1/AC-2 (#1024): an empty .result envelope is a failed model call, not a
        # verdict. Count it toward the consecutive-failure abort like a router error
        # (Copilot review on #1024) so repeated empty responses fast-fail (rc=9).
        error "review_run: router returned empty .result envelope; refusing to emit verdict"
        emit_event "plugin.run.error" "plugin=review" "reason=empty_result_envelope"
        _zbuild_record_cli_fail
        local _ff_rc=0
        _llm_check_cli_fail_abort || _ff_rc=$?
        [[ $_ff_rc -eq 9 ]] && return 9
        return 1
    fi

    # ─── Parse verdict from LLM response ────────────────────────────────────
    local verdict="" confidence="" issues_json="[]" summary=""

    if [[ $router_rc -ne 0 ]]; then
        # AC-1 (#1024): never coerce a failed model call into a semantic verdict.
        # Track consecutive failures; if threshold reached, abort pipeline (rc=9).
        _zbuild_record_cli_fail
        local _ff_rc=0
        _llm_check_cli_fail_abort || _ff_rc=$?
        if [[ $_ff_rc -eq 9 ]]; then
            return 9
        fi
        error "review_run: router rc=$router_rc; no artifact written"
        emit_event "plugin.run.error" "plugin=review" \
            "reason=router_failed" "router_rc=$router_rc"
        return 1
    fi

    if [[ $router_rc -eq 0 && -n "$raw_response" ]]; then
        # AC-4 (#1024): a successful (non-empty) model call resets the consecutive
        # CLI-failure counter so the abort threshold tracks *consecutive* failures,
        # not cumulative blips across the run (Copilot review on #1024).
        _zbuild_reset_cli_fail
        # ADR-028 v1.2 (#944): use _llm_envelope_parse --schema-gate so
        # _llm_recover_envelope_json fires when LAST-wins selects a
        # brace-bearing postamble instead of the real review envelope.
        # This supersedes the #933 fence-detection + extract_first_json_object
        # pattern; recovery is more robust than fence-only disambiguation.
        # shellcheck disable=SC2034  # _review_prose is a required output-param
        # of _llm_envelope_parse; review emits no prose sidecar (only impact does).
        local stripped _review_prose
        _llm_envelope_parse --schema-gate _review_envelope_schema_ok \
            "$raw_response" stripped _review_prose

        verdict="$(printf '%s' "$stripped" \
            | jq -r '.verdict // empty' 2>/dev/null || true)"
        confidence="$(printf '%s' "$stripped" \
            | jq -r '.confidence // 0.5' 2>/dev/null || echo "0.5")"
        local issues_raw
        issues_raw="$(printf '%s' "$stripped" \
            | jq -r '.issues // [] | tojson' 2>/dev/null || true)"
        if printf '%s' "$issues_raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
            issues_json="$issues_raw"
        fi
        summary="$(printf '%s' "$stripped" \
            | jq -r '.summary // ""' 2>/dev/null || true)"
    fi

    # ─── Validate verdict; default to request_changes if invalid ─────────────
    local verdict_valid=false
    local v
    for v in $_REVIEW_VALID_VERDICTS; do
        if [[ "$verdict" == "$v" ]]; then
            verdict_valid=true
            break
        fi
    done

    if ! $verdict_valid; then
        warn "review_run: invalid verdict '${verdict}' from LLM; defaulting to request_changes"
        local original_verdict="$verdict"
        verdict="request_changes"
        confidence="${confidence:-0.5}"
        # Prepend a note about the invalid verdict to issues
        local note="LLM returned invalid verdict '${original_verdict}'; defaulted to request_changes"
        issues_json="$(printf '%s' "$issues_json" \
            | jq --arg n "$note" '. + [$n]' 2>/dev/null \
            || jq -n --arg n "$note" '[$n]')"
        if [[ -z "$summary" ]]; then
            summary="Verdict defaulted: LLM response was not a valid verdict value."
        fi
    fi

    # ─── #485 fail-closed: coerce approve → request_changes when tests
    # did not positively pass. block is the strictest floor and is NOT
    # demoted here (ADR-019). LLM confidence is preserved verbatim — it
    # remains an advisory signal independent of the post-validation result.
    local test_status
    test_status="$(_review_derive_test_status "$test_results_json_path")"
    if [[ "$verdict" == "approve" && ( "$test_status" == "unknown" || "$test_status" == "failed" ) ]]; then
        local original_verdict_485="$verdict"
        local test_exit_code_485=""
        if [[ -f "$test_results_json_path" ]]; then
            test_exit_code_485="$(jq -r '.exit_code // empty' "$test_results_json_path" 2>/dev/null || true)"
        fi
        warn "review_run: verdict coerced from approve to request_changes (test_status=$test_status)"
        verdict="request_changes"
        local coerce_note="tests did not pass (test_status=$test_status); approve coerced to request_changes"
        issues_json="$(printf '%s' "$issues_json" \
            | jq --arg n "$coerce_note" '. + [$n]' 2>/dev/null \
            || jq -n --arg n "$coerce_note" '[$n]')"
        # Prepend coercion note to summary so the LLM's reasoning stays visible.
        if [[ -n "$summary" ]]; then
            summary="[coerced: tests $test_status] $summary"
        else
            summary="[coerced: tests $test_status]"
        fi
        emit_event "review.test_status.coerced" \
            "plugin=review" \
            "stage=review" \
            "original_verdict=$original_verdict_485" \
            "coerced_verdict=request_changes" \
            "test_status=$test_status" \
            "test_exit_code=$test_exit_code_485"
    fi

    # ─── 843-H (#923): mechanical acceptance-coverage gate ───────────────────
    # Downgrade approve → request_changes when a design SPEC-n has no
    # [SPEC-n]-tagged TESTFILE present in the diff under review — i.e. the test
    # that makes the behavior load-bearing was not created/amended in this
    # change. Deterministic complement to the LLM verdict; the acceptance-gate
    # stage (ADR-036) is the producer-side teeth, this is the exit-gate guard.
    # No acceptance block → no-op (composable). block is never demoted.
    # Skip when the merge-base diff basis is unavailable (initial commit, shallow
    # clone, detached checkout without main/origin/main): we cannot compute which
    # files changed, so we must not coerce on an empty diff. The acceptance-gate
    # stage (ADR-036) remains the primary, basis-independent teeth.
    local _design_md="$artifact_dir/design.md"
    if [[ "$verdict" == "approve" ]] && [[ -n "${_mb_base:-}" ]] \
       && grep -q '^```acceptance' "$_design_md" 2>/dev/null; then
        local _changed_files="" _gap_specs="" _spec_id _tf _covered
        _changed_files="$(git diff --name-only "$_mb_base" HEAD 2>/dev/null || true)"
        while IFS= read -r _spec_id; do
            [[ -z "$_spec_id" ]] && continue
            _covered=0
            while IFS= read -r _tf; do
                [[ -z "$_tf" ]] && continue
                grep -qF "[$_spec_id]" "$_tf" 2>/dev/null || continue
                if printf '%s\n' "$_changed_files" | grep -qxF "$_tf"; then
                    _covered=1; break
                fi
            done < <(acceptance_list_testfiles "$_design_md")
            [[ "$_covered" -eq 0 ]] && _gap_specs+="${_gap_specs:+,}$_spec_id"
        done < <(acceptance_list_spec_ids "$_design_md" 2>/dev/null || true)
        if [[ -n "$_gap_specs" ]]; then
            warn "review_run: verdict coerced approve→request_changes (acceptance coverage gap: $_gap_specs)"
            verdict="request_changes"
            local _cov_note="acceptance coverage gap: SPEC(s) $_gap_specs have no [SPEC-n]-tagged test touched in the diff"
            issues_json="$(printf '%s' "$issues_json" \
                | jq --arg n "$_cov_note" '. + [$n]' 2>/dev/null \
                || jq -n --arg n "$_cov_note" '[$n]')"
            if [[ -n "$summary" ]]; then
                summary="[coverage gap: $_gap_specs] $summary"
            else
                summary="[coverage gap: $_gap_specs]"
            fi
            emit_event "review.acceptance_coverage.gap" \
                "plugin=review" "stage=review" "specs=$_gap_specs"
        fi
    fi

    # ─── Write review.json ───────────────────────────────────────────────────
    local issues_count
    issues_count="$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)"

    # Coerce confidence to numeric 0..1; default 0.5 for non-numeric values.
    local confidence_num
    confidence_num="$(printf '%s' "${confidence:-0.5}" \
        | awk 'BEGIN{v=0.5} /^[0-9.]+$/{v=$1; if(v>1)v=1; if(v<0)v=0} END{printf "%g",v}')"

    jq -n \
        --arg verdict "$verdict" \
        --argjson confidence "$confidence_num" \
        --argjson issues "$issues_json" \
        --arg summary "$summary" \
        '{
            schema_version: 1,
            verdict: $verdict,
            confidence: $confidence,
            issues: $issues,
            summary: $summary
        }' | atomic_write "$output_review_json"

    # ADR-026 / Wave 18-B (#707): write review.md alongside review.json so
    # the outer build_review_cycle can wire review_md → build.prior_review_feedback
    # via the cycle orchestrator's _cycle_apply_feedback. Mirrors
    # test_assessment's test-assessment.md sibling-of-json pattern (#568).
    # The artifact is declared optional in manifest.yaml; templates that do
    # NOT wire build_review_cycle pay only the cheap render cost.
    # Copilot P2 (#715): write the markdown sibling via atomic_write to match
    # the canonical sibling-artifact pattern (test_assessment writes both
    # JSON+MD atomically). Plain redirection would leak a partial file if
    # the renderer aborts mid-write, and the prior `|| : >` fallback could
    # additionally truncate a partial output on renderer non-zero rc — both
    # paths now flow through atomic_write's rename-into-place contract.
    local _review_md_path="${output_review_json%.json}.md"
    local _review_md_body=""
    if declare -F render_review_md >/dev/null 2>&1; then
        local _review_json_body
        _review_json_body="$(cat "$output_review_json" 2>/dev/null || true)"
        _review_md_body="$(render_review_md "$_review_json_body" 2>/dev/null || true)"
    fi
    if [[ -z "$_review_md_body" ]]; then
        # Renderer unavailable OR returned empty — emit a minimal markdown so
        # the cycle feedback wiring sees a non-empty file. Never silent-fail
        # to empty file.
        _review_md_body="$(printf '# Review (verdict: %s)\n\n%s\n' \
            "$verdict" "${summary:-}")"
    fi
    printf '%s' "$_review_md_body" | atomic_write "$_review_md_path" \
        2>/dev/null || true

    emit_event "plugin.run.complete" "plugin=review" \
        "verdict=$verdict" \
        "issues_count=$issues_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── _review_set_banner_override ────────────────────────────────────────────
# #506: Compute a numstat-style file-change summary for the operator-visible
# stage_io banner and export it via ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE. The
# review LLM still receives the full diff via the redacted prompt — this
# override ONLY swaps the on-screen banner body.
#
# Args:
#   $1 = scope_manifest path (for the allowlist; reconstructed from `+` lines
#        the same way _review_audit_tool_use does)
#   $2 = diff_patch_path     (used as the --full-at pointer in the
#        truncation hint so operators can grep where the full diff lives)
#
# Strategy:
#   - Resolve merge-base against the default branch (origin/main, then main,
#     then HEAD~1). If none resolves, fall back to `git diff HEAD --numstat`.
#   - Format via shared format_numstat with --event-prefix review so a
#     truncation fires as `review.numstat.truncated`.
#   - Wrap the body in `── changed files ──` heading + a trailing blank line
#     so the override is visually distinct from the raw-prompt body.
#
# Fail-soft: any git error → empty override (banner falls back to raw prompt).
_review_set_banner_override() {
    local scope_manifest="$1"
    local diff_patch_path="$2"

    # Reconstruct allowlist from scope manifest `+` lines.
    local -a _allowed_files=()
    if [[ -n "$scope_manifest" && -f "$scope_manifest" ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -z "$_line" ]] && continue
            _allowed_files+=( "$_line" )
        done < <(awk '/^\+/ { sub(/^\+[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); if (length($0)) print $0 }' "$scope_manifest" 2>/dev/null || true)
    fi

    # Resolve a merge-base ref (shared with the LLM diff source, #896).
    local _base; _base="$(zbuild_resolve_merge_base)"

    local _raw=""
    if [[ -n "$_base" ]]; then
        _raw="$(git diff "$_base" HEAD --numstat 2>/dev/null || true)"
    fi
    if [[ -z "$_raw" ]]; then
        _raw="$(git diff HEAD --numstat 2>/dev/null || true)"
    fi

    # Format. Empty _raw → formatter still emits a "total: 0 files…" footer
    # which is the honest signal to the operator.
    local _formatted
    _formatted="$(format_numstat "$_raw" _allowed_files \
        --event-prefix "review" \
        --full-at "${diff_patch_path:-diff.patch}")"

    export ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE=$'── changed files ──\n'"$_formatted"
    return 0
}

# ─── _review_audit_tool_use ─────────────────────────────────────────────────
# ADR-018 (#469): warn-only audit. Parses tool_uses[] (written by the router
# side-channel) and emits review.scope.violation for each Read whose
# input.file_path is NOT covered by the scope manifest allowlist. Does NOT
# coerce the verdict — downstream consumers decide. Fail-soft: any error is
# logged via warn() but the function still returns 0.
#
# Args:
#   $1 = tool_uses_file (json array; may be empty or missing)
#   $2 = scope_manifest path
_review_audit_tool_use() {
    local tool_uses_file="$1" scope_manifest="$2"

    [[ -z "$tool_uses_file" || ! -s "$tool_uses_file" ]] && return 0
    [[ -z "$scope_manifest" || ! -f "$scope_manifest" ]] && return 0

    # Allowlist: lines starting with '+' in the manifest (mirrors
    # apply_scope_redaction's parser).
    local allow_lines
    allow_lines="$(awk '/^\+/ { sub(/^\+[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); if (length($0)) print $0 }' "$scope_manifest" 2>/dev/null || true)"
    local scope_hash
    scope_hash="$(shasum -a 256 "$scope_manifest" 2>/dev/null | cut -d' ' -f1)"

    # Extract Read paths from tool_uses[]; skip non-Read calls.
    local read_paths
    read_paths="$(jq -r '
        if type == "array" then
            .[] | select(.name == "Read") | .input.file_path // empty
        else
            empty
        end
    ' "$tool_uses_file" 2>/dev/null || true)"

    [[ -z "$read_paths" ]] && return 0

    local path stripped in_scope a
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        stripped="${path#./}"
        in_scope=0
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            # Prefix match — `a` is the allowlist entry (e.g. "tests/"). The
            # case glob `"$a"*` expands to e.g. `tests/*` and matches when
            # `stripped` starts with `a`. Quote `a` so its own contents are
            # taken literally; only the trailing `*` is a glob.
            case "$stripped" in
                "$a"*) in_scope=1; break ;;
            esac
        done <<< "$allow_lines"
        if [[ $in_scope -eq 0 ]]; then
            emit_event "review.scope.violation" \
                "plugin=review" \
                "stage=review" \
                "path=$path" \
                "scope_hash=$scope_hash"
            warn "review_audit: out-of-scope Read on '$path' (warn-only; verdict unchanged)"
        fi
    done <<< "$read_paths"

    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
review_finalize() {
    emit_event "plugin.finalize.complete" "plugin=review"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
review_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=review"
    return 0
}
