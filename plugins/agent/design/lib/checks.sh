#!/usr/bin/env bash
# plugins/agent/design/lib/checks.sh — design's scripted checks of its own
# design.md (#2369, ADR-040, ADR-046; was the design-gate stage, #1218).
#
# No model, nothing executed: every check reads design.md and the files it
# names. _design_checks reports ALL violations in one pass; a design with any
# cannot be used, and the engine runs design again, handed them (ADR-068 §10).
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_DESIGN_CHECKS_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_CHECKS_LOADED=1
# shellcheck source=../../../../scripts/lib/test-paths.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../../scripts/lib/test-paths.sh"
# shellcheck source=../../../../scripts/lib/item-ids.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/item-ids.sh"
_DCK_LIB_DIR="${BASH_SOURCE[0]%/*}/../../../../scripts/lib"

# _dck_scope_nonempty <design_md>
# C1: returns 0 iff design.md carries a ```scope fence with ≥1 non-blank entry.
_dck_scope_nonempty() {
    local design_md="${1:-}"
    [[ -f "$design_md" ]] || return 1
    local in_scope=0 entries=0 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        # #1227: tolerate a trailing-whitespace fence (mirrors the design
        # stage's grep -q prefix match) so a fence line with a trailing space
        # does not falsely trip SCOPE_MISSING.
        if [[ "$line" == '```scope' || "$line" == '```scope'[[:space:]]* ]]; then in_scope=1; continue; fi
        if [[ $in_scope -eq 1 && "$line" == '```'* ]]; then break; fi
        if [[ $in_scope -eq 1 && -n "${line//[[:space:]]/}" ]]; then entries=$((entries + 1)); fi
    done < "$design_md"
    [[ $entries -gt 0 ]]
}

