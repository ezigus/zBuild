#!/usr/bin/env bash
# plugins/agent/intake/lib/requirements.sh — the issue's requirements as one
# fixed, engine-numbered list (#2306, ADR-070 §1, §2).
#
# Every later stage reads this list instead of re-reading the issue's prose for
# itself. The ids are R-1, R-2, … in the order the issue lists them, assigned
# here: no identifier is taken from the issue's words (on #2035, "SPEC-2" in the
# issue meant a test label, and three stages read it as design's own SPEC-2).

[[ -n "${_ZBUILD_INTAKE_REQUIREMENTS_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_REQUIREMENTS_LOADED=1

# _intake_requirements_json <issue_json> — prints requirements.json for an issue
# fetched as {title, body}. Source: every checkbox line (`- [ ]` / `- [x]`, any
# bullet, any indent, under any heading) outside a code fence, its words kept
# as written with control characters removed. With no checkbox, R-1 is the
# title and the body's first paragraph, and "source" says "title".
_intake_requirements_json() {
    jq -c '
        def clean: gsub("[[:cntrl:]]"; " ") | gsub("^\\s+|\\s+$"; "");
        (.title // "" | clean) as $title
        | ((.body // "") | gsub("\r"; "") | split("\n")) as $lines
        | [ foreach $lines[] as $l ({fence: false, out: null};
              if ($l | test("^\\s*(```|~~~)")) then {fence: (.fence | not), out: null}
              elif .fence then {fence: true, out: null}
              else {fence: false,
                    out: ([$l | capture("^\\s*[-*+]\\s+\\[[ xX]\\]\\s+(?<t>.*\\S)\\s*$") | .t] | .[0])}
              end;
              .out)
            | select(. != null) | clean | select(length > 0) ] as $boxes
        | if ($boxes | length) > 0 then
              {schema_version: 1, source: "checkboxes",
               requirements: [$boxes | to_entries[] | {id: "R-\(.key + 1)", text: .value}]}
          else
              ([ ($lines | join("\n")) | split("\n\n")[] | gsub("\n"; " ") | clean
                 | select(length > 0) ] | .[0] // "") as $para
              | {schema_version: 1, source: "title",
                 requirements: [{id: "R-1",
                                 text: (if $para == "" then $title else $title + ": " + $para end)}]}
          end' <<< "${1:-}"
}

# _intake_write_requirements <artifact_dir> <issue_json> — writes
# <artifact_dir>/requirements.json. rc 1 when it cannot be built or written.
_intake_write_requirements() {
    local art="${1:-}" json
    [[ -n "$art" ]] || return 1
    json="$(_intake_requirements_json "${2:-}" 2>/dev/null)" && [[ -n "$json" ]] || return 1
    atomic_write "$art/requirements.json" <<< "$json"
}
