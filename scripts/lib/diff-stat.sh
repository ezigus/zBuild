#!/usr/bin/env bash
# scripts/lib/diff-stat.sh — diff-stat summary block for LLM prompts (Wave 16-B, #699)
#
# Emits a compact, structure-first summary of a unified patch so the LLM sees
# "what changed" before being asked to wade through the full hunks. The block
# is inserted at the TOP of the review prompt (before plan/diff content) so
# the model orients on file count + per-file churn first.
#
# Format:
#   ## Changed files (<N> total, +<adds> -<dels>)
#   <path>                                              +<adds> -<dels>
#   <path>                                              +<adds> -<dels>
#
# Paths are bare. Wave 12-B made diff.patch branch-cumulative and in-scope-only
# (the redactor strips out-of-scope hunks upstream), so no <out-of-scope-context>
# wrappers can appear in numstat input here.
#
# Sourced library: no set -euo pipefail (would mutate caller options).

[[ -n "${_ZBUILD_DIFF_STAT_LOADED:-}" ]] && return 0
_ZBUILD_DIFF_STAT_LOADED=1

# _zbuild_diff_stat <patch_file>
#
# Reads <patch_file> via `git apply --numstat -` and emits the summary block
# on stdout. Empty / missing / unparseable patch → "## Changed files (0 total)".
# Never fails (always returns 0); callers can splice the output unconditionally.
_zbuild_diff_stat() {
    local patch_file="${1:-}"

    if [[ -z "$patch_file" || ! -s "$patch_file" ]]; then
        printf '## Changed files (0 total)\n'
        return 0
    fi

    # `git apply --numstat -` works without a working tree and parses any
    # unified diff. Binary files get `-\t-\t<path>` which we surface as `bin`.
    local numstat
    numstat="$(git apply --numstat - < "$patch_file" 2>/dev/null || true)"

    if [[ -z "$numstat" ]]; then
        printf '## Changed files (0 total)\n'
        return 0
    fi

    # Two passes: (1) compute totals + the widest path column for alignment,
    # (2) format each row. awk keeps the implementation single-process.
    printf '%s\n' "$numstat" | awk '
        BEGIN { files = 0; tot_add = 0; tot_del = 0; max_path = 0 }
        # numstat row: <adds>\t<dels>\t<path>   (adds/dels can be "-" for binary)
        NF >= 3 {
            files++
            add = $1; del = $2
            # Reconstruct path field (may legitimately contain whitespace, but
            # numstat tab-separates so $3..NF works).
            path = $3
            for (i = 4; i <= NF; i++) path = path " " $i

            if (add == "-") { add_n[files] = "bin" } else { add_n[files] = add; tot_add += add + 0 }
            if (del == "-") { del_n[files] = "bin" } else { del_n[files] = del; tot_del += del + 0 }
            paths[files] = path
            if (length(path) > max_path) max_path = length(path)
        }
        END {
            if (files == 0) {
                print "## Changed files (0 total)"
                exit 0
            }
            # Header: include signed totals when at least one numeric file
            # contributed (binary-only diffs would have tot_add=tot_del=0;
            # still emit the line — operator can tell from "bin" markers).
            printf "## Changed files (%d total, +%d -%d)\n", files, tot_add, tot_del
            # Pad path to max_path + 2 spaces; right-align +N/-N as fixed-width
            # columns so the eye lands on the per-file churn quickly.
            col = max_path + 2
            for (i = 1; i <= files; i++) {
                printf "%-*s +%-4s -%s\n", col, paths[i], add_n[i], del_n[i]
            }
        }
    '
}