# _dck_evidence_v <var> <repo_root> <item> <base> — what is wrong with one
# evidence item of a [done] requirement (ADR-069 §2), or empty. #2462: [done]
# means the code from before the change already does it, so the item is
# `file:"exact text"` whose text is in the file on the base commit and still in
# it outside what this branch changed — or a test file named alone that the
# base commit has. Never a line number: lines move as the change is made. With
# no base commit (none resolves), the text in the file is all that is checked.
#   LINE     a line number      BAD       not a file in the repository
#   NO_TEXT  a source file named alone    MISSING   the text is not in it
#   NOT_BEFORE  not on the base commit, or only in lines this branch changed
_dck_evidence_v() {
    local -n _dev="$1"; local root="$2" item="$3" base="$4" path txt n src occ ranges a c l ok=0
    _dev=""
    acceptance_evidence_split "$item" path txt n
    [[ -n "$n" ]] && { _dev=LINE; return 0; }
    [[ -n "$path" && "$path" != /* && "/$path/" != *"/../"* && -f "$root/$path" ]] || { _dev=BAD; return 0; }
    if [[ -z "$txt" ]]; then
        zb_is_test_path "$path" "$root" || { _dev=NO_TEXT; return 0; }
        [[ -z "$base" ]] || git -C "$root" cat-file -e "$base:$path" 2>/dev/null || _dev=NOT_BEFORE
        return 0
    fi
    src="$(<"$root/$path")"
    [[ "$src" == *"$txt"* ]] || { _dev=MISSING; return 0; }
    [[ -n "$base" ]] || return 0
    [[ "$(git -C "$root" show "$base:$path" 2>/dev/null)" == *"$txt"* ]] || { _dev=NOT_BEFORE; return 0; }
    # The lines this branch added or changed: each hunk's "+start,count".
    ranges="$(git -C "$root" diff -U0 --no-color "$base" -- "$path" 2>/dev/null \
        | sed -nE 's/^@@ [^+]*\+([0-9]+)(,([0-9]+))? @@.*/\1 \3/p')"
    occ=0
    while IFS= read -r l; do
        occ=$((occ + 1))
        [[ "$l" == *"$txt"* ]] || continue
        ok=1
        while read -r a c; do
            [[ -n "$a" ]] || continue
            c="${c:-1}"
            (( occ >= a && occ < a + c )) && { ok=0; break; }
        done <<< "$ranges"
        (( ok )) && return 0
    done <<< "$src"
    _dev=NOT_BEFORE
}

# _dck_block_ids_v <ids_var> <removed_var> <block> — the SPEC ids, and the ids
# of the REMOVED lines, of an extracted acceptance block, space separated. Read
# by the shell: design's checks run on every try.
_dck_block_ids_v() {
    local -n _dbi="$1" _dbr="$2"; local _l re
    re="^REMOVED:[[:space:]]*(${_ACCEPTANCE_ID_ERE})"
    _dbi="" _dbr=""
    while IFS= read -r _l; do
        [[ "$_l" == "TESTFILES:" ]] && break
        if [[ "$_l" =~ $_ACCEPTANCE_SPEC_RE ]]; then _dbi+="${BASH_REMATCH[1]} "
        elif [[ "$_l" =~ $re ]]; then _dbr+="${BASH_REMATCH[1]} "; fi
    done <<< "$3"
    return 0
}

# _dck_bad_id_lines_v <array> <design_md> — each acceptance-block line (before
# TESTFILES) shaped like a SPEC line whose id has no valid form (#2462): such a
# line is otherwise read as words of the SPEC before it.
_dck_bad_id_lines_v() {
    local -n _dbl="$1"; local l in=0 re='^([A-Za-z][A-Za-z0-9_]*-[0-9]+)(\[[a-z-]+\])?:'
    _dbl=()
    while IFS= read -r l; do
        [[ "$l" == '```acceptance' ]] && { in=1; continue; }
        (( in )) || continue
        [[ "$l" == '```' || "$l" == TESTFILES: ]] && break
        [[ "$l" =~ $re ]] || continue
        local _id="${BASH_REMATCH[1]}"
        [[ "$l" =~ $_ACCEPTANCE_SPEC_RE ]] || _dbl+=("$_id")
    done < "$2"
    return 0
}

# _dck_describes_contents <text> — rc 0 when a requirement's words only
# say what a file contains or that it exists (#2305, ADR-069 §9). Such a
# requirement fails before the change and passes after it, so it satisfies the
# fail-first rule while proving nothing about behaviour. All three must hold:
#   - it names a file: a path with / or a source extension, or the word file,
#     manifest, source, script or function;
#   - it uses a contents verb: contains, defines, declares, exists, is/are
#     present, has a … key/field/entry/function, greps;
#   - it has no behaviour word: returns, emits, writes, fails, prints, exits,
#     rejects, skips, stops, runs, refuses, outputs, logs, calls, reports,
#     passes, creates, removes, produces, reads, sends (any ending), or when, if,
#     whenever, unless, given.
# Text inside backticks or double quotes is a quoted name, not a verb, so it is
# dropped before the verbs are read. False positives block real designs: keep
# the lists tight.
_dck_describes_contents() {
    local raw="${1,,}" t
    local b='(^|[^a-z0-9_])' e='([^a-z0-9_]|$)'
    [[ "$raw" =~ ${b}([a-z0-9_.-]+/[a-z0-9_./-]+|[a-z0-9_-]+\.(sh|bash|ya?ml|json|md|py|js|ts|toml|txt)|files?|manifests?|source|scripts?|functions?)${e} ]] || return 1
    t="$raw"
    while [[ "$t" =~ ^(.*)\`[^\`]*\`(.*)$ ]]; do t="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; done
    while [[ "$t" =~ ^(.*)\"[^\"]*\"(.*)$ ]]; do t="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; done
    [[ "$t" =~ ${b}(contains?|defines?|declares?|exists?|greps?|(is|are)\ +present|(has|have)\ +(a|an|the)\ +([^ ]+\ +){0,3}(keys?|fields?|entry|entries|functions?))${e} ]] || return 1
    # A behaviour word is a word of its own: "fresh-run" names a case, it does
    # not say the code runs (#2474: #1805's BNDY-1 got through on it).
    local hb='(^|[^a-z0-9_-])' he='([^a-z0-9_-]|$)'
    [[ "$t" =~ ${hb}((return|emit|write|fail|print|exit|reject|skip|stop|run|refuse|output|log|call|report|pass|create|remove|produce|read|send)[a-z]*|written|wrote|ran|when|if|whenever|unless|given)${he} ]] && return 1
    return 0
}

# _dck_parts <id> <status> <parts> — C10 (#2467, ADR-073 §3): what is wrong
# with a SPEC's Given/When/Then, added to the caller's violations. A [code] or
# [done] SPEC needs them; a [no-code] one may have them, and they are then held
# to the same rules.
_dck_parts() {
    local _dp_id="$1" _dp_st="$2" _dp_raw="$3" _dp_q
    if [[ -z "$_dp_raw" ]]; then
        [[ "$_dp_st" == "code" || "$_dp_st" == "done" ]] \
            && violations+=("GWT_MISSING $_dp_id (no Given/When/Then)")
        return 0
    fi
    local -a _dp_parts=() _dp_probs=()
    acceptance_parts_v _dp_parts "$_dp_raw" _dp_probs
    for _dp_q in ${_dp_probs[@]+"${_dp_probs[@]}"}; do
        case "$_dp_q" in
            NO_WHEN)        violations+=("GWT_NO_WHEN $_dp_id (no When:)") ;;
            MANY_WHEN)      violations+=("GWT_MANY_WHEN $_dp_id (more than one When:)") ;;
            AND_AFTER_WHEN) violations+=("GWT_AND_AFTER_WHEN $_dp_id (an And: after the When:)") ;;
            AND_FIRST)      violations+=("GWT_AND_FIRST $_dp_id (an And: with no part above it)") ;;
            NO_THEN)        violations+=("GWT_NO_THEN $_dp_id (no Then:)") ;;
            "EMPTY "*)      violations+=("GWT_EMPTY_PART $_dp_id ${_dp_q#EMPTY } (no words)") ;;
        esac
    done
    return 0
}

# _dck_plain <violation> — the sentence design reads for one violation (#2269).
# The code stays in the result JSON (other code and tests read it); the feedback
# file says what to change, in the words design was given.
_dck_plain() {
    local v="$1" rest="${1#* }"
    local id="${rest%% *}" third="${rest#* }"; third="${third%% *}"
    case "$v" in
        SCOPE_MISSING*)      printf 'design.md has no scope block — add a ```scope block listing every file the change touches' ;;
        ACCEPTANCE_MISSING*) printf 'design.md has no readable ```acceptance block — add one with a line per requirement' ;;
        NO_STATUS*)          printf '%s has no status — tag it [code] if it needs code (its test fails on the code from before your change and passes after), [no-code] if it needs work that changes no behaviour (docs, a test, config or a refactor), or [done] if the code already does it (then name the evidence after " evidence: ")' "$id" ;;
        # The retired tag is named, not written: design would copy it back.
        "UNKNOWN_STATUS "*" [guard] "*) printf '%s carries the old guard tag, which is no longer a status — tag it [done] if the code already does it, naming the evidence after " evidence: ", or [code] if it needs code' "$id" ;;
        UNKNOWN_STATUS*)     printf '%s is tagged %s, which is not a status — tag it [code] if it needs code, [no-code] if it needs work that changes no behaviour, or [done] if the code already does it, naming the evidence after " evidence: "' "$id" "$third" ;;
        DONE_NO_EVIDENCE*)   printf '%s is marked [done] but names no evidence — end its line with " evidence: " and a file with an exact piece of its text (scripts/x.sh:"run_guard()"), or an existing test file, that shows the code already does it' "$id" ;;
        DONE_BAD_EVIDENCE*)  printf 'the evidence %s for %s does not point at the repository — name a file that exists, by its path from the repository root (no leading / and no ..), with an exact piece of its text: scripts/x.sh:"run_guard()"' "$third" "$id" ;;
        # #2462: [done] is done on the code from before the change, shown by text.
        DONE_LINE_EVIDENCE*) printf 'the evidence %s for %s names a line number, and line numbers move as the change is made — name an exact piece of the file'"'"'s text instead: scripts/x.sh:"run_guard()"' "$third" "$id" ;;
        DONE_NO_TEXT*)       printf 'the evidence %s for %s names a source file alone — add an exact piece of its text that shows the code already does it: %s:"run_guard()"' "$third" "$id" "$third" ;;
        DONE_TEXT_MISSING*)  printf 'the evidence %s for %s is not in that file — quote its text exactly' "$third" "$id" ;;
        DONE_NOT_BEFORE*)    printf '%s is marked [done], but its evidence %s is not in the code from before this change — this branch added or changed it, so it is not done yet: tag %s [code] and give it a test' "$id" "$third" "$id" ;;
        ID_*)                zb_id_plain "$v" SPEC ;;
        CONTENTS_NOT_BEHAVIOUR*) printf '%s describes what a file contains, not what the code does — no test can prove that; describe the behaviour someone could observe (an input and what happens)' "$id" ;;
        MISSING_TESTFILE_FOR_SPEC*) printf '%s has no test file listed — add a "%s: <test file>" line under TESTFILES:' "$id" "$id" ;;
        "WIRING_MISSING ("*) printf 'the acceptance block does not say which existing file calls the new code — add a WIRING: line naming it, or WIRING: none if nothing calls it yet' ;;
        REQUIREMENT_NOT_COVERED*) local _rt="${rest#* (}"; _rt="${_rt%)}"
            # The requirement's own words go last, unquoted, so quotes inside them
            # cannot break the sentence (review #2320).
            printf 'requirement %s from the issue is not covered by any SPEC: %s. End the line of the SPEC that delivers it with " covers: %s" (before any " evidence: "), or add a SPEC for it; if the code already does it, a [done] SPEC with evidence covers it' "$id" "$_rt" "$id" ;;
        TESTFILE_NOT_A_TEST*) local _tg; zb_test_path_globs_v _tg
            printf '%s is named as a test, but it is not in a test folder (%s) — name a test file in one of them, or leave it out: a document or a source file is not a test' "$id" "${_tg// /, }" ;;
        WIRING_MISSING*)     printf 'the WIRING file %s does not exist — name a file that exists in the repository, or WIRING: none' "$id" ;;
        # #2467 (ADR-073 §1 §3): a SPEC's parts.
        GWT_MISSING*)        printf '%s is written on one line — rewrite it with its parts on the lines under it: Given: <the setup> (optional), When: <the one action>, Then: <what a test can observe> (one or more; And: adds another), and Cleanup: <what must be true again after> when the setup or a Then leaves something behind' "$id" ;;
        GWT_NO_WHEN*)        printf '%s has no When: line — add the one action that the test performs' "$id" ;;
        GWT_MANY_WHEN*)      printf '%s has more than one When: — one SPEC has one When, one action; split it into one SPEC per action' "$id" ;;
        GWT_AND_AFTER_WHEN*) printf '%s has an And: straight after its When:, which would be a second action — one SPEC has one When; put the extra setup under Given: or split the SPEC' "$id" ;;
        GWT_AND_FIRST*)      printf '%s starts its parts with And: — And: continues the Given:, Then: or Cleanup: above it' "$id" ;;
        GWT_NO_THEN*)        printf '%s has no Then: line — add what a test can observe after the When' "$id" ;;
        GWT_EMPTY_PART*)     local _gp="${rest#* }"; _gp="${_gp%% (*}"
            printf '%s has an empty %s — write what it says, or remove the line' "$id" "$_gp" ;;
        GWT_ORPHAN_PART*)    local _op="${rest#(}"; _op="${_op%)}"
            printf 'a part line is under no SPEC (%s) — put each Given:, When:, Then:, And: or Cleanup: line under the SPEC it belongs to' "$_op" ;;
        GWT_PART_ON_REMOVED*) printf '%s is removed, so it has no parts — remove the lines under its REMOVED line' "$id" ;;
        WIRING_IS_TEST*)     printf 'the WIRING file %s is one of your test files — a test is not what runs the change; name the file whose code calls the new code, or write WIRING: none' "$id" ;;
        *) printf '%s' "$v" ;;
    esac
}

