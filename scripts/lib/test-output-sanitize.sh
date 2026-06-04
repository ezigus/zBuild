#!/usr/bin/env bash
# scripts/lib/test-output-sanitize.sh — test_output sanitizer (Wave 15-C, #681)
#
# Strips framework decoration from captured test runner output before it lands
# in (a) the test plugin's 10KB truncation budget and (b) the test_assessment
# LLM prompt splice. Per #681 the dogfood prompts were ~200 lines of decoration
# wrapping ~5 lines of signal — banner pairs, redaction-tag wrappers, ANSI,
# decorative separators, and a truncation footer pointing at a file the LLM
# cannot read. The transforms here delete only the framework decoration and
# preserve every byte of genuine runner stdout/stderr.
#
# Sourced library: no set -euo pipefail (would mutate caller options).

[[ -n "${_ZBUILD_TEST_OUTPUT_SANITIZE_LOADED:-}" ]] && return 0
_ZBUILD_TEST_OUTPUT_SANITIZE_LOADED=1

# _zbuild_sanitize_test_output
#
# Reads test_output text on stdin, applies 5 transforms, writes the cleaned
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
# expected/got values, runner stdout/stderr, summary counts, exit codes, and
# multi-line bash from genuine test failures.
#
# Usage: printf '%s' "$raw" | _zbuild_sanitize_test_output
_zbuild_sanitize_test_output() {
    # Transform 1 (wrapper strip) is applied first via awk so it can span
    # lines if needed. The remaining four transforms are per-line and chain
    # through sed. The wrapper regex is non-greedy enough for the realistic
    # inline-path shape `<out-of-scope-context>/abs/path</out-of-scope-context>`
    # — multiple occurrences on one line each strip independently.
    # Step 1: strip ANSI first so banner/separator pattern matches aren't
    # foiled by embedded color codes between the box-drawing characters.
    # Step 2: awk handles transforms 1, 2, 3, 5 (wrapper-strip + line drops
    # with a 90% threshold for decorative separators).
    sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g' | awk '
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
