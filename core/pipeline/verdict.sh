#!/usr/bin/env bash
# core/pipeline/verdict.sh — verdict-driven stage indicator resolver (issue #507).
#
# Resolves a stage's verdict by reading the plugin's manifest-declared
# primary output artifact. Used by runner.sh to choose the glyph + color
# of the per-stage indicator line (was: hardcoded green ✓ for every rc=0
# stage; now reflects the plugin's actual verdict).
#
# Verdict table (PINNED — see ADR-019 / ADR-020 amendment):
#   pass                                          → ✓ GREEN
#   fail, error (a stage that did not finish)     → ✗ RED
#   missing/malformed on declared-primary         → ✗ RED (`error`) + stage.verdict.contract_violation
#   rc != 0 (any cause)                           → ✗ RED  (rc always wins)
#
# #2366 (ADR-054 §6): every stage writes one outcome from the engine's closed
# list (result contract 3); no stage has its own verdict words.
#
# Public API:
#   runner_read_stage_verdict <state_dir> <manifest_path> <stage> <rc>
#       echoes one of: pass | warn | fail | unknown
#         OR (#550 structural-failure pass-through): error — a stage that did not
#         finish, or a result the engine cannot read
#       The structural-failure raw verdicts bypass classification so the
#       cycle blocked predicate can distinguish them from generic "fail".
#       side-effects: may emit stage.verdict.missing event
#
#   verdict_glyph <verdict_class>     → ✓ | ⚠ | ✗
#   verdict_color <verdict_class>     → ANSI escape (or empty if NO_COLOR)
#
# Bash 5+. Sourced library; do not add set -euo pipefail.

[[ -n "${_ZBUILD_VERDICT_LOADED:-}" ]] && return 0
_ZBUILD_VERDICT_LOADED=1

_ZBUILD_VERDICT_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_ZBUILD_VERDICT_ROOT="$(cd "$_ZBUILD_VERDICT_DIR/../.." && pwd)"

# #1824: the engine's declared contract range. NOT `|| true` — the v2 branch
# below keys off _ZBUILD_CONTRACT_V2, and a silently-missing bound would read
# every result as v1 and skip disposition validation entirely.
# shellcheck source=../contract/version.sh
source "$_ZBUILD_VERDICT_ROOT/core/contract/version.sh"

# Defensive sources so the file is usable in isolation (unit tests).
if ! declare -F eb_emit_event >/dev/null 2>&1; then
    # shellcheck source=../event-bus/event-bus.sh
    source "$_ZBUILD_VERDICT_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
fi
# #1822: the closed disposition set. NOT `|| true` — without it the reader would
# silently stop validating dispositions, which is the unenforced-declaration
# failure ADR-054 exists to end.
if ! declare -F disposition_is_valid >/dev/null 2>&1; then
    # shellcheck source=./disposition.sh
    source "$_ZBUILD_VERDICT_ROOT/core/pipeline/disposition.sh"
fi
# #1823: the fallback classification for a dispatch that left no result. NOT
# `|| true` — without it the reader would silently fall back to nothing at all
# for exactly the dispatches that need explaining.
if ! declare -F dispatch_rc_failure_disposition >/dev/null 2>&1; then
    # shellcheck source=./dispatch-rc.sh
    source "$_ZBUILD_VERDICT_ROOT/core/pipeline/dispatch-rc.sh"
fi
# ADR-068 §8: whether a result was written by its stage's latest run.
# shellcheck source=../../scripts/lib/stage-dispatch-mark.sh
declare -F stage_result_is_current >/dev/null 2>&1 || \
    source "$_ZBUILD_VERDICT_ROOT/scripts/lib/stage-dispatch-mark.sh"
if [[ -z "${GREEN:-}${YELLOW:-}${RED:-}" ]]; then
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$_ZBUILD_VERDICT_ROOT/scripts/lib/helpers.sh" 2>/dev/null || true
fi

# ─── verdict_classify <raw_verdict> → pass|warn|fail|unknown ──────────────────
# Maps a raw verdict string (from a plugin's primary-output JSON) into one of
# four indicator classes per the verdict table above.
verdict_classify() {
    # #2366 (ADR-054 §6): every stage writes one outcome; the reader turns it
    # into pass, fail, or `error` for a stage that did not finish. Those are
    # the only words the engine knows — no stage's own word is classified.
    case "${1:-}" in
        pass)       echo "pass" ;;
        fail|error) echo "fail" ;;
        *)          echo "unknown" ;;
    esac
}

# ─── verdict_glyph <class> ─────────────────────────────────────────────────────
verdict_glyph() {
    case "${1:-}" in
        pass)  echo "✓" ;;
        warn)  echo "⚠" ;;
        fail)  echo "✗" ;;
        *)     echo "⚠" ;;
    esac
}

