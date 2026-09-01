#!/usr/bin/env bash
# lint-test-identity — tests must not use a plausible issue number as identity.
#
# 25 of the 29 numbers tests used were real issues or PRs, and #42 was OPEN. A
# test that keys a run to one writes fabricated prior work onto that issue's
# state branch: measured on this repo, zbuild/state/issue-999 held 68 commits of
# test payloads and issue-698 held 121. Since #1970/#2006 the CI path chains and
# pushes, so that reaches origin and a real run would restore it.
#
# Identity comes from zb_test_issue (90000001+), which no repository can reach.
# Per-line opt-out is `# lint-test-identity:allow` on the offending line —
# visible at the site and greppable, not a path rule that widens silently. That
# distinction is what #1969 had to undo for lint-grep-c.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Both assignment forms. The quoted one was missed on the first pass and hid 31
# sites, so it is pinned explicitly here.
PATTERN='(ZBUILD_ISSUE_NUMBER|ZBUILD_ISSUE)="?[0-9]+"?|--issue[ =]+[0-9]+|_artifact_persist_(push|restore|adopt_remote|branch|has_identity) [0-9]+|zbuild_run_key [0-9]+'

_offenders=""
while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"

    # Pure-bash matching below, deliberately: `printf ... | grep -q` is the
    # SIGPIPE antipattern this repo guards against (#1015, #1260), and a bare
    # `| head` trips #1886. Parameter expansion and [[ =~ ]] need neither.
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == "#"* ]] && continue                       # provenance, not identity
    [[ "$text" == *"lint-test-identity:allow"* ]] && continue

    num=""
    if [[ "$text" =~ (ZBUILD_ISSUE_NUMBER|ZBUILD_ISSUE)=\"?([0-9]+) ]]; then
        num="${BASH_REMATCH[2]}"
    elif [[ "$text" =~ --issue[\ =]+([0-9]+) ]]; then
        num="${BASH_REMATCH[1]}"
    elif [[ "$text" =~ _artifact_persist_[a-z_]+\ ([0-9]+) ]]; then
        num="${BASH_REMATCH[1]}"
    elif [[ "$text" =~ zbuild_run_key\ ([0-9]+) ]]; then
        num="${BASH_REMATCH[1]}"
    fi
    [[ -z "$num" ]] && continue
    [[ "$num" == "0" ]] && continue          # the no-identity sentinel
    [[ "$num" -ge 90000000 ]] && continue    # reserved test range

    _offenders+="  $file:$line: ${trimmed:0:90}"$'\n'
done < <(grep -rnE "$PATTERN" tests/ core/ plugins/ 2>/dev/null || true)

if [[ -n "$_offenders" ]]; then
    printf 'lint-test-identity: FAIL — a real issue number is used as test identity\n\n'
    printf '%s\n' "$_offenders"
    printf 'Use zb_test_issue (90000001+) so a stray zbuild/state ref is\n'
    printf 'unmistakably test residue and can never collide with real prior work.\n'
    printf 'If the number genuinely is not an identity, append:  # lint-test-identity:allow\n'
    exit 1
fi
printf 'lint-test-identity: OK — no real issue number used as test identity\n'
