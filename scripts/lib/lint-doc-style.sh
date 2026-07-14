#!/usr/bin/env bash
# scripts/lib/lint-doc-style.sh — enforce docs/DOC-STYLE.md "newcomer opening" (#1406).
#
# DOC-STYLE.md rule 1 ("Open for a total newcomer") and rule 5 ("Every page is
# self-contained at the top") require every user-facing page to open — right
# after its H1 title — with a plain-language sentence saying what it is / who
# it's for / what problem it solves, *before* any mechanism, table, code, or
# diagram. This is the ENFORCEMENT half of #1406; the standard itself and the
# newcomer rewrites of README + the wiki landed in #1405.
#
# This checker verifies that STRUCTURAL fact only — that a real prose sentence
# exists near the top. It is deliberately NOT a subjective prose-quality judge:
# it is deterministic, repo-agnostic, and makes zero model calls, so it can run
# in the Lint CI job like the sibling lint-contract / lint-stage-io guards.
#
# IN SCOPE:  README.md  +  every top-level docs/wiki/*.md  EXCEPT _Sidebar.md.
# OUT OF SCOPE (NOT checked here): the generated docs/wiki/plugins/*.md and
#   docs/wiki/mechanics/*.md subdirectories. #1406 delegates enforcement of the
#   generated pages to #876 (docs-as-release coverage gate) and #1356 (per-leaf
#   / per-mechanic generators) — both of which cite docs/DOC-STYLE.md. A later
#   issue can extend this check to the subdirs once the generators emit
#   conforming openings.
#
# THE MECHANICAL RULE (structural, objective):
#   For each in-scope file, after the first H1 (`# ...`) line, within the first
#   ~12 non-blank lines there MUST be a plain PROSE line — a real sentence.
#   A line qualifies as a prose opening when it is NONE of:
#     - a heading             (starts with `#`)
#     - a code fence          (starts with ``` or ~~~)
#     - a table row           (starts with `|`)
#     - a badge / image / html(starts with `![`  or  `<`)
#     - a bare list item      (starts with `- `, `* `, `+ `, or `N.`)
#   and IS a real sentence: at least 5 words and ending in sentence punctuation
#   (`.` `!` `?`, allowing one trailing `)` or backtick). Bold-wrapped prose
#   like `**...sentence.**` counts (README/Home open this way); a blockquote
#   `> real sentence.` counts (the leading `>` is stripped before the checks).
#
# If a file has no such newcomer opening, it FAILS with `path — reason`. The
# script exits non-zero if ANY in-scope file fails, and prints a clean pass line
# otherwise. Uses /usr/bin/grep for the H1 scan (the repo default `grep` is
# ugrep). Fails loud if the docs dir or any target file is missing.
#
# Exit codes:
#   0 — every in-scope page has a conforming newcomer opening
#   1 — at least one in-scope page lacks a plain-language opening (or is missing)
#
# Usage:
#   bash scripts/lib/lint-doc-style.sh

set -euo pipefail

SYSGREP=/usr/bin/grep

