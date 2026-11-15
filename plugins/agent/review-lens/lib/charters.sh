#!/usr/bin/env bash
# plugins/agent/review-lens/lib/charters.sh — the review-lens prompt builder.
#
# ADR-040 §3: one prompt per lens (ADR-038 §2), each lens a map element of the
# review-lens stage. Each lens's job is its own text, lenses/<lens>.md (#2548,
# ADR-038 amended 2026-11-15): what it looks for, what is not a finding, where
# its problems come from, and its severity examples. The persona the template
# names for the element is who does the job, and reaches the model through the
# provider. No lens is special-cased in code.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_CHARTERS_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_CHARTERS_LOADED=1

_RL_LENSES_DIR="${BASH_SOURCE[0]%/*}/../lenses"
# The repository's own lens jobs are read like its rules.md: the one reader
# that refuses a link out of the folder, and caps the size.
if ! declare -F _po_load_repo_file >/dev/null 2>&1; then
    # shellcheck source=../../../../scripts/lib/prompt-overrides.sh
    source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/prompt-overrides.sh"
fi

# _rl_lens_job_v <var> <lens> — the lens's own job text, read in this shell
# (ADR-065 §5): the target repository's .zbuild/lenses/<lens>.md, else the
# install's (ADR-038, amended 2026-11-15: a repository may add or change a
# lens). rc 1 when the lens has none: it reviews nothing.
_rl_lens_job_v() {
    local -n _rlj="$1"; local _f="$_RL_LENSES_DIR/$2.md"
    _rlj=""
    [[ "$2" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    # Only a repository that has one pays for the checked read.
    if [[ -n "${ZBUILD_REPO_ROOT:-}" && -e "$ZBUILD_REPO_ROOT/.zbuild/lenses/$2.md" ]]; then
        _rlj="$(_po_load_repo_file ".zbuild/lenses/$2.md" "$ZBUILD_REPO_ROOT")"
        [[ -n "$_rlj" ]] && return 0
    fi
    [[ -s "$_f" ]] || return 1
    IFS= read -r -d '' _rlj < "$_f" || true
    _rlj="${_rlj%$'\n'}"
    [[ -n "$_rlj" ]]
}

# ─── _rl_build_lens_prompt <lens> <change> [context] ───────────────────────
# One prompt for ONE lens: its findings and a 0-10 score. The severity scale is
# defined here, once, for every lens (#2433); each lens's job gives examples.
# <context> is what the change was FOR — the issue, its SPECs, the planned
# scope (#1654, #1845 PR #2213): a lens that sees only the change reads engine-set
# values as attacker input and cannot tell a defect from what was asked for.
# The "compare with the issue" paragraph is here, so every lens gets it from one
# source (#2307).
_rl_build_lens_prompt() {
    local lens="$1" evidence="$2" context="${3:-}" job=""
    _rl_lens_job_v job "$lens" || job=""
    cat <<PROMPT
## What you own
A report for the "${lens}" lens: each problem you find in the change, as this
lens judges it, and a score.

${job}

A problem the change introduced at a severity the template names sends the
change back for another round, to the stage that can fix it. For each problem,
say whether the change INTRODUCED it (or made it worse), or whether the code before the change already did the same thing.
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
        "message": "<one-sentence description>",
        "quote": "<the exact text that shows it, copied from the file as it is now, or a line the change removed>",
        "introduced": <true if this change introduced or worsened it; false if the code before the change already did this>,
        "fix": "<one of: code, test, design, issue>"
      }
    ]
  }
- Every finding quotes the text that shows it. The quote is checked against
  its file and the change: a finding whose quote is not there makes the report
  unusable.
- If you find nothing for this lens, return {"score": 10, "findings": []}.

SEVERITY — grade each finding on this one scale:
- \`critical\`: the change makes the program unsafe or wrong for everyone: data loss, a security hole, or the run breaking on a normal path.
- \`high\`: the change is wrong on a path the issue cares about, or breaks something it should not touch.
- \`medium\`: the change works, but a realistic case gets it wrong, a test does not prove what it claims, or the design leaves a gap that will cause the next bug.
- \`low\`: style, wording, a small inefficiency, or hardening against an unlikely case.

FIX — say what would fix each finding:
- \`code\`: the code must change.
- \`test\`: a test must be added, changed or moved — which cases a test covers and which file holds it are the tests' to fix, never the design's.
- \`design\`: the design must change: a decision, or a requirement in its acceptance contract.
- \`issue\`: the issue itself is wrong: it contradicts an ADR, or asks for something that cannot be built as written. No stage can fix this.

## What you judge against
THE CHANGE below names the commit this branch started from and the files it
changed: read each change with git diff, as it says there. Before you judge a
line, read the surrounding code in the repository: the rest of the file, its
callers, what produces its inputs, and comparable code elsewhere. A problem may be proven by unchanged code
(the change disagrees with its neighbours) — cite it. Report problems in the
change.
${context:+
${context}
}
THE CHANGE:
${evidence}

## What you must not do
- Describe what you find; do NOT recommend a merge action, and do NOT name
  which stage should fix it: say what would fix it.

Emit the JSON object now.
PROMPT
}
