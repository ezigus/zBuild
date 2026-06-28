#!/usr/bin/env bash
# plugins/agent/review-lens/lib/charters.sh — per-lens charter + prompt builder.
#
# ADR-040 §3 (EPIC #1129 C1). A lens is a first-class semantic-judgment stage,
# no longer a sub-routine of one review stage. Each lens differs by the distinct
# QUESTION it asks (its charter) over evidence it is fed — the ADR-038 §2
# isolated-call principle: one prompt per lens, never one prompt with N sections.
# Charter text is shared with plugins/agent/review-report/lib/lenses.sh until the
# C3 cutover retires that fan-out; duplicating the source here is intentional.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_CHARTERS_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_CHARTERS_LOADED=1

# ─── _rl_lens_charter <lens> ────────────────────────────────────────────────
# The distinct question each lens asks. ADR-038 §2: lenses differ by the
# evidence/charter, not by sectioning one mega-prompt.
_rl_lens_charter() {
    case "$1" in
        correctness)
            printf '%s' "Examine the change for logic errors: off-by-one mistakes, unhandled null/undefined values, incorrect assumptions about data shapes, and control-flow bugs." ;;
        security)
            printf '%s' "Examine the change for security weaknesses: injection risks, credential or secret exposure, path traversal, and missing input validation at system boundaries (CLI, parsers, plugin manifests)." ;;
        test-coverage)
            printf '%s' "Examine whether the changed lines are exercised by tests: untested public functions, missing edge-case coverage, and assertions that are too weak to catch a regression." ;;
        design-conformance)
            printf '%s' "Examine whether the change implements what the plan and design described: missing pieces, out-of-scope additions, and divergence from the stated approach." ;;
        integration)
            printf '%s' "Examine the change for integration problems: missing imports, broken call chains, mismatched interfaces between modules, functions called with wrong argument shapes, and wiring gaps where new code is not connected to existing code." ;;
        error-handling)
            printf '%s' "Examine the change for error-handling gaps: silent error swallowing, missing error paths when external commands fail, inconsistent error patterns, and unchecked return values." ;;
        performance)
            printf '%s' "Examine the change for performance problems: O(n^2) or worse loop patterns, unbounded memory allocation or file reads, missing pagination or streaming for large data, and repeated expensive operations that could be cached." ;;
        edge-case)
            printf '%s' "Examine the change for edge-case gaps: zero-length inputs, empty strings and arrays, boundary values at maximum or minimum, Unicode and special characters in data paths, and concurrent access timing issues." ;;
        architecture)
            printf '%s' "Examine the change for architectural violations: layer-boundary breaches, coupling between components that should be isolated, divergence from established patterns and conventions, and structural decisions that would impede future evolution." ;;
        red-team)
            printf '%s' "Examine the change as a hostile reviewer looking for exploitable flaws: race conditions, privilege escalation paths, logic errors that can be triggered by adversarial input, and security assumptions that break under adversarial conditions." ;;
        maintainability)
            printf '%s' "Examine the change for long-term maintainability risks: code smells, poor naming, unclear logic, coupling issues, missing tests, and violations of established patterns that make future changes harder." ;;
        scope)
            printf '%s' "WARN ONLY (advisory, never blocking): compare the change against the declared scope. Flag files edited in the diff that the planned scope did not list (out-of-scope edits), and files the scope listed but the diff did not touch (in-scope-but-untouched). Report each as a low/medium finding describing the scope drift; never recommend reverting or blocking." ;;
        *)
            printf '%s' "Examine the change for issues relevant to the ${1} concern." ;;
    esac
}

# ─── _rl_build_lens_prompt <lens> <evidence_content> ────────────────────────
# One prompt for ONE lens. Advisory contract: emit findings + a 0-10 score only.
_rl_build_lens_prompt() {
    local lens="$1" evidence="$2" charter
    charter="$(_rl_lens_charter "$lens")"
    cat <<PROMPT
You are the "${lens}" review lens. ${charter}

This is an advisory report. Describe what you find; do NOT recommend a merge
action and do NOT gate anything. Report only issues you can point to in the
change below.

OUTPUT CONTRACT (obey absolutely):
- Respond with EXACTLY ONE JSON object. First character '{', last character '}'.
- Your response MUST begin with \`{\` — no leading prose, no trailing prose, no markdown fences.
- Schema:
  {
    "score": <integer 0-10, 10 = no concerns for this lens>,
    "findings": [
      {
        "file": "<path>",
        "category": "<short category, e.g. logic, injection, coverage>",
        "severity": "<one of: low, medium, high, critical>",
        "line": <integer line number or null>,
        "message": "<one-sentence description>"
      }
    ]
  }
- If you find nothing for this lens, return {"score": 10, "findings": []}.

CHANGE UNDER REVIEW:
${evidence}

Emit the JSON object now.
PROMPT
}
