#!/usr/bin/env bash
# scripts/lib/lint-bare-timeout.sh — every timeout bound goes through one helper
# (#1752, ADR-036 amendment 2026-10-09).
#
# macOS has no `timeout` (Homebrew's coreutils installs `gtimeout` only), so a
# bare `timeout` call runs its command unbounded or not at all there — how the
# #2113 false `inert_build` shipped. The fix was six hand-copied "gtimeout, else
# timeout" probes; this lint keeps a seventh from appearing. In core/, scripts/
# and plugins/ (not legacy/) it fails on:
#   - a bare `timeout`/`gtimeout` call, in any command position
#   - a hand-written probe (`command -v`, `type -P`, `hash`, `which` of either
#     name) outside scripts/lib/timeout-cmd.sh — the old shape, which calls
#     nothing bare and so would pass the first check
# Use `_acceptance_timeout_prefix` (scripts/lib/timeout-cmd.sh) instead.
#
# Comments, quoted text, heredoc bodies and names like `timeout_secs` or
# `--timeout` are not calls. A line may opt out with
#   # lint-bare-timeout:allow: <reason>
# and the reason is required.
#
# Not scanned: scripts/lib/test-helpers.sh — its `timeout` is a test-only mock
# (a fake binary written for tests, probed with `command -v timeout`), not a
# bound on engine work.
#
# Usage: bash scripts/lib/lint-bare-timeout.sh [repo_root]
# Exit:  0 clean; 1 one or more findings (each printed as file:line: text).
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

files=()
for d in core scripts plugins; do
    [[ -d "$ROOT/$d" ]] || continue
    while IFS= read -r -d '' f; do
        case "${f#"$ROOT"/}" in
            scripts/lib/test-helpers.sh) continue ;;  # test-only mock, see header
        esac
        files+=("$f")
    done < <(find "$ROOT/$d" -name '*.sh' -not -path '*/legacy/*' -print0)
done
(( ${#files[@]} > 0 )) || exit 0

# The awk pass blanks quoted text (keeping $(...) inside double quotes, which
# runs), drops comments and heredoc bodies, then looks for the two shapes.
findings="$(awk -v root="$ROOT/" '
function reset() { depth = 0; ctx[0] = "N"; par[0] = 0; hd = "" }
FNR == 1 { reset() }
{
    raw = $0
    if (hd != "") {
        t = raw; if (hd_tabs) sub(/^\t+/, "", t)
        if (t == hd) hd = ""
        next
    }
    allowed = (raw ~ /lint-bare-timeout:allow:[ \t]*[^ \t]/)
    code = ""; n = length(raw)
    for (i = 1; i <= n; i++) {
        c = substr(raw, i, 1); c2 = substr(raw, i, 2); top = ctx[depth]
        if (top == "S") { if (c == "\047") depth--; code = code " "; continue }
        if (top == "D") {
            if (c == "\\") { i++; code = code "  "; continue }
            if (c == "\"") { depth--; code = code " "; continue }
            if (c2 == "$(") { depth++; ctx[depth] = "C"; par[depth] = 0; code = code c2; i++; continue }
            code = code " "; continue
        }
        # N (top level) or C (inside $(...))
        if (c == "\\") { code = code substr(raw, i, 2); i++; continue }
        if (c == "#" && (i == 1 || substr(raw, i - 1, 1) ~ /[ \t;]/)) break
        if (c == "\047") { depth++; ctx[depth] = "S"; code = code " "; continue }
        if (c == "\"") { depth++; ctx[depth] = "D"; code = code " "; continue }
        if (c2 == "$(") { depth++; ctx[depth] = "C"; par[depth] = 0; code = code c2; i++; continue }
        if (c == "(") par[depth]++
        if (c == ")") { if (par[depth] > 0) par[depth]--; else if (top == "C") depth-- }
        code = code c
    }
    # A heredoc starts after this line; its body is text, not code.
    if (match(raw, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/) && substr(raw, RSTART, 3) != "<<<") {
        h = substr(raw, RSTART, RLENGTH); hd_tabs = (h ~ /^<<-/)
        gsub(/^<<-?[ \t]*|[\047"]/, "", h); hd = h
    }
    if (allowed) next
    rel = FILENAME; if (index(rel, root) == 1) rel = substr(rel, length(root) + 1)
    if (rel != "scripts/lib/timeout-cmd.sh" &&
        code ~ /(command[ \t]+-v|type[ \t]+-P|hash|which)[ \t]+g?timeout([ \t;|&)]|$)/) {
        printf "%s:%d: hand-written timeout probe (use _acceptance_timeout_prefix): %s\n", rel, FNR, raw
        next
    }
    rest = code; off = 0
    while (match(rest, /g?timeout/)) {
        s = off + RSTART; e = s + RLENGTH
        before = substr(code, 1, s - 1); after = substr(code, e, 1)
        prev = (s > 1) ? substr(code, s - 1, 1) : ""
        off = e - 1; rest = substr(code, e)
        if (prev ~ /[A-Za-z0-9_.\/-]/ || (after != "" && after !~ /[ \t]/)) continue
        sub(/[ \t]+$/, "", before)
        if (before == "" || before ~ /([;&|(!{`]|\$\()$/ ||
            before ~ /(^|[ \t;&|(])(then|do|else|elif|if|while|until|exec|command|nohup|env|time|xargs|sudo)$/) {
            printf "%s:%d: bare timeout call (use _acceptance_timeout_prefix): %s\n", rel, FNR, raw
            break
        }
    }
}' "${files[@]}")"

if [[ -n "$findings" ]]; then
    printf '%s\n' "$findings" >&2
    echo "lint-bare-timeout: build the bound with _acceptance_timeout_prefix (scripts/lib/timeout-cmd.sh), or mark the line '# lint-bare-timeout:allow: <reason>'" >&2
    exit 1
fi
exit 0
