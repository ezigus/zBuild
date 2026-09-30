#!/usr/bin/env bash
# scripts/lib/manifest-valid-verdicts.sh — read a manifest's
# config.valid_verdicts. Shared by the runtime reader (core/pipeline/verdict.sh,
# #2242: an undeclared verdict fails the stage) and the lints (lint-verdict-
# classify, lint-verdict-words), so the three read the same list the same way.

[[ -n "${_ZBUILD_MANIFEST_VALID_VERDICTS_LOADED:-}" ]] && return 0
_ZBUILD_MANIFEST_VALID_VERDICTS_LOADED=1

# manifest_valid_verdicts_state <manifest> → one line:
#   absent            — no valid_verdicts key anywhere in the manifest
#   empty             — declared as an explicit inline [] (or a key with no items)
#   list <v1> <v2> …  — declared block list or flow sequence
# Scoped to the `config:` block so an unrelated key elsewhere cannot satisfy it.
manifest_valid_verdicts_state() {
    awk '
        /^config:[[:space:]]*$/ { in_cfg=1; next }
        in_cfg && /^[a-zA-Z_]/  { in_cfg=0 }
        in_cfg && /^[[:space:]]*valid_verdicts:/ {
            found=1
            # Inline form: valid_verdicts: []  (or any inline scalar/flow value)
            line=$0
            sub(/^[[:space:]]*valid_verdicts:[[:space:]]*/, "", line)
            if (line ~ /^\[[[:space:]]*\]$/) { inline_empty=1 }
            else if (line != "") { inline_other=line }
            in_list=1
            next
        }
        # Items of the block list: "    - value"
        in_cfg && in_list && /^[[:space:]]+-[[:space:]]*[^[:space:]]/ {
            v=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v)      # strip trailing comment
            gsub(/[[:space:]]*$/, "", v)
            if (v != "") { vals[n++]=v }
            next
        }
        # A comment line inside the list does not end it.
        in_cfg && in_list && /^[[:space:]]*#/ { next }
        # Any other key at config-item depth ends the list.
        in_cfg && in_list && /^[[:space:]]+[^-[:space:]]/ { in_list=0 }
        END {
            if (!found) { print "absent"; exit }
            if (n > 0) {
                printf "list"
                for (i = 0; i < n; i++) printf " %s", vals[i]
                printf "\n"
                exit
            }
            if (inline_empty || inline_other == "") { print "empty"; exit }
            # YAML flow sequence: `valid_verdicts: [pass, fail]`. Valid YAML, so
            # parse it rather than reject it — passing the raw "[pass, fail]"
            # through would word-split into "[pass," and "fail]", and BOTH would
            # classify unknown, failing a structurally correct manifest.
            if (inline_other ~ /^\[.*\]$/) {
                sub(/^\[[[:space:]]*/, "", inline_other)
                sub(/[[:space:]]*\]$/, "", inline_other)
                gsub(/[[:space:]]*,[[:space:]]*/, " ", inline_other)
                gsub(/["'"'"']/, "", inline_other)
                if (inline_other == "") { print "empty"; exit }
            }
            print "list " inline_other
        }
    ' "$1"
}

# manifest_verdict_declared <manifest> <word> — rc 0 when <word> is in the
# declared list, rc 1 when a list is declared and <word> is not in it, rc 2 when
# the manifest declares no list (nothing to check against).
manifest_verdict_declared() {
    local state w
    state="$(manifest_valid_verdicts_state "$1" 2>/dev/null)"
    [[ "$state" == list\ * ]] || return 2
    for w in ${state#list }; do
        [[ "$w" == "$2" ]] && return 0
    done
    return 1
}
