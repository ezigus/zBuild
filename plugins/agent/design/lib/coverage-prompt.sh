#!/usr/bin/env bash
# plugins/agent/design/lib/coverage-prompt.sh — what design's coverage check is
# asked (#2369, ADR-073 §5). Split from coverage.sh (#2567: coverage.sh under
# 500 lines); its callers are in coverage.sh.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_DESIGN_COVERAGE_PROMPT_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_COVERAGE_PROMPT_LOADED=1

# The call's three parts, composed with the engine's blocks in the one prompt
# order (ADR-067 §8). #2470: requirement coverage is asked only when a SPEC
# changed or a requirement's finding was answered; with [reqs] it is.
_dcov_prompt_own() {
    local reqs="${1:-}" steps="${2:-}" decision="${3:-}"
    printf 'You are checking whether a DESIGN covers what an ISSUE asked for, SPEC by SPEC.\n'
    [[ -n "$reqs" ]] && cat <<'EOF2'

Check EVERY requirement, and find EVERY one that no SPEC fully covers — not
only the first you find. The design is revised once per round and fixes only
what you list; a gap left out of this answer costs a whole round.
EOF2
    cat <<'EOF2'

Judge every part of the design — each SPEC line, the steps and the decisions — against everything the issue gives you: its REQUIREMENTS, its LIMITS, its TERMS and its own words.
Every part must be needed by them and agree with them. A part carried over from an earlier design is judged the same as a new one.
Find EVERY part that commits to something that the issue does not ask for, or that contradicts it — not only the first.
Every SPEC shown in full is such a part, line by line.

Check each SPEC's status against the code from before this change and the
issue. Its status follows from three facts:
- Is it a change to a document only? Then it is [doc].
- If not, does the code from before this change already behave as the SPEC says — by any route, a fallback included? If not, it is [code].
- If it does, is work still needed that changes no behaviour — a test, a config, a refactor? Then it is [no-code]; if none, it is [done].
Find every SPEC whose status is not the one these facts give. Then judge each
of its parts.

Answer in exactly this form, each line starting with its id.
EOF2
    [[ -n "$reqs" ]] && cat <<'EOF2'

One line for every requirement:

<requirement id>: covered
<requirement id>: uncovered | WHY: <what no SPEC covers> | QUOTE: <the requirement's own words that no SPEC covers>

When nothing a test could observe would show a requirement met, no SPEC can
cover it and the issue must be fixed by its owner:

<requirement id>: none | WHY: <why nothing a test could observe after the change would show it met> | QUOTE: <the requirement's own words>
EOF2
    cat <<'EOF2'

At least one line for every SPEC shown in full. When nothing is wrong with it,
one line:

<SPEC id>: ok

When something is wrong with it, one line for each thing wrong, and no ok line,
every one in this form:

<SPEC id> <line>: <problem> | WHY: <why> | QUOTE: <words from that line>

<line> is the word the line starts with: Title (the SPEC's first line), Given, When, Then, And or Cleanup.
The QUOTE is copied from that line, and says which line it is when the SPEC has
several. <problem> is one of:

- not-asked — the line commits to something the issue does not ask for, or contradicts it
- untestable — only for a Then, or an And under a Then: it must be something a
  test can observe after the When — an output, a result, a file the code
  writes, an event — never what a file or a test contains, and never "it works"
- how — the line says how the code is built, or how a test sets something up or
  checks it; a Given names the situation the code is in, never the steps a test
  takes to get there

An untestable or a how line also says what the line could say instead — what a
test could observe after the When for the same requirement:

<SPEC id> <line>: untestable | WHY: <why> | INSTEAD: <what a test could observe after the When instead> | QUOTE: <words from that line>
<SPEC id> <line>: how | WHY: <why> | INSTEAD: <what a test could observe after the When instead> | QUOTE: <words from that line>

- contradicts — the line cannot be true together with something else, and WHY
  says what and where
- duplicate — only for the When: another SPEC already has this action, and WHY
  names it
- new-owner — only on Title: the SPEC builds something new for a job that
  something in the code from before this change already does; the QUOTE is a
  line of that existing owner, as <file> | <one line of it>
- status — only on Title, for a SPEC whose status is not the one its facts give,
  with the three facts, each yes or no, and a QUOTE from the code instead of the
  SPEC:

<SPEC id> Title: status | DOC: <yes or no> | BEFORE: <yes or no> | WORK: <yes or no> | WHY: <what shows it> | QUOTE: <file> | <one line of it>

A status QUOTE is a line of the code from before this change, or of the
document, that shows the fact the status gets wrong: when it already behaves
this way, the line that does it; when it does not, the line that does
something else.
EOF2
    # #2567 (ADR-073 §5): the steps and the decisions, by the same rule.
    [[ -n "$steps" ]] && cat <<'EOF2'

At least one line for the design's steps (its ```steps block): ok, or one line
for each problem. new-owner is a step that builds something new — a file, a
library, a mechanism — for a job that something in the code from before this
change already does; look for it before you answer: the plugin kinds in
docs/ARCHITECTURE.md, the ADRs for the area, the existing plugins and libraries.

Steps: ok
Steps: not-asked | WHY: <no requirement needs this step> | QUOTE: <the step's words>
Steps: contradicts | WHY: <which requirement, limit or term, and how> | QUOTE: <the step's words>
Steps: new-owner | WHY: <what the steps build, and what already owns that job> | QUOTE: <file> | <one line of the existing owner>
EOF2
    [[ -n "$decision" ]] && cat <<'EOF2'

At least one line for the design's decisions (DECISIONS below): ok, or one line
for each problem, in the forms of the steps:

Decision: ok
Decision: not-asked | WHY: <no requirement needs this> | QUOTE: <the decisions' words>
Decision: contradicts | WHY: <which requirement, limit or term, and how> | QUOTE: <the decisions' words>
Decision: new-owner | WHY: <what it builds, and what already owns that job> | QUOTE: <file> | <one line of the existing owner>
EOF2
    cat <<'EOF2'

Copy each QUOTE as it is from what it names, with no quote marks around it. It
is checked: a quote that is not there makes the answer unusable.
EOF2
}

# _dcov_prompt_judge <draft> <shown> [requirements] [others] [done_evidence] [base] [issue] [limits] [terms] [steps] [decisions] [requirements shown only]
# — <shown> the SPECs to judge, in full; [others] the rest, by their first line,
# given only with [requirements], for what they cover (#2470, ADR-072 §4).
_dcov_prompt_judge() {
    cat <<EOF2
The design you judge is the file at $1 — read it there for anything you need
that is not shown here. Do not open design.md: it is an earlier design, not the
one you judge.
EOF2
    [[ -n "${7:-}" ]] && printf '\nISSUE — the issue itself, in the requester'"'"'s own words:\n%s\n' "$7"
    [[ -n "${3:-}" ]] && cat <<EOF2

REQUIREMENTS — the issue's requirements, each with its id.

Judge every requirement in REQUIREMENTS by its words. Read the issue for what a
requirement means. A SPEC may say which requirements it covers; check its
words, not only the ids it names.

An issue contains more than requirements — context, rationale, links, history.
Those are not requirements and their absence from the SPECs is not a gap. Judge
what the issue REQUIRES, not everything it mentions.

Several SPECs may cover one requirement together, one thing each: judge every
SPEC that names it, together.

When a requirement is written so loosely that no SPEC could settle it — nothing
anyone could observe would show it met — answer none for it:
that is a finding against the requirement, for the issue's owner, not a gap a
SPEC can close.

Mapping is not enough: those SPECs together must demand ALL of the requirement.
A set of SPECs that demands less than the requirement — a subset of the cases,
a weaker condition, some of the files, a narrower scope — leaves it uncovered. Name the
requirement as uncovered and say what the SPECs leave out.

You judge the design before any code exists, so your part of each requirement
is the BEHAVIOUR it asks of the software. A requirement about how the change is
verified — that the tests fail on the code from before the change, that the
full suite is green, that the mutation tests run, that the tree is committed
first — can only be judged once the change and its tests exist, and the check
that compares the finished change with the issue judges it there. It is not
uncovered.

A SPEC tagged [done] says the code already does it. A requirement it covers
counts as covered: the claim is judged against the code once the change is
built.

REQUIREMENTS:
$3
EOF2
    [[ -n "${12:-}" ]] && printf '\nREQUIREMENTS — shown for what the steps and the decisions must be needed by and agree with. Give them no line:\n%s\n' "${12}"
    printf '\nACCEPTANCE — the SPECs to judge, each with its parts:\n'
    printf 'ACCEPTANCE:\n%s\n' "${2:-(none)}"
    # #2550 (ADR-069): a limit is not covered; a SPEC that builds one contradicts it.
    [[ -n "${10:-}" ]] && printf '\nSTEPS — the design'"'"'s steps, to judge by the rule above:\n%s\n' "${10}"
    [[ -n "${11:-}" ]] && printf '\nDECISIONS — the design'"'"'s decisions, to judge by the rule above:\n%s\n' "${11}"
    # #2555 (ADR-070): the issue's terms, word for word, as every stage gets them.
    [[ -n "${9:-}" ]] && printf '\nTERMS — what the issue says each of these words means, and only this. Any part of the design — a SPEC line, a step, the decisions — that uses a term differently from its definition contradicts it: answer contradicts for that part, quoting it.\n%s\n' "$9"
    [[ -n "${8:-}" ]] && printf '\nLIMITS — what the change must not do. They are not requirements: give them no line. Any part of the design — a SPEC line, a step, the decisions — that does what a limit forbids contradicts it: answer contradicts for that part, quoting it.\n%s\n' "$8"
    [[ -n "${3:-}" && -n "${4:-}" ]] && printf '\nOTHER SPECS — judged before and unchanged, shown by their first line for what they cover. Do not answer for them.\n%s\n' "$4"
    [[ -n "${5:-}" ]] && printf "\nTHE [done] SPECS' EVIDENCE — a file and a piece of its text. Open the file\nand read the code around that text, as much as you need:\n%s\n" "$5"
    # #2543: every SPEC's status is checked against it, not only a [done] one's.
    [[ -n "${6:-}" ]] && printf '\nThe code from before this change is a copy at %s — check each SPEC'"'"'s\nstatus there. The repository as it is now is the current directory.\n' "$6"
    return 0
}
_dcov_prompt_limits() {
    cat <<'EOF2'
- Do not suggest SPEC text.
- Do not rewrite the design.
- Answer only, in the form above.
EOF2
}