# ─── verdict_color <class> ─────────────────────────────────────────────────────
verdict_color() {
    case "${1:-}" in
        pass)  printf '%s' "${GREEN:-}" ;;
        warn)  printf '%s' "${YELLOW:-}" ;;
        fail)  printf '%s' "${RED:-}" ;;
        *)     printf '%s' "${YELLOW:-}" ;;
    esac
}

# ─── _verdict_primary_output_path <manifest> ──────────────────────────────────
# Returns the path: value of the FIRST outputs[] entry marked `primary: true`.
# Empty string if none. Mirrors the awk in contracts.sh but scoped to the
# primary-flagged row.
_verdict_primary_output_path() {
    local _vpp
    _verdict_primary_output_path_v _vpp "${1-}"
    [[ -n "$_vpp" ]] && printf '%s\n' "$_vpp"
    return 0
}
# _verdict_primary_output_path_v <var> <manifest> — the same, read by the shell
# into <var> (ADR-065 §5: it runs on every result read). An entry's values carry
# over when the outputs block closes and reopens, as they did in the awk.
_verdict_primary_output_path_v() {
    local -n _vpo="$1"; _vpo=""
    local manifest="${2-}" l v in_out=0 cpath="" cprim=""
    [[ -f "$manifest" && -r "$manifest" ]] || return 0
    declare -F _mg_clean_v >/dev/null 2>&1 \
        || source "$_ZBUILD_VERDICT_ROOT/scripts/lib/manifest-graph.sh"
    local re_open='^outputs:' re_top='^[a-zA-Z_]' re_id='^[[:space:]]*-[[:space:]]*id:'
    local re_kv='^[[:space:]]+(path|primary):'
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ "$l" =~ $re_open ]] && { in_out=1; continue; }
        [[ "$l" =~ $re_top ]] && in_out=0
        (( in_out )) || continue
        if [[ "$l" =~ $re_id ]]; then
            [[ "$cprim" == "true" && -n "$cpath" ]] && { _vpo="$cpath"; return 0; }
            cpath=""; cprim=""; continue
        fi
        if [[ "$l" =~ $re_kv ]]; then
            v="${l#*:}"; _mg_strip_lead_v v; _mg_clean_v v
            if [[ "${BASH_REMATCH[1]}" == path ]]; then cpath="$v"; else cprim="$v"; fi
        fi
    done 2>/dev/null < "$manifest"
    [[ "$cprim" == "true" && -n "$cpath" ]] && _vpo="$cpath"
    return 0
}

