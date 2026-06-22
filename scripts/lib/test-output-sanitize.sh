#!/usr/bin/env bash
# scripts/lib/test-output-sanitize.sh — LLM-prompt sanitizer (Wave 15-C #681; Wave 16-B #699)
#
# Strips framework decoration from arbitrary text that's about to be spliced
# into an LLM prompt. Original use case (Wave 15-C): captured test_output
# headed for the test plugin's truncation budget and the test_assessment
# prompt. Wave 16-B (#699) generalises the helper to the review prompt as
# well — plan/diff/scope-manifest/test-results text blocks all flow through
# the same redactor wrap (`<out-of-scope-context>` tags) and stage_io banner
# machinery, so the same 5 transforms cleanly remove framework decoration
# anywhere a text artifact gets spliced into an LLM prompt.
#
# Call sites (issue #721): test, test_assessment, review, build (_feedback_body
# + _review_feedback_body), plan (redacted_content), security-lens
# (redacted_content). All five plugins that splice potentially noisy pipeline
# artifact text into a prompt route it through _zbuild_sanitize_for_llm.
#
# The transforms delete only framework decoration; every byte of genuine
# content is preserved.
#
# Sourced library: no set -euo pipefail (would mutate caller options).

[[ -n "${_ZBUILD_TEST_OUTPUT_SANITIZE_LOADED:-}" ]] && return 0
_ZBUILD_TEST_OUTPUT_SANITIZE_LOADED=1

# _zbuild_sanitize_for_llm  (canonical entry point — Wave 16-B #699)
#
# Reads decorated text on stdin, applies 5 transforms, writes the cleaned
# output to stdout. Idempotent (sanitize ∘ sanitize == sanitize).
#
# Transforms (per #681):
#   1. <out-of-scope-context>X</out-of-scope-context> → X  (keep inner content)
#   2. Strip ══...══ and ── ... ── stage-io banner lines
#   3. Strip ═-only / ─-only decorative separator lines (90%+ box-drawing chars)
#   4. Strip \x1b[...m ANSI CSI sequences (color codes around ✓/✗)
#   5. Strip "↪ [N more lines · full at /path/x.json]" truncation-footer lines
#
# Preserves: ✓/✗ marks (after ANSI strip), test names, assertion messages,
# expected/got values, runner stdout/stderr, summary counts, exit codes,
# multi-line bash from genuine test failures, plan text, diff hunks, scope
# manifest entries.
#
# Usage: printf '%s' "$raw" | _zbuild_sanitize_for_llm
_zbuild_sanitize_for_llm() {
    # Pipeline order matters for correctness:
    #   1. sed strips ANSI CSI sequences across the whole stream first, so
    #      banner / separator pattern matches in step 2 are not foiled by
    #      color codes embedded between the box-drawing characters.
    #   2. awk processes the (now-ANSI-free) stream line-by-line. Per line
    #      it (a) strips <out-of-scope-context>…</out-of-scope-context>
    #      wrappers — multiple occurrences per line each strip independently;
    #      the inner content is assumed to not contain `<` so the wrapper
    #      shape stays self-contained on one line — (b) drops the truncation
    #      footer, (c) drops the ══/── stage-io banner pairs, and (d) drops
    #      decorative separators whose visible content is ≥ 90% `═`/`─`.
    # #830: LC_ALL=C makes sed/awk treat input as raw bytes rather than
    # locale-encoded characters. Without it, BSD sed (macOS) and GNU sed
    # (Linux under unset LANG) abort with "RE error: illegal byte sequence"
    # on any non-UTF-8 byte in npm test output (binary failure dumps,
    # escape-char fragments). POSIX command-prefix scoping means the
    # variable applies only to this child process; the caller's locale
    # is unaffected.
    LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g' | LC_ALL=C awk '
    {
        # Transform 1: strip <out-of-scope-context>…</out-of-scope-context>
        # wrappers, keep inner content. Repeat per line to catch multiple
        # occurrences (e.g. two wrapped paths on one assertion line).
        while (match($0, /<out-of-scope-context>[^<]*<\/out-of-scope-context>/)) {
            inner = substr($0, RSTART + 22, RLENGTH - 22 - 23)
            $0 = substr($0, 1, RSTART - 1) inner substr($0, RSTART + RLENGTH)
        }
        line = $0

        # Transform 5: truncation footer `↪ [N more lines · full at /path]`.
        if (line ~ /^↪ \[.*more lines.*full at.*\]$/) next

        # Transform 2: stage-io banner pairs `══ … ══` and `── … ──`.
        if (line ~ /^══.*══$/) next
        if (line ~ /^── .* ──$/) next

        # Transform 3: decorative separator — line is 90%+ ═ or ─.
        # Count box-drawing chars vs visible length (ignoring whitespace).
        stripped = line
        gsub(/[[:space:]]/, "", stripped)
        n = length(stripped)
        if (n >= 3) {
            heavy = stripped; gsub(/═/, "", heavy)
            light = stripped; gsub(/─/, "", light)
            if ((n - length(heavy)) * 10 >= n * 9) next
            if ((n - length(light)) * 10 >= n * 9) next
        }
        print line
    }
    '
}

# _zbuild_sanitize_test_output — Wave 15-C name, kept as a back-compat alias.
# Wave 16-B (#699) renamed the canonical entry point to _zbuild_sanitize_for_llm
# because the helper is general (not test-specific). Existing call sites in the
# test plugin and the test_assessment plugin continue to work unchanged.
_zbuild_sanitize_test_output() {
    _zbuild_sanitize_for_llm "$@"
}