# _design_checks <design_md> <repo_root> <requirements_json> [last_design] [issue_text]
# Fills _DESIGN_VIOLATIONS with one code per violation (C1..C5, C7, C9); empty
# when design.md passes. The requirements file is absent on a goal run;
# [last_design] is the last design that passed, [issue_text] the issue's words
# (the stage passes none: the requirement list carries the ids they write).
_design_checks() {
    local design_md="$1" repo_root="$2" req_json="${3:-}" last="${4:-}" _txt="${5:-}"
    _DESIGN_VIOLATIONS=()
    local -a violations=()
    local _covered=" " _base="" _base_done="" _evw="" _req_rows="" _req_codes="" _rr_k _rr_id _rr_t
    # The requirements, read once: "A<US>id<US>text" for each, "R<US>id" for
    # each removed one, "I<US>id" for each id the issue's words write — C7 reads
    # the first, C9 the codes of both and the issue's ids.
    if [[ -s "$req_json" ]]; then
        # Unit separator, not @tsv: @tsv would double every backslash in the
        # text (review #2320). Intake strips control characters, so it never occurs.
        _req_rows="$(jq -r '(.requirements[]? | "A\u001f" + .id + "\u001f" + (.text | gsub("[[:cntrl:]]"; " "))),
                            (.removed[]? | "R\u001f" + .id + "\u001f"),
                            (.issue_ids[]? | "I\u001f" + . + "\u001f")' "$req_json" 2>/dev/null || true)"
        while IFS=$'\x1f' read -r _rr_k _rr_id _rr_t; do
            [[ -n "$_rr_id" ]] || continue
            # #2462: the ids the issue's own words write, as intake recorded them.
            [[ "$_rr_k" == I ]] && { _txt+=" $_rr_id"; continue; }
            [[ "$_req_codes " != *" ${_rr_id%%-*} "* ]] && _req_codes+=" ${_rr_id%%-*}"
        done <<< "$_req_rows"
    fi

    # ── C1 SCOPE: non-empty ```scope block ──────────────────────────────────
    if ! _dck_scope_nonempty "$design_md"; then
        violations+=("SCOPE_MISSING (design.md has no non-empty \`\`\`scope block)")
    fi

    # ── C2 ACCEPTANCE: block present + parseable ─────────────────────────────
    local _accept_ok=0
    if [[ -f "$design_md" ]] && extract_acceptance_block "$design_md" >/dev/null 2>&1; then
        _accept_ok=1
    else
        violations+=("ACCEPTANCE_MISSING (design.md has no parseable \`\`\`acceptance block)")
    fi

    # ── C3 STATUS + C4 CODE-HAS-TESTFILE (#2304, ADR-069 §1–§3) ─────────────
    # Every requirement carries a status. [done] names evidence that exists, so
    # "already done" is a claim the gate can check, not a way to skip the red
    # step (#2035). Only a code requirement needs a test file of its own.
    if [[ $_accept_ok -eq 1 ]]; then
        local _blk _spec _ev _ev_n _na="" _nr=""
        _blk="$(extract_acceptance_block "$design_md" 2>/dev/null || true)"
        # The ids, read once from the block: C3 walks them, C9 checks them.
        _dck_block_ids_v _na _nr "$_blk"
        # C10: a part with no SPEC above it, or under a REMOVED line.
        local _bl _rre="^REMOVED:[[:space:]]*(${_ACCEPTANCE_ID_ERE})"
        while IFS= read -r _bl; do
            [[ "$_bl" == "TESTFILES:" ]] && break
            if [[ "$_bl" =~ $_ACCEPTANCE_PART_RE ]]; then
                violations+=("GWT_ORPHAN_PART (${_bl%%$'\x1f'*})")
            elif [[ "$_bl" =~ $_rre && "$_bl" == *$'\x1f'* ]]; then
                violations+=("GWT_PART_ON_REMOVED ${BASH_REMATCH[1]} (a part under a REMOVED line)")
            fi
        done <<< "$_blk"
        for _spec in $_na; do
            _acceptance_spec_line "$_blk" "$_spec" || continue
            _covered+="${_ACC_SPEC_COVERS//,/ } "
            # ── C10 PARTS (#2467, ADR-073 §3): a [code] or [done] SPEC is written
            # as Given/When/Then — one action, at least one thing to observe.
            _dck_parts "$_spec" "$_ACC_SPEC_STATUS" "$_ACC_SPEC_PARTS"
            # ADR-069 §9 (amended #2474): every SPEC, whatever its tag, says what
            # someone could see the code do, not what a file contains.
            [[ -n "$_ACC_SPEC_STATUS" ]] && _dck_describes_contents "$_ACC_SPEC_TEXT" \
                && violations+=("CONTENTS_NOT_BEHAVIOUR $_spec (describes file contents, not behaviour)")
            case "$_ACC_SPEC_STATUS" in
                "")      violations+=("NO_STATUS $_spec (requirement carries no [code], [no-code] or [done] status)") ;;
                no-code) : ;;
                code)
                    # #1649: existence is deliberately NOT checked — design runs
                    # before build, so requiring the file forced every design off
                    # its own proposed test file. The acceptance gate checks it.
                    # Traversal is dropped by acceptance-block.sh while parsing.
                    [[ -n "$(acceptance_list_testfiles_for_spec "$design_md" "$_spec" 2>/dev/null || true)" ]] \
                        || violations+=("MISSING_TESTFILE_FOR_SPEC $_spec (no testfile declared for [code] SPEC)") ;;
                done)
                    if [[ "$_ACC_SPEC_TAG" == "guard" ]]; then
                        violations+=("UNKNOWN_STATUS $_spec [guard] (the retired tag; use [done] with evidence)")
                        continue
                    fi
                    _ev_n=0
                    while IFS= read -r _ev; do
                        [[ -z "$_ev" ]] && continue
                        _ev_n=$((_ev_n + 1))
                        # The base commit is resolved once, and only when a [done] needs it.
                        if [[ -z "$_base_done" ]]; then
                            # shellcheck source=../../../../scripts/lib/merge-base.sh
                            declare -F zbuild_resolve_merge_base >/dev/null 2>&1 || source "$_DCK_LIB_DIR/merge-base.sh"
                            _base="$(zbuild_resolve_merge_base "$repo_root" 2>/dev/null || true)"; _base_done=1
                        fi
                        _dck_evidence_v _evw "$repo_root" "$_ev" "$_base"
                        case "$_evw" in
                            "")         : ;;
                            LINE)       violations+=("DONE_LINE_EVIDENCE $_spec $_ev (a line number)") ;;
                            NO_TEXT)    violations+=("DONE_NO_TEXT $_spec $_ev (a source file with no text)") ;;
                            MISSING)    violations+=("DONE_TEXT_MISSING $_spec $_ev (the text is not in the file)") ;;
                            NOT_BEFORE) violations+=("DONE_NOT_BEFORE $_spec $_ev (not in the code from before the change)") ;;
                            *)          violations+=("DONE_BAD_EVIDENCE $_spec $_ev (not a file in the repository)") ;;
                        esac
                    done < <(acceptance_spec_evidence "$design_md" "$_spec" 2>/dev/null || true)
                    [[ $_ev_n -eq 0 ]] && violations+=("DONE_NO_EVIDENCE $_spec ([done] names no evidence)") ;;
                *)       violations+=("UNKNOWN_STATUS $_spec [${_ACC_SPEC_TAG}] (not a status)") ;;
            esac
        done
    fi

    # ── C9 IDS (#2462, ADR-069 §1): each SPEC id describes it and never moves.
    # The last design that passed holds the ids to keep; REMOVED lines say why
    # one goes, and stay. A requirement's code is never a SPEC's.
    if [[ $_accept_ok -eq 1 ]]; then
        local _pa="" _pr="" _bad _w
        local -a _iv=()
        if [[ -n "$last" && -s "$last" && "$last" != "$design_md" ]]; then
            # A working copy that is still the last design holds its ids: no second read.
            if [[ "$(<"$last")" == "$(<"$design_md")" ]]; then _pa="$_na" _pr="$_nr"
            else _dck_block_ids_v _pa _pr "$(extract_acceptance_block "$last" 2>/dev/null)"; fi
        fi
        # #2482: a REMOVED line may name a SPEC that a try of this run wrote and
        # that did not pass — its draft is in the try archive.
        local _tried="" _tf _ta _tr _ast="${ZBUILD_CURRENT_STAGE:-design}"
        for _tf in "${design_md%/*}/attempts/${_ast//[^A-Za-z0-9_-]/_}"/*/design-draft.md; do
            [[ -s "$_tf" ]] || continue
            [[ -n "${ZBUILD_RUN_START_MARKER:-}" && -e "$ZBUILD_RUN_START_MARKER" && "$ZBUILD_RUN_START_MARKER" -nt "$_tf" ]] && continue
            _dck_block_ids_v _ta _tr "$(extract_acceptance_block "$_tf" 2>/dev/null)"
            _tried+="$_ta"
        done
        zb_ids_check_v _iv "$_pa" "$_pr" "$_na" "$_nr" "$_txt" "$_req_codes" 1 "$_tried"
        for _w in "${_iv[@]+"${_iv[@]}"}"; do violations+=("$_w"); done
        local -a _bads=()
        _dck_bad_id_lines_v _bads "$design_md"
        for _bad in "${_bads[@]+"${_bads[@]}"}"; do violations+=("ID_BAD $_bad"); done
    fi

    # ── C8 TEST FOLDERS (ADR-069 §10): every test file is in a test folder ──
    # #1801 run 40390919951: two ADR documents named as tests were run with bash.
    if [[ $_accept_ok -eq 1 ]]; then
        local _tf
        while IFS= read -r _tf; do
            [[ -n "$_tf" ]] || continue
            zb_is_test_path "$_tf" "$repo_root" \
                || violations+=("TESTFILE_NOT_A_TEST $_tf (not in a test folder)")
        done < <(acceptance_list_testfiles "$design_md" 2>/dev/null | LC_ALL=C sort -u)
    fi

    # ── C7 REQUIREMENTS (#2306, ADR-070 §3): every requirement intake numbered
    # is covered by at least one SPEC, whatever its status. Read by script, so
    # no model decides what the issue asked for.
    if [[ $_accept_ok -eq 1 && -s "$req_json" ]]; then
        local _rid _rtext _rk
        while IFS=$'\x1f' read -r _rk _rid _rtext; do
            [[ "$_rk" == A && -n "$_rid" ]] || continue
            [[ "$_covered" == *" $_rid "* ]] \
                || violations+=("REQUIREMENT_NOT_COVERED $_rid ($_rtext)")
        done <<< "$_req_rows"
    fi

    # ── C5 WIRING: section present ("none" ok); each concrete path exists and is no TESTFILE ─
    if [[ $_accept_ok -eq 1 ]]; then
        if ! acceptance_list_wiring "$design_md" >/dev/null 2>&1; then
            violations+=("WIRING_MISSING (design.md acceptance block has no WIRING: section)")
        else
            local _w _tfs
            _tfs="$(acceptance_list_testfiles "$design_md" 2>/dev/null || true)"
            while IFS= read -r _w; do
                [[ -z "$_w" || "$_w" == "none" ]] && continue
                [[ -e "$repo_root/$_w" ]] || { violations+=("WIRING_MISSING $_w (declared wiring path absent on disk)"); continue; }
                # #2429: reachability cannot prove a test file load-bearing.
                grep -qxF -- "$_w" <<< "$_tfs" && violations+=("WIRING_IS_TEST $_w (a TESTFILE named as WIRING)")
            done < <(acceptance_list_wiring "$design_md" 2>/dev/null || true)
        fi
    fi

    _DESIGN_VIOLATIONS=("${violations[@]}")
    return 0
}
