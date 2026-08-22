#!/usr/bin/env bash
# plugins/agent/build/lib/scope.sh — scope-validation and expansion helpers.
# Sourced by plugin.sh after shared libs (numstat-format.sh, etc.) are loaded.

[[ -n "${_ZBUILD_BUILD_SCOPE_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_SCOPE_LOADED=1

# _build_path_in_scope <path> <allowed_files_array_name>
# Thin wrapper around the shared _numstat_path_in_scope helper (#506).
_build_path_in_scope() {
    _numstat_path_in_scope "$@"
}

# _build_path_is_scratch <path> (#1789)
# Well-known editor/VCS scratch suffixes. `sed -i.bak` and `git show HEAD:f >
# f.head` leave these behind; they are residue of an agent comparing versions of
# a file it was authorised to edit, never work in their own right. Callers must
# apply this only to paths already known to be OUT of scope — an in-scope file
# that happens to carry one of these suffixes is legitimate work.
_build_path_is_scratch() {
    local _p="$1"
    [[ -z "$_p" ]] && return 1
    [[ "$_p" =~ \.(bak|orig|rej|head|tmp)$ ]] && return 0
    [[ "$_p" == *~ ]] && return 0
    return 1
}

# _build_detect_out_of_scope_files <feedback_body> <plan_files_csv> (#792)
# Detect when test_assessment's failure_summary_md names file paths NOT in
# plan.files[]. Returns list of out-of-scope paths (one per line), empty if none.
_build_detect_out_of_scope_files() {
    local feedback_body="$1"
    local plan_files_csv="$2"
    [[ -z "$feedback_body" ]] && return 0
    [[ -z "$plan_files_csv" ]] && return 0

    local cleaned
    cleaned="$(printf '%s' "$feedback_body" \
        | sed -E 's#(tests|plugins|config|core|scripts|docs)/[A-Za-z0-9_./-]+\.(sh|json|yaml|md|golden|txt):[0-9]+##g' \
        2>/dev/null || true)"

    local matches
    matches="$(printf '%s' "$cleaned" \
        | grep -oE '(tests|plugins|config|core|scripts|docs)/[A-Za-z0-9_./-]+\.(sh|json|yaml|md|golden|txt)' \
        2>/dev/null | sort -u || true)"
    [[ -z "$matches" ]] && return 0

    local m
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        case ",$plan_files_csv," in
            *",$m,"*) ;;
            *) printf '%s\n' "$m" ;;
        esac
    done <<< "$matches"
}

# _build_scope_expansion_request <oos_files_newline> <feedback_body> (#840)
# Builds an ADR-030 scope_expansion_request from the out-of-scope files build is
# blocked on. Echoes {files:[...]} or nothing.
_build_scope_expansion_request() {
    local oos="$1" feedback="$2"
    [[ -z "$oos" ]] && return 0
    # Use _BUILD_ROOT (set by zbuild_plugin_bootstrap before this lib is sourced).
    local _gov="$_BUILD_ROOT/scripts/lib/scope-governance.sh"
    # shellcheck source=/dev/null
    [[ -f "$_gov" ]] && source "$_gov"
    declare -F scope_collateral_class >/dev/null 2>&1 || return 0

    local -a tokens=()
    local _t
    while IFS= read -r _t; do
        [[ -n "$_t" ]] && tokens+=("$_t")
    done < <(printf '%s' "$feedback" \
        | grep -oE "'[^']{2,}'|\"[^\"]{2,}\"" 2>/dev/null \
        | sed -E "s/^['\"]//; s/['\"]\$//" | sort -u)

    local entries="[]" f cls ev
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        cls="$(scope_collateral_class "$f")"
        ev=""
        if [[ -f "$f" ]]; then
            for _t in "${tokens[@]:-}"; do
                [[ -z "$_t" ]] && continue
                if LC_ALL=C grep -qF -- "$_t" "$f" 2>/dev/null; then ev="$_t"; break; fi
            done
        fi
        entries="$(jq -c --arg p "$f" --arg c "$cls" --arg e "$ev" \
            '. + [{path:$p, category:$c, evidence:$e, reason:"build blocked on out-of-scope file named in test feedback"}]' \
            <<<"$entries" 2>/dev/null || printf '%s' "$entries")"
    done <<< "$oos"

    [[ "$entries" == "[]" ]] && return 0
    jq -nc --argjson f "$entries" '{files:$f}' 2>/dev/null || true
}