# ─── _verdict_resolve_path <raw_path> <state_dir> ─────────────────────────────
# Expands the canonical templating vars (manifest_graph_canonical_vars, ADR-055
# §2) and anchors relative paths under state_dir. THE engine's single
# interpolation helper — stage-prompt.sh and input-resolve.sh (#1826)
# both delegate here rather than adding a sixth copy.
#
# #1826 added ${stage_io_dir} and ${run_id}. The first had NO resolver anywhere
# in the tree despite being canonical since ADR-015 v1; run_id comes from the
# environment, so an unset ZBUILD_RUN_ID leaves the reference expanding to empty.
_verdict_resolve_path() { local _vrp; _verdict_resolve_path_v _vrp "$1" "$2"; printf '%s' "$_vrp"; }
# _verdict_resolve_path_v <var> <raw> <state_dir> — the same, into <var>, with no
# subshell (ADR-065 §5).
_verdict_resolve_path_v() {
    local _vrv_out="$1" _vrv_raw="$2" _vrv_sd="$3"
    local _vrv_ad="${_vrv_sd}/artifacts"
    local _vrv_p="$_vrv_raw"
    _vrv_p="${_vrv_p//\$\{state_dir\}/$_vrv_sd}"
    _vrv_p="${_vrv_p//\$\{artifact_dir\}/$_vrv_ad}"
    _vrv_p="${_vrv_p//\$\{artifacts_dir\}/$_vrv_ad}"
    _vrv_p="${_vrv_p//\$\{stage_io_dir\}/$_vrv_ad/stage-io}"
    # run_id is interpolated into a path: strip anything but the sanitized set
    # the runner itself guarantees, so a hostile value cannot traverse.
    local _vrv_rid="${ZBUILD_RUN_ID:-}"; _vrv_rid="${_vrv_rid//[^A-Za-z0-9._-]/_}"
    _vrv_p="${_vrv_p//\$\{run_id\}/$_vrv_rid}"
    # #2270: a map element's own name, so parallel elements never share a file.
    # Sanitized like run_id — it is interpolated into a path.
    # With no element set (outside a map member) it stays unresolved: an empty
    # name would point at a file no element owns (`lens--checkpoint.md`).
    local _vrv_me="${ZBUILD_MAP_ELEMENT:-}"; _vrv_me="${_vrv_me//[^A-Za-z0-9._-]/_}"; _vrv_me="${_vrv_me//../__}"
    [[ -n "$_vrv_me" ]] && _vrv_p="${_vrv_p//\$\{map_element\}/$_vrv_me}"
    if [[ "$_vrv_p" != /* ]]; then
        _vrv_p="$_vrv_sd/$_vrv_p"
    fi
    printf -v "$_vrv_out" '%s' "$_vrv_p"
}

# ─── _verdict_parse_result_v <var> <result.json> <state_dir> ─────────────────
# The one parse of a result (ADR-065 §5). Lines: contract, outcome, the first
# mandatory field that is missing or empty, data.build_kind, then the reason
# (last, because free text may span lines) ending in a \001 marker.
#
# Every reader parses through here, and the runner reads each result once in
# its own shell before it asks its readers, each in its own $( ): they inherit
# the parse. It is used while the mark made just BEFORE it read the file is
# strictly newer than the file; any write after the mark leaves the file no
# older than it, and it is parsed again. Each shell keeps its own marks, under
# the run's runtime/, so a subshell's parse never vouches for its parent's.
declare -gA _VR_PARSE=() _VR_PARSE_MARK=()
_VR_PARSE_N=0
_verdict_parse_result_v() {
    local -n _vp_out="$1"
    local _vp_f="$2" _vp_dir="${3:-}/runtime/read-marks" _vp_mark="${_VR_PARSE_MARK[$2]:-}" _vp_r
    if [[ -n "$_vp_mark" && "$_vp_mark" -nt "$_vp_f" ]]; then
        _vp_out="${_VR_PARSE[$_vp_f]}"; return 0
    fi
    if [[ -n "${3:-}" && -d "$3" ]]; then
        [[ "$_vp_mark" == "$_vp_dir/$BASHPID."* ]] || {
            _VR_PARSE_N=$(( _VR_PARSE_N + 1 )); _vp_mark="$_vp_dir/$BASHPID.$_VR_PARSE_N"; }
        [[ -d "$_vp_dir" ]] || mkdir -p "$_vp_dir" 2>/dev/null
        : > "$_vp_mark" 2>/dev/null || _vp_mark=""
    else
        _vp_mark=""
    fi
    if ! _vp_r="$(jq -r '. as $o
        | def ok($f): ($o|has($f)) and ($o[$f]|type == "string") and ($o[$f]|length > 0);
        ["outcome", "reason"] as $need
        | [ ($o.result_contract // 1 | tostring),
          ($o.outcome // "" | tostring | gsub("\n"; " ")),
          ([ $need[] | select(ok(.) | not) ] | first // ""),
          ((try $o.data.build_kind catch null) // "" | if type == "string" then . else tojson end | gsub("\n"; " ")),
          (($o.reason // "" | tostring) + "\u0001") ] | join("\n")' "$_vp_f" 2>/dev/null)"; then
        unset '_VR_PARSE_MARK[$_vp_f]'
        return 1
    fi
    _vp_out="$_vp_r"
    if [[ -n "$_vp_mark" ]]; then
        _VR_PARSE[$_vp_f]="$_vp_r"; _VR_PARSE_MARK[$_vp_f]="$_vp_mark"
    fi
    return 0
}

# ─── _verdict_read_result <state_dir> <manifest> <stage> <rc> <out_prefix> ───
# ADR-054 (#1821): resolve a stage's result ONCE and publish it on named vars,
# so the three public readers stop each re-resolving and re-parsing the same
# artifact (cycle_dispatch_stage calls all three per member).
#
# Publishes:
#   <prefix>_state    ok | no_manifest | no_primary | absent | malformed | nonjson
#   <prefix>_contract the result's .result_contract (1 when absent — out of the
#                     range since #1850, so a violation)
#
# NB: the version key is `result_contract`, NOT `schema_version`. `schema_version`
# is already taken and means the ARTIFACT's own schema, independently per artifact
# type — build-summary.json is at 4 (#602, pinned by build-test.sh). Reusing it
# would read every build summary as a v2 result and fail it for a missing
# `disposition`; that false positive was caught by the local-vs-CI parity golden.
#   <prefix>_verdict  raw verdict string ("" when the artifact carries none)
#   <prefix>_disp     .disposition. PARSED AND EXPOSED, NOT BRANCHED ON here;
#                     the vocabulary and the engine's response table are #1822.
#   <prefix>_reason   .reason ("" when absent)
#   <prefix>_viol     "" | contract_violation:<detail>
#   <prefix>_path     resolved primary path ("" when unresolvable)
#
# #1850 (ADR-054 §5): the engine reads result contract v2 only. A result that
# exists but is not v2 — malformed, missing a mandatory field, no
# result_contract or one out of range — is a violation published on <prefix>_viol.
# A dispatch that left NO readable result (no manifest, no primary declared, a
# non-JSON primary, an absent primary) keeps its <prefix>_state here, because
# what that means depends on rc: at rc 0 it is a structural failure
# (_verdict_unreadable_violation), at rc≠0 the stage died and the disposition
# reader classifies how. The lenient defaults that used to read these states as
# pass/warn are gone.
#
# Takes rc but never consults it: rc semantics belong to the callers. That is
# what lets runner_read_stage_reason surface a reason on a FAILED dispatch.
_verdict_read_result() {
    local state_dir="$1" manifest="$2" stage="$3" _rc="$4" p="$5"
    printf -v "${p}_state" '%s' "ok"
    printf -v "${p}_contract" '%s' "1"
    printf -v "${p}_verdict" '%s' ""
    printf -v "${p}_disp" '%s' ""
    printf -v "${p}_reason" '%s' ""
    printf -v "${p}_viol" '%s' ""
    printf -v "${p}_path" '%s' ""
    printf -v "${p}_present" '%s' "0"
    printf -v "${p}_kind" '%s' ""

    if [[ -z "$manifest" || ! -f "$manifest" ]]; then
        printf -v "${p}_state" '%s' "no_manifest"; return 0
    fi

    local prim_path; _verdict_primary_output_path_v prim_path "$manifest"
    if [[ -z "$prim_path" ]]; then
        printf -v "${p}_state" '%s' "no_primary"; return 0
    fi

    local resolved; _verdict_resolve_path_v resolved "$prim_path" "$state_dir"
    printf -v "${p}_path" '%s' "$resolved"

    case "$resolved" in
        *.json) ;;
        # A non-JSON primary cannot carry a v2 result (ADR-054 §5). It stays
        # `nonjson` whether or not it exists; the caller decides what that means.
        *)  printf -v "${p}_state" '%s' "nonjson"
            [[ -s "$resolved" ]] && printf -v "${p}_present" '%s' "1"
            return 0 ;;
    esac

    if [[ ! -s "$resolved" ]]; then
        printf -v "${p}_state" '%s' "absent"; return 0
    fi
    # A result older than the stage's latest run is the previous run's: that
    # run wrote none (ADR-068 §8).
    if ! stage_result_is_current "$state_dir" "$stage" "$resolved"; then
        printf -v "${p}_state" '%s' "absent"; return 0
    fi
    # One parse for every field (ADR-065), shared by every reader.
    local _rr_out _rr_rest
    if ! _verdict_parse_result_v _rr_out "$resolved" "$state_dir"; then
        if ! jq empty "$resolved" >/dev/null 2>&1; then
            printf -v "${p}_state" '%s' "malformed"
            printf -v "${p}_viol" '%s' "contract_violation:malformed_json"
            return 0
        fi
        _rr_out=$'1\n\n\n\n\001'   # valid JSON but not an object: no contract, no fields
    fi
    local _sv="${_rr_out%%$'\n'*}"; _rr_rest="${_rr_out#*$'\n'}"
    local _rr_outcome="${_rr_rest%%$'\n'*}"; _rr_rest="${_rr_rest#*$'\n'}"
    local _rr_missing="${_rr_rest%%$'\n'*}"; _rr_rest="${_rr_rest#*$'\n'}"
    printf -v "${p}_kind" '%s' "${_rr_rest%%$'\n'*}"; _rr_rest="${_rr_rest#*$'\n'}"
    [[ "$_sv" =~ ^[0-9]+$ ]] || _sv=1
    printf -v "${p}_contract" '%s' "$_sv"
    # NOTE: do NOT try to publish the version on a global from here. Many
    # callers still read through `x="$(runner_read_stage_...)"`, and a `$()` is
    # a SUBSHELL — an assignment inside it never reaches the parent. A gate
    # reading such a global would silently always see the default and never
    # fire: green, and inert. That is exactly what #1823 shipped for one commit
    # before review caught it. A caller that needs one of these values reads it
    # from a reader (its stdout, or its _v form's variable).
    # The \001 marks the end: `$( )` strips trailing newlines, so an empty
    # reason would otherwise shift every field above it.
    printf -v "${p}_reason" '%s' "${_rr_rest%$'\001'}"

    if ! contract_version_supported "$_sv"; then
        # #1850/#2366: a result contract the engine does not read (an absent one,
        # or contract 2). The range is core/contract/version.sh's, never a literal.
        printf -v "${p}_viol" '%s' "contract_violation:unsupported_contract:${_sv}"
        return 0
    fi
    # #2366 (ADR-054 §6): a result carries ONE word. pass and fail mean the stage
    # finished and judged its work; any other word on the list is how it failed
    # to finish, and the engine's disposition response applies. Mapped here onto
    # the verdict/disposition pair the rest of the engine reads.
    if [[ -n "$_rr_missing" ]]; then
        printf -v "${p}_viol" '%s' "contract_violation:missing_field:${_rr_missing}"
    elif ! outcome_is_valid "$_rr_outcome"; then
        printf -v "${p}_viol" '%s' "contract_violation:unknown_outcome:${_rr_outcome}"
    else
        case "$_rr_outcome" in
            pass|fail) printf -v "${p}_verdict" '%s' "$_rr_outcome"
                       printf -v "${p}_disp" '%s' "complete" ;;
            *)         printf -v "${p}_verdict" '%s' "error"
                       printf -v "${p}_disp" '%s' "$_rr_outcome" ;;
        esac
    fi
    return 0
}

# ─── _verdict_unreadable_violation <state> ───────────────────────────────────
# #1850: the violation a dispatch that exited 0 committed by leaving no readable
# result. Prints nothing for `ok` (and for `malformed`, which already carries its
# own violation). Each of these used to be a lenient default — pass, warn, or
# unknown — which is how a stage that crashed before writing anything passed.
_verdict_unreadable_violation() { local _vuv; _verdict_unreadable_violation_v _vuv "${1:-}"; printf '%s' "$_vuv"; }
_verdict_unreadable_violation_v() {
    local -n _vuvo="$1"
    case "${2:-}" in
        no_manifest) _vuvo='contract_violation:no_manifest' ;;
        no_primary)  _vuvo='contract_violation:no_primary' ;;
        nonjson)     _vuvo='contract_violation:nonjson_primary' ;;
        absent)      _vuvo='contract_violation:missing_result' ;;
        *)           _vuvo='' ;;
    esac
}

# ─── runner_read_stage_verdict <state_dir> <manifest> <stage> <rc> ───────────
# Returns the verdict class. Side-effect: emits stage.verdict.missing when a
# manifest declares a primary output but the artifact is missing/malformed.
runner_read_stage_verdict() { local _rsv; runner_read_stage_verdict_v _rsv "$@"; echo "$_rsv"; }
# runner_read_stage_verdict_v <var> <state_dir> <manifest> <stage> <rc> — the
# same into <var>, in this shell: a dispatch reads it, and the readers below,
# every time (ADR-065 §5, round 9). Each _v form's locals are its own.
runner_read_stage_verdict_v() {
    local -n _rsvo="$1"; shift
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"

    # rc always wins.
    if [[ "$rc" -ne 0 ]]; then
        _rsvo="fail"; return 0
    fi

    local _r_state _r_contract _r_verdict _r_disp _r_reason _r_viol _r_path _r_present _r_kind
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _r

    # ADR-054 (#1821): a contract violation is a STRUCTURAL failure, not a warn.
    # It returns raw `error` — already in the #550 pass-through set, so
    # _cycle_detect_blocked halts on it with no predicate or template change —
    # and carries its detail on the .reason channel. #1850: leaving no readable
    # result at rc 0 is one too.
    [[ -n "$_r_viol" ]] || _verdict_unreadable_violation_v _r_viol "$_r_state"
    if [[ -n "$_r_viol" ]]; then
        eb_emit_event "stage.verdict.contract_violation" \
            "stage=$stage" "reason=$_r_viol" "result_contract=$_r_contract" \
            "path=$_r_path" 2>/dev/null || true
        _rsvo="error"; return 0
    fi

    # A v2 result always carries a verdict (an empty one is a violation above).
    local raw_verdict="$_r_verdict"

    local cls
    case "$raw_verdict" in pass) cls=pass ;; fail|error) cls=fail ;; *) cls=unknown ;; esac   # verdict_classify
    # #550: preserve structural-failure raw verdicts so the cycle blocked
    # predicate (_cycle_detect_blocked) can distinguish them from generic
    # "fail" (which means "test ran and failed — keep iterating").
    # `error` means "the stage could not complete its work" and the cycle must
    # abort early. Without this pass-through, verdict_classify collapses it to
    # "fail" and _cycle_detect_blocked never fires. (#2366: the reader maps
    # every outcome that is not pass or fail to `error`; corrupt_diff and block
    # can no longer occur.)
    if [[ "$raw_verdict" == error ]]; then
        _rsvo="$raw_verdict"; return 0
    fi
    if [[ "$cls" == "unknown" ]]; then
        eb_emit_event "pipeline.indicator.unknown_verdict" \
            "stage=$stage" "raw_verdict=$raw_verdict" "path=$_r_path" 2>/dev/null || true
        # Unknown verdict on a declared primary → warn (informational drift).
        _rsvo="warn"; return 0
    fi
    _rsvo="$cls"
}

# ─── runner_read_stage_reason <state_dir> <manifest> <stage> <rc> ───────────
# ADR-029 G2 (#810): when a stage produced verdict=error, return the .reason
# string from its primary output JSON. Used by the cycle orchestrator's
# G2 fast-abandon: a reason of `router_timeout` / `router_oom_kill` from
# `_router_rc_classify` is the signal that this dispatch was infra-failed
# (not a recoverable model error).
#
# Side-effects: NONE here. No events emitted; the classified verdict reader
# already covered diagnostic events for this dispatch pass.
runner_read_stage_reason() { local _rsr; runner_read_stage_reason_v _rsr "$@"; printf '%s' "$_rsr"; }
runner_read_stage_reason_v() {
    local -n _rsro="$1"; shift
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"
    # ADR-054 (#1821): the `rc != 0 → echo ""` early return is GONE. It discarded
    # the reason for exactly the dispatches that needed explaining — a plugin
    # that returns non-zero after writing a result (plan's `return 1`) left the
    # engine holding only an integer. Read whenever a result exists; a dispatch
    # that died before writing one still yields empty, which is the honest answer
    # and is what #1823's fallback classification keys on.
    local _n_state _n_contract _n_verdict _n_disp _n_reason _n_viol _n_path _n_present _n_kind
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _n
    # A contract violation explains itself on this channel too, so an operator
    # reading the reason sees why the stage was failed rather than a blank. At
    # rc 0, leaving no readable result is one (#1850); at rc≠0 the stage died,
    # and the blank is the honest answer #1823's classification keys on.
    if [[ -z "$_n_viol" && "$rc" -eq 0 ]]; then
        _verdict_unreadable_violation_v _n_viol "$_n_state"
    fi
    if [[ -n "$_n_viol" ]]; then _rsro="$_n_viol"; return 0; fi
    # ADR-058 C12 (amended 2026-10-26): a halt for changing the repository says
    # so — the stage's own result describes its work, not why the run stopped
    # (#1801 run 40390919951 halted saying "21 of 818 tests failed").
    if [[ -s "${state_dir}/runtime/write-boundary-violated" ]]; then
        local _wbv; _wbv="$(<"${state_dir}/runtime/write-boundary-violated")"
        _rsro="${stage} changed files in the repository that it may not change: ${_wbv}"
        return 0
    fi
    _rsro="$_n_reason"
}

# ─── runner_read_stage_verdict_raw <state_dir> <manifest> <stage> <rc> ───────
# Wave 19-A (#717): returns the RAW verdict string from the plugin's primary
# output JSON (e.g. "approve", "request_changes", "block", "pass"), without
# collapsing approve→pass / request_changes→warn.
#
# Why a sibling of runner_read_stage_verdict: the original function returns
# the CLASSIFIED verdict (pass|warn|fail|unknown + structural-failure
# pass-through) which is correct for the operator-facing indicator glyph,
# but the cycle orchestrator's exit_when/abort_when/until predicates compare
# against the RAW value declared in the template (e.g. `value: approve`).
# Without the raw read, exit_when on review.verdict==approve never matches
# because the dispatch blob stores "pass" not "approve" — the dogfood
# 20260605055348-2232 symptom: review approved, but pipeline ran to
# max_iterations instead of converging via exit_when.
#
# Side-effects: NONE here (no events). Callers are expected to ALSO call
# runner_read_stage_verdict in the same dispatch pass (which is what
# cycle_dispatch_stage at runner.sh:~1115 does today: populates
# _CYCLE_DISPATCH_VERDICT via the classified call AND
# _CYCLE_DISPATCH_VERDICT_RAW via this raw call). That ordering ensures
# diagnostic events (stage.verdict.missing, pipeline.indicator.unknown_verdict)
# fire exactly once for the artifact — emitting them here too would double-
# count.
runner_read_stage_verdict_raw() { local _rsw; runner_read_stage_verdict_raw_v _rsw "$@"; printf '%s' "$_rsw"; }
runner_read_stage_verdict_raw_v() {
    local -n _rswo="$1"; shift
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"

    # rc != 0 → no verdict semantics; mirror the classified path's "fail"
    # so cycle predicates evaluating `verdict == fail` still match.
    if [[ "$rc" -ne 0 ]]; then
        _rswo="fail"; return 0
    fi

    local _w_state _w_contract _w_verdict _w_disp _w_reason _w_viol _w_path _w_present _w_kind
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _w

    # A contract violation surfaces as raw `error` here too, so the cycle's raw
    # channel and the classified channel agree — including, since #1850, a
    # dispatch that left no readable result. Side-effect-free: the classified
    # reader already emitted the event for this dispatch pass.
    [[ -n "$_w_viol" ]] || _verdict_unreadable_violation_v _w_viol "$_w_state"
    if [[ -n "$_w_viol" ]]; then _rswo="error"; return 0; fi
    _rswo="$_w_verdict"
}

# ─── runner_read_stage_report <state_dir> <manifest> <stage> <rc> (#2189) ────
# The contract fields the CYCLE acts on, read from the dispatched member's own
# primary result — whichever stage it is. The engine never opens a stage's
# artifact by name (ADR-055 §1): it reads this report off the member it just
# dispatched, so a cycle only ever sees what ITS members reported THIS iteration.
# Prints compact JSON:
#   {changes:{files:[…],added:N,removed:N}?, scope_request:{…}?, not_reproduced:[…]?,
#    tests:{failed:N}? (a numeric failed count), failed_items:[…]? (a failed list),
#    reason:"…"?, scope_files:[…]?, owned_files:[…]?, wiring_files:[…]?}
# Fields are read from `data.*` first, then the legacy top-level names
# (files_changed / lines_added / lines_removed / scope_expansion_request).
runner_read_stage_report() { local _rsp; runner_read_stage_report_v _rsp "$@"; printf '%s' "$_rsp"; }
runner_read_stage_report_v() {
    local -n _rspo="$1"; shift
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"
    local _p_state _p_contract _p_verdict _p_disp _p_reason _p_viol _p_path _p_present _p_kind
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _p
    # Only a result this run wrote has a report (ADR-068 §8).
    [[ "$_p_state" == ok ]] || { _rspo='{}'; return 0; }
    _rspo="$(_verdict_report_from_file "$_p_path")"
}

# ─── runner_read_stage_data_kind <state_dir> <manifest> <stage> ─────────────
# ADR-054: the primary result's data.build_kind, so the cycle can tell the
# empty_diff resting point from a pass without reading the verdict channel.
runner_read_stage_data_kind() { local _rsk; runner_read_stage_data_kind_v _rsk "$@"; [[ -z "$_rsk" ]] || printf '%s\n' "$_rsk"; }
runner_read_stage_data_kind_v() {
    local -n _rsko="$1"; shift
    local state_dir="$1" manifest="$2" stage="$3"
    local _k_state _k_contract _k_verdict _k_disp _k_reason _k_viol _k_path _k_present _k_kind
    _rsko=""
    _verdict_read_result "$state_dir" "$manifest" "$stage" 0 _k
    # Only a result this run wrote says what kind of build it was (ADR-068 §8).
    [[ "$_k_state" == ok ]] || return 0
    _rsko="$_k_kind"
}

# _verdict_report_from_file <result.json> — the extraction runner_read_stage_report
# applies to a member's primary result (split out so cycle-test stubs hand the
# engine exactly what a real dispatch would).
_verdict_report_from_file() {
    local _p_path="$1"
    [[ -s "$_p_path" ]] || { printf '{}'; return 0; }
    jq -c '
        def num($x): if ($x|type) == "number" then $x else 0 end;
        ( .data.changes // (if (.files_changed // null) != null
              then {files: .files_changed, added: num(.lines_added), removed: num(.lines_removed)}
              else null end) ) as $ch
        | ( .data.scope_request // .scope_expansion_request // null ) as $sr
        | ( .data.not_reproduced // null ) as $nr
        | ( .data.failed // .failed // null ) as $fl
        | {} + (if ($fl|type) == "number" then {tests: {failed: $fl}} else {} end)
             + (if ($fl|type) == "array"  then {failed_items: $fl} else {} end)
             + (if ((.reason // null)|type) == "string" then {reason: .reason} else {} end)
             + (if $ch != null then {changes: $ch} else {} end)
             + ((.data.scope_files  // .scope_files  // null) as $x | if ($x|type) == "array" then {scope_files: $x}  else {} end)
             + ((.data.owned_files  // .owned_files  // null) as $x | if ($x|type) == "array" then {owned_files: $x}  else {} end)
             + ((.data.wiring_files // .wiring_files // null) as $x | if ($x|type) == "array" then {wiring_files: $x} else {} end)
             + (if $sr != null then {scope_request: $sr} else {} end)
             + (if $nr != null then {not_reproduced: $nr} else {} end)
    ' "$_p_path" 2>/dev/null || printf '{}'
}

# ─── runner_read_stage_disposition <state_dir> <manifest> <stage> <rc> ───────
# ADR-054 §6 (#1821 exposed the field; #1822 gave it a vocabulary). Resolves the
# disposition for one dispatch. Four outcomes, in precedence order:
#
#   0. The result VIOLATED the contract — a word off the closed set, or any
#      missing mandatory field → `broken`. A stage that wrote an invalid result
#      is defective, and the two channels must not disagree: were this to return
#      the declared word, a caller reading only this channel would be told
#      "throttled, retry" about a result the engine has already rejected as
#      structurally invalid, and would retry it forever. That is precisely the
#      infinite-retry regression #1822's guard names. Nothing is lost — the
#      offending word survives verbatim on the reason channel as
#      `contract_violation:unknown_disposition:<word>`. This is not the invented
#      default the issue forbids: the engine is not guessing a plausible value in
#      order to carry on, it is concluding a defect and halting.
#   1. The stage DECLARED a valid one (v2 result) → that word, verbatim.
#   2. The dispatch DIED and left no readable result → the engine CLASSIFIES it
#      from what it observed (#1823, ADR-054 §4): a rate limit seen on either
#      router path → `throttled`; death by signal or a timeout → `interrupted`;
#      anything else → `broken`. This is the only place the engine is permitted
#      to infer, and it infers a disposition, not a verdict. Before #1823 every
#      one of these was flatly `broken`, which halted a run that had merely been
#      interrupted — the exact failure ADR-054 §6 says `interrupted`/`throttled`
#      exist to prevent. Absent any observation it is still `broken`: a stage
#      that explained nothing cannot be distinguished from a defective one, and
#      guessing "probably transient" is how a real defect retries forever.
#      Nothing is written back to the stage's artifact directory; the conclusion
#      lives on this return value and on the dispatch event.
#
#      The observation arrives as an argument rather than being re-derived here
#      because only the dispatch boundary can take it: `dispatch_rc_observation`
#      needs the raw wait status, and the boundary is where that status exists.
#      This reader does still see a raw rc — the narrowing happens at
#      `cycle_dispatch_stage`'s return, AFTER this pass — which is what lets the
#      legacy-rc branch below read the number. Passing the observation in keeps
#      the two independent: the reader never has to know whether the rc it was
#      handed has been narrowed yet.
#   3. Otherwise → empty. A v1 result declares no disposition, so the response
#      table is not consulted and today's verdict-driven control flow is
#      untouched. That is the versioned coexistence ADR-054 §5 requires, and it
#      is also what keeps ADR-021's unrelated `.disposition` vocabulary
#      (terminal|recoverable|advisory|none) inert — those artifacts are v1.
#
# Note the ordering against rc: a stage that wrote a result and THEN returned
# non-zero keeps its declared word (`plan`'s hand-rolled `return 1` is exactly
# this shape). rc never overwrites a declaration; it only fills the silence.
runner_read_stage_disposition() { local _rsd; runner_read_stage_disposition_v _rsd "$@"; printf '%s' "$_rsd"; }
runner_read_stage_disposition_v() {
    local -n _rsdo="$1"; shift
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"
    local observation="${5-}" rate_limited="${6:-0}"
    local _d_state _d_contract _d_verdict _d_disp _d_reason _d_viol _d_path _d_present _d_kind
    # The engine stopped this stage at its time limit (plugin_hook_call): that
    # is how it ended, whatever it left behind.
    if [[ -f "${state_dir}/runtime/stage-time-limit.${stage//[^A-Za-z0-9._-]/_}" ]]; then
        _rsdo="timed_out"; return 0
    fi
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _d

    # #1850: at rc 0, leaving no readable result is a violation too — the stage
    # said it finished and the engine is holding nothing.
    if [[ -z "$_d_viol" && "$rc" -eq 0 ]]; then
        _verdict_unreadable_violation_v _d_viol "$_d_state"
    fi
    if [[ -n "$_d_viol" ]]; then
        _rsdo="broken"; return 0
    fi
    # #1809 (ADR-058 C9): file-backed markers set by lifecycle.sh after dispatch.
    # Checked between _d_viol and _d_disp so a stage that declared disposition=complete
    # but violated the write boundary or the artifact contract still resolves to broken.
    # File-backed (not a shell global) because the map: arm runs a generated standalone
    # script in a separate process — a global assigned there never reaches this reader.
    if [[ -f "${state_dir}/runtime/write-boundary-violated" ]] || \
       [[ -f "${state_dir}/runtime/artifact-contract-violated" ]]; then
        _rsdo="broken"; return 0
    fi
    # ADR-058 C12 amendment: this stage changed the repository without
    # declaring it may, and its changes were put back. Its output cannot be
    # trusted, so the engine retries it; a second offence wrote the halting
    # marker above instead.
    local _wb_key="${stage:-stage}"; _wb_key="${_wb_key//[^A-Za-z0-9._-]/_}"   # zbuild_stage_key
    if [[ -f "${state_dir}/runtime/write-boundary-reverted.${_wb_key}" ]]; then
        _rsdo="unusable"; return 0
    fi
    if [[ -n "$_d_disp" ]]; then
        # #2111: a rate limit observed on the wire ends the run whatever word
        # the stage chose — a plugin that still says `interrupted`/`throttled`
        # would otherwise be retried into the same limit. #2187: say so with
        # the cause's own word.
        if [[ "$rate_limited" == "1" ]] && disposition_retryable "$_d_disp" 2>/dev/null; then
            _rsdo="rate_limited"; return 0
        fi
        _rsdo="$_d_disp"; return 0
    fi
    if [[ "$rc" -ne 0 ]] && ! _verdict_result_was_readable "$_d_state" "$_d_present"; then
        # The stage died leaving no result: classify how it died. Direct
        # evidence first — a 429 seen on the wire means wait (#2111) — then the
        # observation the dispatch boundary took from the raw wait status. #1850
        # deleted the legacy rc mapping that used to sit between the two: every
        # stage declares its own disposition, so a number has nothing to add.
        if [[ "$rate_limited" == "1" ]]; then _rsdo=unavailable   # dispatch_rc_failure_disposition
        else case "$observation" in signal|timeout) _rsdo=interrupted ;; *) _rsdo=broken ;; esac; fi
        return 0
    fi
    _rsdo=""
}

# ─── _verdict_result_was_readable <state> <present> ─────────────────────────
# Did this dispatch leave a result the engine could actually read? Only `ok` —
# a JSON primary that parsed. Everything else — no manifest, no declared
# primary, a non-JSON primary (no v2 result can live there, and #1850 retired
# the sidecar that once spoke for one), absent, unparseable — means the stage
# left the engine holding nothing, which is #1822's `broken`. <present> is kept
# for the callers' signature.
_verdict_result_was_readable() {
    [[ "${1:-}" == "ok" ]]
}
