#!/usr/bin/env bash
# scripts/migrate-template-v2.sh — Convert legacy template YAML (v1) to inline
# cycle syntax (v2) per issue #585 / ADR-021 v2.
#
# Usage:
#   scripts/migrate-template-v2.sh <template.yaml> [--in-place] [--no-backup]
#
# Behavior:
#   - Reads the input template.
#   - If no top-level `cycles:` block found → no-op, exits 0 ("already migrated").
#   - Otherwise: hoists each cycle's member stages into a new top-level
#     `stage_definitions:` map, replaces them in the `stages:` list with one
#     inline `- id: <cycle_id>; type: cycle; …` entry, and drops the legacy
#     `cycles:` block.
#   - Default: writes output to stdout. With --in-place: writes back to file
#     (creates .bak unless --no-backup).
#
# Idempotency: rerunning on a v2 file is a no-op (no `cycles:` block → exit 0).
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <template.yaml> [--in-place] [--no-backup]
EOF
    exit 2
}

[[ $# -lt 1 ]] && usage

FILE=""
IN_PLACE=0
BACKUP=1
for arg in "$@"; do
    case "$arg" in
        --in-place)  IN_PLACE=1 ;;
        --no-backup) BACKUP=0 ;;
        -h|--help)   usage ;;
        -*)          echo "unknown flag: $arg" >&2; usage ;;
        *)
            if [[ -z "$FILE" ]]; then FILE="$arg"
            else echo "extra arg: $arg" >&2; usage
            fi
            ;;
    esac
done

[[ -z "$FILE" ]] && usage
[[ ! -f "$FILE" ]] && { echo "migrate-template-v2: file not found: $FILE" >&2; exit 1; }

OUT="$(awk '
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function indent_of(line,    n) { n = 0; while (substr(line, n+1, 1) == " ") n++; return n }
function compute_block_end(start,    j, last, ll) {
    if (start == 0) return 0
    last = start
    for (j = start + 1; j <= NR; j++) {
        ll = lines[j]
        if (ll ~ /^[a-zA-Z_]/) break
        if (ll ~ /^[[:space:]]/ || ll == "") last = j
    }
    while (last > start && lines[last] == "") last--
    return last
}

# Phase 1: read whole file into lines[], detect blocks.
{ lines[NR] = $0 }

