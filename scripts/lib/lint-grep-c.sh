#!/usr/bin/env bash
# scripts/lib/lint-grep-c.sh — reject the `$(grep -c … || echo …)` antipattern (#1751).
#
# `grep -c` PRINTS its count (including "0") and EXITS 1 when there are no
# matches. So `count="$(grep -c PAT f || echo 0)"` produces the two-line string
# "0\n0" on the no-match path — and the next `(( count … ))` dies with
# "syntax error in expression", aborting the whole script under `set -e`.
# The bug only fires on the no-match branch, which is why it survives review
# and normal runs and then kills a scheduled job nobody is watching.
#
# The safe forms, all of which this linter accepts:
#   count="$(grep -c PAT f || true)"        # grep already printed the count
#   count=$(grep -c PAT f) || count=0       # assignment outside the substitution
#
# Scans scripts/ core/ plugins/ tests/ for *.sh. Excludes legacy-DoNotUse/ only (frozen
# upstream import, never run).
#
# #1969: test files used to be exempt, on the reasoning that a test asserting on
# the string result is not at risk of the arithmetic abort. That reasoning was
# incomplete. In a SPEC-tagged test the same expression produces an assertion
# that can never pass, and the acceptance gate escalates one such assertion into
# `not_passing_at_head` for EVERY SPEC bound to the file. That is what happened
# to plugins/tool/test/tests/test-test.sh:661 in run 32886585375: one typo, a
# 4-hour pipeline loss, and `lint: 1/1 passed` in the same report.
#
# A line that must keep the literal bad form (this linter's own fixtures) is
# marked `# lint-grep-c:allow`. It is a per-line, in-source opt-out — visible at
# the site, greppable, and impossible to widen silently the way a path rule is.
#
# Exit codes:
#   0 — no occurrences of the antipattern
#   1 — at least one occurrence (each is named with file:line)
#
# Usage:
#   bash scripts/lib/lint-grep-c.sh

set -euo pipefail

_SELF_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_REPO_ROOT="$(cd "$_SELF_DIR/../.." && pwd)"

# Roots may be overridden for testing against a fixture tree.
_SCAN_ROOTS=("${@:-}")
_SCAN_REPO_ROOT_TOPLEVEL=0
if [[ -z "${_SCAN_ROOTS[0]:-}" ]]; then
    _SCAN_ROOTS=("$_REPO_ROOT/scripts" "$_REPO_ROOT/core" "$_REPO_ROOT/plugins" "$_REPO_ROOT/tests")
    # Also the repo-root *.sh entrypoints (install.sh and friends). Scanned at
    # depth 1 only — recursing from the repo root would drag in node_modules,
    # .git and the frozen legacy-DoNotUse/ import for no benefit.
    _SCAN_REPO_ROOT_TOPLEVEL=1
fi

# A counting `grep` — the count flag in any cluster, or the GNU long form
# `--count` — followed by `|| echo` or `|| printf` in the same command, its
# output piped on or not. #2454: the check reads whole commands, not lines. A
# command continued with `\` is joined first, and single-quoted text (a jq
# filter, a grep pattern) is blanked, so brackets or pipes inside it cannot hide
# the bug. Six of #1805's assertions had exactly that shape, and a line-based
# rule that stopped at the first `)` passed them.
# Deliberately narrow: `|| true` and assignment-outside-substitution must both
# keep passing.
_SEG='([^;&|()]|>&)*'
_PATTERN="grep${_SEG}[[:space:]](-[a-zA-Z]*c[a-zA-Z]*|--count)([[:space:]]${_SEG})?(\\|[^|;&()]${_SEG})*\\|\\|[[:space:]]*(echo|printf)"

_failures=0

_collect_files() {
    local _r
    for _r in "${_SCAN_ROOTS[@]}"; do
        [[ -d "$_r" ]] || continue
        find "$_r" -name '*.sh' -type f -print0 2>/dev/null
    done
    if [[ "$_SCAN_REPO_ROOT_TOPLEVEL" -eq 1 ]]; then
        find "$_REPO_ROOT" -maxdepth 1 -name '*.sh' -type f -print0 2>/dev/null
    fi
}

# _scan <file>... — "file<TAB>line<TAB>command" for each offending command;
# line is where the command starts.
_scan() {
    _LGC_PAT="$_PATTERN" awk '
        # code(s) — s with the text inside quotes blanked: single-quoted text
        # (a jq filter, a grep pattern) and double-quoted text (a test title),
        # except a $( … ) inside double quotes, which is code. Brackets or pipes
        # inside quotes then cannot hide the bug or fake it.
        function code(s,   out, i, c, n, sp, st) {
            out = ""; sp = 0; st[0] = "N"; n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (st[sp] == "S") { if (c == "\047") sp--; continue }
                if (st[sp] == "D") {
                    if (c == "\\") { i++; continue }
                    if (c == "\"") { sp--; out = out "\""; continue }
                    if (c == "$" && substr(s, i + 1, 1) == "(") { st[++sp] = "C"; out = out "$("; i++ }
                    continue
                }
                if (c == "\\") { out = out substr(s, i, 2); i++; continue }
                if (c == "\047") { st[++sp] = "S"; out = out "\047\047"; continue }
                if (c == "\"") { st[++sp] = "D"; out = out "\""; continue }
                if (c == "(") st[++sp] = "C"
                else if (c == ")" && st[sp] == "C") sp--
                out = out c
            }
            return out
        }
        function check(   t) {
            if (cmd == "") return
            t = cmd; sub(/^[[:space:]]+/, "", t)
            # A comment describing the antipattern is not an instance of it,
            # and a marked command is the explicit per-line opt-out (#1969).
            if (t ~ /grep/ && t ~ /\|\|/ && t !~ /^#/ && t !~ /lint-grep-c:allow/) {
                if (code(t) ~ pat) printf "%s\t%d\t%s\n", fname, start, t
            }
            cmd = ""
        }
        BEGIN { pat = ENVIRON["_LGC_PAT"] }
        FNR == 1 { check(); fname = FILENAME }
        {
            line = $0
            if (cmd == "") start = FNR
            if (line ~ /\\$/) { sub(/\\$/, "", line); cmd = cmd line " "; next }
            cmd = cmd line
            check()
        }
        END { check() }' "$@" 2>/dev/null || true
}

_files=()
while IFS= read -r -d '' _file; do
    case "$_file" in
        */legacy-DoNotUse/*) continue ;;
    esac
    _files+=("$_file")
done < <(_collect_files)

if [[ ${#_files[@]} -gt 0 ]]; then
    while IFS=$'\t' read -r _file _lineno _text; do
        [[ -n "$_lineno" ]] || continue
        printf 'lint-grep-c: %s:%s — `grep -c … || echo` yields "0\\n0" on no-match; use `|| true`\n' \
            "${_file#"$_REPO_ROOT"/}" "$_lineno" >&2
        printf '    %s\n' "$_text" >&2
        _failures=$((_failures + 1))
    done < <(_scan "${_files[@]}")
fi

if [[ "$_failures" -gt 0 ]]; then
    printf '\nlint-grep-c: %d occurrence(s). `grep -c` already prints the count — replace `|| echo 0` with `|| true`.\n' \
        "$_failures" >&2
    exit 1
fi

printf 'lint-grep-c: OK — no grep -c || echo occurrences in scripts/ core/ plugins/ tests/\n'
exit 0
