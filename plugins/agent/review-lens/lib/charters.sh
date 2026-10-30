#!/usr/bin/env bash
# plugins/agent/review-lens/lib/charters.sh — the review-lens prompt builder.
#
# ADR-040 §3: one prompt per lens (ADR-038 §2), each lens a map element of the
# review-lens stage. A lens is a stage like any other (ADR-051 §3, amended
# 2026-10-12): this stage writes one job for every lens, and the question a
# lens asks is its persona's, which the provider delivers — the element names
# its persona in the template. No lens is special-cased here.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_CHARTERS_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_CHARTERS_LOADED=1

# ─── _rl_build_lens_prompt <lens> <evidence_content> [context] ─────────────
# One prompt for ONE lens: its findings and a 0-10 score. The severity scale is
# defined here, once, for every lens (#2433); each persona gives examples.
# <context> is what the change was FOR — the issue, its SPECs, the planned
# scope (#1654, #1845 PR #2213): a lens that sees only the diff reads engine-set
# values as attacker input and cannot tell a defect from what was asked for.
# The "compare with the issue" paragraph is here, so every lens gets it from one
# source (#2307).
_rl_build_lens_prompt() {
    local lens="$1" evidence="$2" context="${3:-}"
    cat <<PROMPT
## What you own
A report for the "${lens}" lens: each problem you find in the change,
judged from your own perspective,
and a score. A problem the change introduced at a severity the template names
sends the change back for another round, to the stage that can fix it. For each problem, say whether the change INTRODUCED it (or made it
worse), or whether the code before the change already did the same thing.
Compare the change with the issue it was made for. If the change does not
deliver part of what the issue asked for, report it as a finding: name any part
of the issue that the change does not deliver, judged as the "${lens}" lens
judges.
Where the change reads data another part of the code writes, you open the
code that writes it, then check the change uses the names and shapes it really
produces, and that its tests make such data with that code, not by hand.

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
        "message": "<one-sentence description>",
        "introduced": <true if this change introduced or worsened it; false if the code before the change already did this>,
        "fix": "<one of: code, test, design, issue>"
      }
    ]
  }
- If you find nothing for this lens, return {"score": 10, "findings": []}.

SEVERITY — grade each finding on this one scale:
- \`critical\`: the change makes the program unsafe or wrong for everyone: data loss, a security hole, or the run breaking on a normal path.
- \`high\`: the change is wrong on a path the issue cares about, or breaks something it should not touch.
- \`medium\`: the change works, but a realistic case gets it wrong, a test does not prove what it claims, or the design leaves a gap that will cause the next bug.
- \`low\`: style, wording, a small inefficiency, or hardening against an unlikely case.

FIX — say what would fix each finding:
- \`code\`: the code must change.
- \`test\`: a test must be added or changed.
- \`design\`: the design must change: a decision, a requirement in its acceptance contract, or its scope.
- \`issue\`: the issue itself is wrong: it contradicts an ADR, or asks for something that cannot be built as written. No stage can fix this.

## What you judge against
The diff below shows WHAT CHANGED. Before you judge a line,
read the surrounding code in the repository: the rest of the file, its callers,
what produces its inputs, and comparable code elsewhere. A problem may be proven by unchanged code
(the change disagrees with its neighbours) — cite it. Report problems in the
change.
${context:+
${context}
}
CHANGE UNDER REVIEW:
${evidence}

## What you must not do
- Describe what you find; do NOT recommend a merge action, and do NOT name
  which stage should fix it: say what would fix it.

Emit the JSON object now.
PROMPT
}