END {
    # Pass A: locate top-level stages: and cycles: lines.
    # Block "content" extends from the header line up to the LAST indented
    # (or blank) line before the next top-level non-comment key. Comment
    # blocks ("#…") between blocks are treated as belonging to neither block
    # so the migration preserves them in their original position.
    stages_start = 0; stages_end = 0
    cycles_start = 0; cycles_end = 0
    for (i = 1; i <= NR; i++) {
        l = lines[i]
        if (l ~ /^stages:[[:space:]]*$/) { stages_start = i; continue }
        if (l ~ /^cycles:[[:space:]]*$/) { cycles_start = i; continue }
    }
    stages_end = compute_block_end(stages_start)
    cycles_end = compute_block_end(cycles_start)

    # Idempotency: no legacy cycles: block → emit input verbatim.
    if (cycles_start == 0) {
        for (i = 1; i <= NR; i++) print lines[i]
        exit 0
    }

    # Pass B: collect stage blocks. A "stage block" starts at a "  - id: X" line
    # within stages_start..stages_end and continues until the next "  - id:" or
    # outside the stages section.
    n_stages = 0
    for (i = stages_start + 1; i <= stages_end; i++) {
        l = lines[i]
        if (l ~ /^[[:space:]]*-[[:space:]]*id:/) {
            n_stages++
            stage_idx[n_stages] = i
            sid = l
            sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", sid)
            sid = trim(sid)
            stage_id[n_stages] = sid
        }
    }
    for (k = 1; k <= n_stages; k++) {
        start = stage_idx[k]
        if (k < n_stages) end = stage_idx[k+1] - 1
        else end = stages_end
        stage_start_line[k] = start
        stage_end_line[k]   = end
    }

    # Pass C: collect cycles. Each cycle has: cid, member stages list, and the
    # contiguous block of raw lines from "  - id: cid" to end of cycle entry.
    n_cycles = 0
    cur_cycle = 0
    for (i = cycles_start + 1; i <= cycles_end; i++) {
        l = lines[i]
        if (l ~ /^[[:space:]]*-[[:space:]]*id:/) {
            if (cur_cycle > 0) cycle_end_line[cur_cycle] = i - 1
            n_cycles++
            cur_cycle = n_cycles
            cid = l
            sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", cid)
            cycle_id[cur_cycle] = trim(cid)
            cycle_start_line[cur_cycle] = i
        }
    }
    if (cur_cycle > 0) cycle_end_line[cur_cycle] = cycles_end

    # Pass D: extract member stages from each cycles cycle. Look for
    # "    stages: [a, b, c]" or multiline.
    for (c = 1; c <= n_cycles; c++) {
        members = ""
        in_list = 0
        for (i = cycle_start_line[c]; i <= cycle_end_line[c]; i++) {
            l = lines[i]
            if (l ~ /^[[:space:]]+stages:[[:space:]]*\[/) {
                tmp = l
                sub(/^[^[]*\[/, "", tmp)
                sub(/\].*$/, "", tmp)
                gsub(/[[:space:]]/, "", tmp)
                members = tmp
                in_list = 0
                continue
            }
            if (l ~ /^[[:space:]]+stages:[[:space:]]*$/) { in_list = 1; continue }
            if (in_list && l ~ /^[[:space:]]+-[[:space:]]/) {
                tmp = l; sub(/^[[:space:]]+-[[:space:]]+/, "", tmp); tmp = trim(tmp)
                members = (members == "" ? tmp : members "," tmp)
                continue
            }
            if (in_list && l ~ /^[[:space:]]+[a-z_]+:/) { in_list = 0 }
        }
        cycle_members[c] = members
    }

    # Compute: for each stage_idx, which cycle does it belong to (if any)?
    for (k = 1; k <= n_stages; k++) stage_in_cycle[k] = 0
    for (c = 1; c <= n_cycles; c++) {
        n = split(cycle_members[c], mem, /,/)
        for (j = 1; j <= n; j++) {
            mid = mem[j]
            for (k = 1; k <= n_stages; k++) {
                if (stage_id[k] == mid) {
                    stage_in_cycle[k] = c
                    stage_pos_in_cycle[k] = j
                }
            }
        }
    }

    # ── Emit output ───────────────────────────────────────────────────────────
    # Lines BEFORE stages:
    for (i = 1; i < stages_start; i++) print lines[i]

    # stages: header
    print "stages:"

    # Walk stages in order. When we hit a cycle member at pos=1, emit the inline
    # cycle block (built from the cycles entry). Skip non-first cycle members.
    for (k = 1; k <= n_stages; k++) {
        c = stage_in_cycle[k]
        if (c == 0) {
            for (i = stage_start_line[k]; i <= stage_end_line[k]; i++) print lines[i]
        } else if (stage_pos_in_cycle[k] == 1) {
            emit_inline_cycle(c)
        }
        # else: absorbed member, skip
    }

    # Skip the cycles: block when reprinting tail.

    # Emit stage_definitions for cycle members
    if (n_cycles > 0) {
        print ""
        print "stage_definitions:"
        for (c = 1; c <= n_cycles; c++) {
            n = split(cycle_members[c], mem, /,/)
            for (j = 1; j <= n; j++) {
                mid = mem[j]
                for (k = 1; k <= n_stages; k++) {
                    if (stage_id[k] == mid) {
                        emit_stage_def(k, mid)
                    }
                }
            }
        }
    }

    # Lines AFTER stages and cycles blocks (e.g., comments, other top-level keys)
    for (i = stages_end + 1; i <= NR; i++) {
        if (i >= cycles_start && i <= cycles_end) continue
        print lines[i]
    }
}

# Emit a single inline cycle entry derived from cycles[c] raw lines.
# Mechanical re-indent: cycle metadata lines from cycles: block are 2-space
# indented under "  - id:"; we re-emit at the same indent under stages:.
function emit_inline_cycle(c,    i, l) {
    for (i = cycle_start_line[c]; i <= cycle_end_line[c]; i++) {
        l = lines[i]
        if (i == cycle_start_line[c]) {
            print l
            print "    type: cycle"
        } else {
            print l
        }
    }
}

function emit_stage_def(k, mid,    i, l, indent, want_indent) {
    print "  " mid ":"
    # Re-indent the body of stage k under "  <mid>:". Original indent is 4
    # spaces (stage body); we want 4 spaces under stage_definitions root.
    for (i = stage_start_line[k] + 1; i <= stage_end_line[k]; i++) {
        l = lines[i]
        # Preserve content; just keep indent as-is (already 4 spaces under "  - id:").
        # Strip leading 2 spaces? Original: "    roles: [..]" (4 spaces). New
        # form under stage_definitions: "  build:\n    roles: [..]" — same 4
        # spaces. So no change needed.
        print l
    }
}
' "$FILE")"

if [[ $IN_PLACE -eq 1 ]]; then
    [[ $BACKUP -eq 1 ]] && cp "$FILE" "${FILE}.bak"
    printf '%s\n' "$OUT" > "$FILE"
else
    printf '%s\n' "$OUT"
fi