# _build_pending_collateral_request <verdict> <feedback_body> <plan_files_csv> (REC-1 #879)
_build_pending_collateral_request() {
    local verdict="$1" feedback="$2" plan_csv="$3"
    [[ "$verdict" == "pass" && -n "$feedback" && -n "$plan_csv" ]] || return 0
    local oos
    oos="$(_build_detect_out_of_scope_files "$feedback" "$plan_csv")"
    [[ -n "$oos" ]] || return 0
    _build_scope_expansion_request "$oos" "$feedback"
}

# _build_edited_collateral_request <feedback> <created_newline> <oos_newline> (REC-2 #880)
_build_edited_collateral_request() {
    local feedback="$1" created_nl="$2" oos_nl="$3"
    [[ -z "$oos_nl" ]] && return 0
    local created_csv; created_csv="$(printf '%s' "$created_nl" | tr '\n' ',')"
    local edited="" f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case ",$created_csv," in
            *",$f,"*) ;;
            *) edited+="$f"$'\n' ;;
        esac
    done <<< "$oos_nl"
    edited="${edited%$'\n'}"
    [[ -z "$edited" ]] && return 0
    _build_scope_expansion_request "$edited" "$feedback"
}

# _build_created_collateral_request <created_path> [created_path...] (#870)
_build_created_collateral_request() {
    (( $# == 0 )) && return 0
    local _gov="$_BUILD_ROOT/scripts/lib/scope-governance.sh"
    # shellcheck source=/dev/null
    [[ -f "$_gov" ]] && source "$_gov"
    declare -F scope_collateral_class >/dev/null 2>&1 || return 0

    local entries="[]" f cls
    for f in "$@"; do
        [[ -z "$f" ]] && continue
        cls="$(scope_collateral_class "$f")"
        [[ "$cls" == collateral_* ]] || continue
        entries="$(jq -c --arg p "$f" --arg c "$cls" \
            '. + [{path:$p, category:$c, created:true, evidence:"", reason:"build created new collateral artifact while implementing the plan"}]' \
            <<<"$entries" 2>/dev/null || printf '%s' "$entries")"
    done

    [[ "$entries" == "[]" ]] && return 0
    jq -nc --argjson f "$entries" '{files:$f}' 2>/dev/null || true
}

# Global output vars for _build_collect_scope_expansion_request:
_BUILD_SERQ_REQUEST_JSON=""
_BUILD_SERQ_REASON=""
_BUILD_SERQ_OOS_FILES_JSON="[]"

# _build_collect_scope_expansion_request <build_verdict> <feedback_body>
#   <plan_files_csv> <violations_created_nl> <violations_all_nl>
# Evaluates all scope-expansion-request paths (empty_diff #792, created #870,
# REC-1 #879, REC-2 #880) and sets globals:
#   _BUILD_SERQ_REQUEST_JSON — JSON request or empty
#   _BUILD_SERQ_REASON       — build_reason string or empty
#   _BUILD_SERQ_OOS_FILES_JSON — "[...]" or "[]"
_build_collect_scope_expansion_request() {
    local _build_verdict="$1"
    local _feedback_body="$2"
    local _plan_files_csv="$3"
    local _violations_created_nl="$4"
    local _violations_all_nl="$5"

    _BUILD_SERQ_REQUEST_JSON=""
    _BUILD_SERQ_REASON=""
    _BUILD_SERQ_OOS_FILES_JSON="[]"

    local -a _violations_created=()
    local -a _violations_all=()
    local _p
    while IFS= read -r _p; do
        [[ -n "$_p" ]] && _violations_created+=("$_p")
    done <<< "$_violations_created_nl"
    while IFS= read -r _p; do
        [[ -n "$_p" ]] && _violations_all+=("$_p")
    done <<< "$_violations_all_nl"

    local _req_json="" _reason="" _oos_json="[]"

    # Path A (#792): empty_diff + feedback names OOS files
    if [[ "$_build_verdict" == "empty_diff" && -n "${_feedback_body:-}" && -n "$_plan_files_csv" ]]; then
        local _oos_paths
        _oos_paths="$(_build_detect_out_of_scope_files "$_feedback_body" "$_plan_files_csv")"
        if [[ -n "$_oos_paths" ]]; then
            _reason="no_progress_scope_blocked"
            _oos_json="$(printf '%s\n' "$_oos_paths" \
                | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
            _req_json="$(_build_scope_expansion_request "$_oos_paths" "$_feedback_body" 2>/dev/null || true)"
        fi
    fi

    # Path B (#870): created out-of-scope collateral
    if [[ -z "$_req_json" && ${#_violations_created[@]} -gt 0 ]]; then
        _req_json="$(_build_created_collateral_request "${_violations_created[@]}" 2>/dev/null || true)"
    fi

    # REC-1 (#879): pass verdict with in-scope edits but OOS files still needed
    if [[ -z "$_req_json" ]]; then
        _req_json="$(_build_pending_collateral_request \
            "$_build_verdict" "${_feedback_body:-}" "$_plan_files_csv" 2>/dev/null || true)"
        if [[ -n "$_req_json" ]]; then
            _reason="scope_request_pending"
            _oos_json="$(jq -c '[.files[].path]' \
                <<<"$_req_json" 2>/dev/null || echo '[]')"
        fi
    fi

    # REC-2 (#880): edited (not created) OOS collateral in clean run
    if [[ -z "$_req_json" && ${#_violations_all[@]} -gt 0 ]]; then
        _req_json="$(_build_edited_collateral_request \
            "${_feedback_body:-}" \
            "$(printf '%s\n' "${_violations_created[@]:-}")" \
            "$(printf '%s\n' "${_violations_all[@]}")" 2>/dev/null || true)"
        if [[ -n "$_req_json" ]]; then
            _reason="${_reason:-scope_request_pending}"
            _oos_json="$(jq -c '[.files[].path]' \
                <<<"$_req_json" 2>/dev/null || echo '[]')"
        fi
    fi

    _BUILD_SERQ_REQUEST_JSON="$_req_json"
    _BUILD_SERQ_REASON="$_reason"
    _BUILD_SERQ_OOS_FILES_JSON="$_oos_json"
}

_extract_scope_from_design() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0

    local in_block=0
    local -a files=()
    while IFS= read -r line; do
        # Tolerate trailing whitespace on the fence lines — legacy used
        # /^```scope[[:space:]]*$/, and build's guard (grep -q '^```scope')
        # matches a whitespace-padded fence, so an exact match here would
        # silently drop the scope and fall back to plan.json (#25 review).
        if [[ "$line" =~ ^'```scope'[[:space:]]*$ ]]; then
            in_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" =~ ^'```'[[:space:]]*$ ]]; then
            break
        fi
        # Keep lines with any non-whitespace; drop whitespace-only lines
        # (faithful to legacy `grep -v '^[[:space:]]*$'`).
        if [[ $in_block -eq 1 && -n "${line//[[:space:]]/}" ]]; then
            files+=("$line")
        fi
    done < "$design_md"

    if [[ ${#files[@]} -gt 0 ]]; then
        local IFS=','
        printf '%s' "${files[*]}"
    fi
}