_DOC_STYLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Target repo = the repo being linted (honor ZBUILD_REPO_ROOT, set by the release
# path); fall back to the script-relative root for direct/source invocation (#1487).
_REPO_ROOT="${ZBUILD_REPO_ROOT:-$(cd "$_DOC_STYLE_DIR/../.." && pwd)}"
_WIKI_DIR="$_REPO_ROOT/docs/wiki"

# Fail loud if the wiki dir vanished — a silent empty scan would let CI pass
# while the docs are gone.
if [[ ! -d "$_WIKI_DIR" ]]; then
    printf 'lint-doc-style: docs/wiki directory not found at %s\n' "$_WIKI_DIR" >&2
    exit 1
fi

# Build the in-scope target list: README.md + every top-level docs/wiki/*.md
# except _Sidebar.md. Subdirectories (plugins/, mechanics/) are intentionally
# excluded — `find -maxdepth 1` keeps this to the top level only.
_targets=("$_REPO_ROOT/README.md")
while IFS= read -r -d '' _f; do
    _targets+=("$_f")
done < <(find "$_WIKI_DIR" -maxdepth 1 -type f -name '*.md' ! -name '_Sidebar.md' -print0 | sort -z)

# Does one line qualify as a plain prose opening sentence? Returns 0 if yes.
_is_prose_opening() {
    local line="$1"

    # Strip a leading blockquote marker: `> real sentence.` is prose.
    line="${line#> }"
    line="${line#>}"

    # Trim leading whitespace.
    line="${line#"${line%%[![:space:]]*}"}"

    # Empty after trimming — not prose.
    [[ -n "$line" ]] || return 1

    # Reject structural / non-prose openings by first token(s).
    case "$line" in
        '#'*) return 1 ;;                 # heading
        '```'*|'~~~'*) return 1 ;;         # code fence
        '|'*) return 1 ;;                  # table row
        '!['*) return 1 ;;                 # image / badge
        '<'*) return 1 ;;                  # raw html
        '- '*|'* '*|'+ '*) return 1 ;;     # bare bullet
        [0-9]'. '*|[0-9][0-9]'. '*) return 1 ;;  # ordered list item
    esac

    # Must end in sentence punctuation, allowing one trailing `)` or backtick
    # (e.g. `...ships.)` or an inline-code close). Also tolerate a trailing
    # bold/italic close `*` after the punctuation for `**...sentence.**`.
    local trimmed="${line%%[[:space:]]}"
    trimmed="${trimmed%[*_\`]}"      # drop one trailing emphasis/backtick marker
    trimmed="${trimmed%[*_\`]}"      # ... and a second (e.g. `**` bold close)
    trimmed="${trimmed%)}"           # drop one trailing `)`
    case "$trimmed" in
        *'.'|*'!'|*'?') : ;;
        *) return 1 ;;
    esac

    # Require at least 5 words (a real sentence, not a fragment/label). The
    # threshold is 5 rather than 6 so genuinely-conforming short openers pass —
    # e.g. Troubleshooting.md opens "Something isn't working. Start here."
    # (5 words), a real newcomer sentence we must NOT force-edit.
    local wc
    wc=$(printf '%s\n' "$line" | wc -w | tr -d '[:space:]')
    [[ "$wc" -ge 5 ]] || return 1

    return 0
}

_failures=0
_checked=0

for _file in "${_targets[@]}"; do
    if [[ ! -f "$_file" ]]; then
        printf '%s — missing (in-scope file not found)\n' "$_file" >&2
        _failures=$((_failures + 1))
        continue
    fi
    _checked=$((_checked + 1))

    # Find the line number of the first H1 (`# ...`) via system grep (ugrep-safe).
    _h1_ln="$($SYSGREP -n -m1 -E '^# ' "$_file" | cut -d: -f1 || true)"
    if [[ -z "$_h1_ln" ]]; then
        printf '%s — no H1 title (`# ...`) found\n' "$_file" >&2
        _failures=$((_failures + 1))
        continue
    fi

    # Scan the non-blank lines after the H1, up to a ~12 non-blank-line window,
    # for the first line that qualifies as a plain prose opening.
    _found=0
    _nonblank=0
    _lineno=0
    while IFS= read -r _l; do
        _lineno=$((_lineno + 1))
        [[ "$_lineno" -le "$_h1_ln" ]] && continue   # skip through the H1
        [[ -z "${_l//[[:space:]]/}" ]] && continue   # skip blank lines
        _nonblank=$((_nonblank + 1))
        [[ "$_nonblank" -gt 12 ]] && break
        if _is_prose_opening "$_l"; then
            _found=1
            break
        fi
    done < "$_file"

    if [[ "$_found" -ne 1 ]]; then
        printf '%s — no plain-language newcomer opening in the first 12 non-blank lines after the H1 (DOC-STYLE.md rule 1/5)\n' \
            "$_file" >&2
        _failures=$((_failures + 1))
    fi
done

if [[ "$_failures" -gt 0 ]]; then
    printf '\nlint-doc-style: %d file(s) lack a newcomer opening. Each in-scope page must open, right after its H1, with a plain sentence saying what it is / who it is for / what problem it solves (see docs/DOC-STYLE.md).\n' \
        "$_failures" >&2
    exit 1
fi

printf 'lint-doc-style: OK — %d in-scope page(s) have a plain-language newcomer opening (README + docs/wiki/*.md, excluding _Sidebar.md and generated subdirs).\n' "$_checked"
exit 0
