#!/usr/bin/env bash
# plugins/tool/design-gate/plugin.sh — Design Gate Stage (ADR-046, ADR-037 §1/§3, #1218)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# The PRE-build mechanical structural gate for the design stage. Runs six checks
# (C1..C5, C7), reports ALL violations in one pass, and writes verdict=pass|fail
# to design-gate-result.json. Every check reads design.md and the files it names
# (C7 also reads intake's requirements.json — #2306, ADR-070); nothing is executed (C6, the [guard] baseline run, went with [guard] — #2304,
# ADR-069). Always returns rc=0 — the verdict lives in the artifact (ADR-040
# verdict-in-artifact convention); the design_verify_cycle's exit_when reads
# .verdict.
#
# Hook prefix: design_gate_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_DESIGN_GATE_PLUGIN_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_GATE_PLUGIN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_DG_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DG_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$_DG_ROOT/scripts/lib/stage-summary.sh" 2>/dev/null || true
# #1783: source the grammar lib from the contract-reader seam, not from the
# engine root. This gate parses the design's acceptance block, so a run that
# edits the block grammar must be gated by ITS copy, not the installed one.
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-block.sh" 2>/dev/null || true

# Resilient emit — no-op when the event-bus is unavailable (unit-test isolation).
_dg_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# _dg_scope_nonempty <design_md>
# C1: returns 0 iff design.md carries a ```scope fence with ≥1 non-blank entry.
_dg_scope_nonempty() {
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

# _dg_evidence_ok <repo_root> <item> — rc 0 when one evidence item of a [done]
# requirement points at the repository (ADR-069 §2): a repo-relative path (no
# leading / and no ..) to a file that exists, optionally `:N` with N inside it.
_dg_evidence_ok() {
    local root="$1" item="$2" path="$2" n=""
    if [[ "$item" =~ ^(.+):([0-9]+)$ ]]; then path="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"; fi
    [[ -n "$path" && "$path" != /* && "/$path/" != *"/../"* && -f "$root/$path" ]] || return 1
    [[ -z "$n" ]] && return 0
    local lines; lines="$(awk 'END { print NR }' "$root/$path" 2>/dev/null)"
    [[ "$n" -ge 1 && "$n" -le "${lines:-0}" ]]
}

# _dg_describes_contents <text> — rc 0 when a [code] requirement's words only
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
_dg_describes_contents() {
    local raw="${1,,}" t
    local b='(^|[^a-z0-9_])' e='([^a-z0-9_]|$)'
    [[ "$raw" =~ ${b}([a-z0-9_.-]+/[a-z0-9_./-]+|[a-z0-9_-]+\.(sh|bash|ya?ml|json|md|py|js|ts|toml|txt)|files?|manifests?|source|scripts?|functions?)${e} ]] || return 1
    t="$raw"
    while [[ "$t" =~ ^(.*)\`[^\`]*\`(.*)$ ]]; do t="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; done
    while [[ "$t" =~ ^(.*)\"[^\"]*\"(.*)$ ]]; do t="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; done
    [[ "$t" =~ ${b}(contains?|defines?|declares?|exists?|greps?|(is|are)\ +present|(has|have)\ +(a|an|the)\ +([^ ]+\ +){0,3}(keys?|fields?|entry|entries|functions?))${e} ]] || return 1
    [[ "$t" =~ ${b}((return|emit|write|fail|print|exit|reject|skip|stop|run|refuse|output|log|call|report|pass|create|remove|produce|read|send)[a-z]*|written|wrote|ran|when|if|whenever|unless|given)${e} ]] && return 1
    return 0
}

# ─── design_gate_run ──────────────────────────────────────────────────────────
# Runs C1..C5, collects ALL violations, writes verdict-in-artifact, emits
# design_gate.{pass,fail}. Always rc=0.
# Args: $1 = stage_id, $2 = state_file
# _dg_plain <violation> — the sentence design reads for one violation (#2269).
# The code stays in the result JSON (other code and tests read it); the feedback
# file says what to change, in the words design was given.
_dg_plain() {
    local v="$1" rest="${1#* }"
    local id="${rest%% *}" third="${rest#* }"; third="${third%% *}"
    case "$v" in
        SCOPE_MISSING*)      printf 'design.md has no scope block — add a ```scope block listing every file the change touches' ;;
        ACCEPTANCE_MISSING*) printf 'design.md has no readable ```acceptance block — add one with a line per requirement' ;;
        NO_STATUS*)          printf '%s has no status — tag it [code] if it needs code (its test fails on the code from before your change and passes after), [no-code] if it needs work that changes no behaviour (docs, a test, config or a refactor), or [done] if the code already does it (then name the evidence after " evidence: ")' "$id" ;;
        # The retired tag is named, not written: design would copy it back.
        "UNKNOWN_STATUS "*" [guard] "*) printf '%s carries the old guard tag, which is no longer a status — tag it [done] if the code already does it, naming the evidence after " evidence: ", or [code] if it needs code' "$id" ;;
        UNKNOWN_STATUS*)     printf '%s is tagged %s, which is not a status — tag it [code] if it needs code, [no-code] if it needs work that changes no behaviour, or [done] if the code already does it, naming the evidence after " evidence: "' "$id" "$third" ;;
        DONE_NO_EVIDENCE*)   printf '%s is marked [done] but names no evidence — end its line with " evidence: " and a file and line (scripts/x.sh:42) or an existing test file that shows the code already does it' "$id" ;;
        DONE_BAD_EVIDENCE*)  printf 'the evidence %s for %s does not point at the repository — name a file that exists, by its path from the repository root (no leading / and no ..), with a line number inside the file' "$third" "$id" ;;
        CONTENTS_NOT_BEHAVIOUR*) printf '%s describes what a file contains, not what the code does — describe the behaviour someone could observe (an input and what happens), or, if the code already does it, mark it [done] with evidence' "$id" ;;
        MISSING_TESTFILE_FOR_SPEC*) printf '%s has no test file listed — add a "%s: <test file>" line under TESTFILES:' "$id" "$id" ;;
        "WIRING_MISSING ("*) printf 'the acceptance block does not say which existing file calls the new code — add a WIRING: line naming it, or WIRING: none if nothing calls it yet' ;;
        REQUIREMENT_NOT_COVERED*) local _rt="${rest#* (}"; _rt="${_rt%)}"
            printf 'requirement %s from the issue ("%s") is not covered by any SPEC — end the line of the SPEC that delivers it with " covers: %s" (before any " evidence: "), or add a SPEC for it; if the code already does it, a [done] SPEC with evidence covers it' "$id" "$_rt" "$id" ;;
        WIRING_MISSING*)     printf 'the WIRING file %s does not exist — name a file that exists in the repository, or WIRING: none' "$id" ;;
        *) printf '%s' "$v" ;;
    esac
}

design_gate_run() {
    local stage_id="${1:-design-gate}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-$(zbuild_engine_tmpdir)/zbuild-design-gate-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local design_md=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        design_md="$(jq -r '.inputs.design // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi
    [[ -n "$design_md" ]] || design_md="$artifacts_dir/design.md"
    local result_path="$artifacts_dir/design-gate-result.json"
    local feedback_path="$artifacts_dir/design-gate-feedback.md"
    # repo_root = the working tree where declared TESTFILES / WIRING paths live.
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$_DG_ROOT")}"

    local -a violations=()
    # #2306 (ADR-070 §3): the issue's numbered requirements; absent on a goal run.
    local req_json=""
    [[ -n "${ZBUILD_STAGE_INPUTS:-}" ]] && req_json="$(jq -r '.inputs.requirements // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    [[ -n "$req_json" ]] || req_json="$artifacts_dir/requirements.json"
    local _covered=" "

    # ── C1 SCOPE: non-empty ```scope block ──────────────────────────────────
    if ! _dg_scope_nonempty "$design_md"; then
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
        local _blk _spec _ev _ev_n
        _blk="$(extract_acceptance_block "$design_md" 2>/dev/null || true)"
        while IFS= read -r _spec; do
            [[ -z "$_spec" ]] && continue
            _acceptance_spec_line "$_blk" "$_spec" || continue
            _covered+="${_ACC_SPEC_COVERS//,/ } "
            case "$_ACC_SPEC_STATUS" in
                "")      violations+=("NO_STATUS $_spec (requirement carries no [code], [no-code] or [done] status)") ;;
                no-code) : ;;
                code)
                    # #1649: existence is deliberately NOT checked — design runs
                    # before build, so requiring the file forced every design off
                    # its own proposed test file. The acceptance gate checks it.
                    # Traversal is dropped by acceptance-block.sh while parsing.
                    [[ -n "$(acceptance_list_testfiles_for_spec "$design_md" "$_spec" 2>/dev/null || true)" ]] \
                        || violations+=("MISSING_TESTFILE_FOR_SPEC $_spec (no testfile declared for [code] SPEC)")
                    _dg_describes_contents "$_ACC_SPEC_TEXT" \
                        && violations+=("CONTENTS_NOT_BEHAVIOUR $_spec (describes file contents, not behaviour)") ;;
                done)
                    if [[ "$_ACC_SPEC_TAG" == "guard" ]]; then
                        violations+=("UNKNOWN_STATUS $_spec [guard] (the retired tag; use [done] with evidence)")
                        continue
                    fi
                    _ev_n=0
                    while IFS= read -r _ev; do
                        [[ -z "$_ev" ]] && continue
                        _ev_n=$((_ev_n + 1))
                        _dg_evidence_ok "$repo_root" "$_ev" \
                            || violations+=("DONE_BAD_EVIDENCE $_spec $_ev (not a file in the repository, or the line is outside it)")
                    done < <(acceptance_spec_evidence "$design_md" "$_spec" 2>/dev/null || true)
                    [[ $_ev_n -eq 0 ]] && violations+=("DONE_NO_EVIDENCE $_spec ([done] names no evidence)") ;;
                *)       violations+=("UNKNOWN_STATUS $_spec [${_ACC_SPEC_TAG}] (not a status)") ;;
            esac
        done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
    fi

    # ── C7 REQUIREMENTS (#2306, ADR-070 §3): every requirement intake numbered
    # is covered by at least one SPEC, whatever its status. Read by script, so
    # no model decides what the issue asked for.
    if [[ $_accept_ok -eq 1 && -s "$req_json" ]]; then
        local _rid _rtext
        while IFS=$'\t' read -r _rid _rtext; do
            [[ -z "$_rid" ]] && continue
            [[ "$_covered" == *" $_rid "* ]] \
                || violations+=("REQUIREMENT_NOT_COVERED $_rid ($_rtext)")
        done < <(jq -r '.requirements[]? | [.id, (.text | gsub("[\t\n]"; " "))] | @tsv' "$req_json" 2>/dev/null || true)
    fi

    # ── C5 WIRING: section present ("none" ok); each concrete path exists ────
    if [[ $_accept_ok -eq 1 ]]; then
        if ! acceptance_list_wiring "$design_md" >/dev/null 2>&1; then
            violations+=("WIRING_MISSING (design.md acceptance block has no WIRING: section)")
        else
            local _w
            while IFS= read -r _w; do
                [[ -z "$_w" || "$_w" == "none" ]] && continue
                [[ -e "$repo_root/$_w" ]] || violations+=("WIRING_MISSING $_w (declared wiring path absent on disk)")
            done < <(acceptance_list_wiring "$design_md" 2>/dev/null || true)
        fi
    fi

    # ── Verdict + artifact ───────────────────────────────────────────────────
    local verdict violations_json reason
    if [[ ${#violations[@]} -eq 0 ]]; then
        verdict="pass"
        violations_json="[]"
        reason="all structural checks cleared"
    else
        verdict="fail"
        violations_json="$(printf '%s\n' "${violations[@]}" | jq -R . | jq -s .)"
        reason="design structural violations: ${#violations[@]} found"
    fi

    # #2225 (review #2229): the verdict names the exact design.md it judged, so a
    # pass for THIS design can be told from a pass for an earlier one that was
    # rewritten afterwards. (No run reuses a design on it since #2299.)
    local _dg_sha; _dg_sha="$(git hash-object "$design_md" 2>/dev/null || true)"
    # #2271 (ADR-068): each violation as a numbered finding, in the sentence
    # design reads — the codes stay in `violations` for code that reads them.
    local _dg_findings="[]" _dg_fv
    if [[ ${#violations[@]} -gt 0 ]]; then
        _dg_findings="$(for _dg_fv in "${violations[@]}"; do _dg_plain "$_dg_fv"; printf '\n'; done | stage_findings_json)"
    fi
    atomic_write "$result_path" <<< "$(jq -n --arg v "$verdict" --argjson viol "$violations_json" \
        --arg r "$reason" --arg sha "$_dg_sha" --argjson fnd "${_dg_findings:-[]}" \
        '{"result_contract":2,"schema_version":1,"verdict":$v,"disposition":"complete","reason":$r,"violations":$viol,
          "data":{"design_sha":$sha, "findings":$fnd}}')"

    if [[ "$verdict" == "fail" ]]; then
        {
            printf '# Design-gate: structural violations\n\n'
            printf 'The design is not ready to build. Fix these and write design.md again:\n\n'
            local _dg_v
            for _dg_v in "${violations[@]}"; do printf -- '- %s\n' "$(_dg_plain "$_dg_v")"; done
        } | atomic_write "$feedback_path"
        _dg_emit "design_gate.fail" "plugin=design-gate" "violations=${#violations[@]}"
    else
        # ADR-055 §9: written on every terminal verdict; absence is never legitimate.
        printf '# Design-gate: all structural checks cleared\n\nThe design is build-ready.\n' \
            | atomic_write "$feedback_path"
        _dg_emit "design_gate.pass" "plugin=design-gate"
    fi

    _dg_emit "plugin.result" "plugin=design-gate" "verdict=$verdict"
    return 0
}

# ─── design_gate_cleanup ──────────────────────────────────────────────────────
