#!/usr/bin/env bash
# core/plugin-registry/attempt-archive.sh — #2183: every dispatch keeps its own
# record.
#
# A stage writes its declared outputs to FIXED paths, so the next dispatch of the
# same stage overwrites them. #1841 run 35802918016: build attempt 1 ended on
# three router timeouts, committed 66259d79 (1 file, +21 lines), was redispatched
# on `disposition: interrupted`, and attempt 2's `changed 0 file(s)` replaced the
# record of what attempt 1 had done. One level up, cycle iteration 2's PASSING
# test-output.log replaced iteration 1's FAILING one inside the same run — the
# failing suite output had to be recovered from a model transcript.
#
# After each run hook the engine copies that stage's DECLARED outputs into
# `<artifact_dir>/attempts/<stage>/iter-<n>-attempt-<m>/`. The live paths do not
# move, so no consumer changes and the newest attempt is still what they read.
# Manifest-driven: the engine copies what the plugin declared, and a plugin that
# declares nothing archives nothing.
#
# Fail-open throughout: bookkeeping never changes a stage's fate.
# Sourced library: inherits the caller's pipefail settings.

[[ -n "${_ZBUILD_ATTEMPT_ARCHIVE_LOADED:-}" ]] && return 0
_ZBUILD_ATTEMPT_ARCHIVE_LOADED=1

# shellcheck source=output-paths.sh
[[ "${BASH_SOURCE[0]}" == */* ]] && _att_dir="${BASH_SOURCE[0]%/*}" || _att_dir="."
source "$_att_dir/output-paths.sh" 2>/dev/null || true
unset _att_dir

# ─── attempt_is_this_run <file> ──────────────────────────────────────────────
# #2252: rc 0 when <file> was written by THIS run — not older than the runner's
# run-start marker (ZBUILD_RUN_START_MARKER). A reused state dir can hold an
# earlier run's files; without the marker (a stage run outside the runner) every
# file present counts.
attempt_is_this_run() {
    local f="$1" m="${ZBUILD_RUN_START_MARKER:-}"
    [[ -s "$f" ]] || return 1
    [[ -n "$m" && -e "$m" ]] || return 0
    [[ "$m" -nt "$f" ]] && return 1
    return 0
}

# ─── attempt_latest_copy <artifact_dir> <basename> ───────────────────────────
# #2252: this run's newest archived copy of <basename>, from any stage's
# attempts. Prints its path; rc 1 when this run archived none. Pure bash
# (glob + -nt), so a reader on the hot path pays no fork.
attempt_latest_copy() {
    local dir="$1" base="$2" f best=""
    [[ -n "$dir" && -n "$base" && -d "$dir/attempts" ]] || return 1
    for f in "$dir"/attempts/*/iter-*-attempt-*/"$base"; do
        attempt_is_this_run "$f" || continue
        if [[ -z "$best" || "$f" -nt "$best" ]]; then best="$f"; fi
    done
    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

# ─── _attempt_manifest_facts_v <var> <manifest> ─────────────────────────────
# One scan of the manifest (#2252: one awk per call, never one per question),
# into <var>:
#   P<TAB><raw path>   every declared output path, unresolved
#   S<TAB><basename>   an output marked `summary: true` — narrative, never work
#   R                  capabilities.writes_repository: true
# A dispatch asks three times (fingerprint before, fingerprint after, archive),
# so the last manifest's answer is kept; manifests do not change during a run.
_ATT_FACTS_FOR=""
_ATT_FACTS=""
# Read by the shell, rule for rule as the awk it replaced (ADR-065 §5): it ran
# in the stage's own process, three times a dispatch.
_attempt_manifest_facts_read_v() {
    local -n _amf="$1"
    local line l in_out=0 in_cap=0 p="" s=0 out=""
    [[ -f "$2" && -r "$2" ]] || { _amf=""; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^outputs:[[:space:]]*$ ]]; then in_out=1; in_cap=0; continue; fi
        if [[ "$line" =~ ^capabilities:[[:space:]]*$ || "$line" =~ ^[a-zA-Z_] ]]; then
            if [[ -n "$p" ]]; then out+="P"$'\t'"$p"$'\n'; (( s )) && out+="S"$'\t'"${p##*/}"$'\n'; fi
            p=""; s=0
            if [[ "$line" =~ ^capabilities:[[:space:]]*$ ]]; then in_cap=1; in_out=0; continue; fi
            in_out=0; in_cap=0
        fi
        (( in_cap )) && [[ "$line" =~ ^[[:space:]]+writes_repository:[[:space:]]*true[[:space:]]*(#.*)?$ ]] && out+="R"$'\n'
        (( in_out )) || continue
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+id: ]]; then
            if [[ -n "$p" ]]; then out+="P"$'\t'"$p"$'\n'; (( s )) && out+="S"$'\t'"${p##*/}"$'\n'; fi
            p=""; s=0
        fi
        if [[ "$line" =~ ^[[:space:]]+path:[[:space:]]* ]]; then
            l="${line:${#BASH_REMATCH[0]}}"
            if [[ "$l" == *#* ]]; then l="${l%%#*}"; l="${l%"${l##*[![:space:]]}"}"; fi
            l="${l#[\"\']}"; p="${l%[\"\']}"
        fi
        [[ "$line" =~ ^[[:space:]]+summary:[[:space:]]*true ]] && s=1
    done < "$2"
    if [[ -n "$p" ]]; then out+="P"$'\t'"$p"$'\n'; (( s )) && out+="S"$'\t'"${p##*/}"$'\n'; fi
    while [[ "$out" == *$'\n' ]]; do out="${out%$'\n'}"; done
    _amf="$out"
}

_attempt_manifest_facts_v() {
    if [[ "$2" != "$_ATT_FACTS_FOR" ]]; then
        _attempt_manifest_facts_read_v _ATT_FACTS "$2"
        _ATT_FACTS_FOR="$2"
    fi
    printf -v "$1" '%s' "$_ATT_FACTS"
}

# ─── attempt_outputs_fingerprint <plugin_dir> <state_file> [before] ─────────
# #2186: "<basename><TAB><cksum|absent>" per declared output. Taken before the
# run hook and compared after it, so the attempt record says which outputs THIS
# dispatch changed. Content-blind: the engine compares bytes, never meaning.
# With [before], an output that had no sum then is not summed now: it reads
# `new`, which differs from anything it could be compared with.
attempt_outputs_fingerprint() {
    local _fp_out
    attempt_outputs_fingerprint_v _fp_out "$@"
    [[ -n "$_fp_out" ]] && printf '%s\n' "$_fp_out"
    return 0
}

# attempt_outputs_fingerprint_v <var> <plugin_dir> <state_file> [before] — the
# same, into <var>: the engine takes it on every run hook, and a `$( )` around
# it copied the whole engine shell (ADR-065 §5).
attempt_outputs_fingerprint_v() {
    local -n _fp_var="$1"; shift
    _fp_var=""
    local _fp_pdir="${1:-}" _fp_sf="${2:-}" _fp_before="${3:-}"
    local manifest="$_fp_pdir/manifest.yaml"
    [[ -s "$manifest" ]] || return 0
    declare -F _registry_resolve_output_path >/dev/null 2>&1 || return 0
    local _fp_sd _fp_ad
    if [[ -n "$_fp_sf" ]]; then _fp_sd="."; [[ "$_fp_sf" == */* ]] && _fp_sd="${_fp_sf%/*}"
    else _fp_sd="${ZBUILD_STATE_DIR:-}"; fi
    [[ -n "$_fp_sd" ]] || return 0
    _fp_ad="${ZBUILD_ARTIFACT_DIR:-$_fp_sd/artifacts}"
    local _k raw resolved sum facts name
    _attempt_manifest_facts_v facts "$manifest"
    while IFS=$'\t' read -r _k raw; do
        [[ "$_k" == P && -n "$raw" ]] || continue
        _registry_resolve_output_path_v resolved "$raw" "$_fp_sd" "$_fp_ad"
        [[ -n "$resolved" ]] || continue
        name="${resolved##*/}"
        # Only a file that is there is summed, and after the run only one that
        # had a sum before: nothing else can compare equal.
        if [[ ! -e "$resolved" ]]; then
            sum="absent"
        elif [[ -n "$_fp_before" && $'\n'"$_fp_before" != *$'\n'"$name"$'\t'[0-9]* ]]; then
            sum="new"
        else
            sum="$(cksum 2>/dev/null < "$resolved" || printf 'absent')"
        fi
        _fp_var+="$name"$'\t'"$sum"$'\n'
    done <<< "$facts"
    # #2252: a stage that writes the repository does its work THERE — its
    # declared outputs are reports of it. One more line fingerprints the tree:
    # HEAD, the status, and the diff against HEAD. No readable HEAD → no line,
    # and the outputs decide as for any other stage.
    if [[ $'\n'"$facts"$'\n' == *$'\nR\n'* ]]; then
        local repo="${ZBUILD_REPO_ROOT:-}" head st df
        if [[ -n "$repo" ]] && head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" && [[ -n "$head" ]]; then
            st="$(git -C "$repo" status --porcelain -uall 2>/dev/null || true)"
            # The diff is hashed as it streams — never held whole in memory
            # (review on #2253); cksum reads all of it, so no early-exit pipe.
            df="$(git -C "$repo" diff HEAD 2>/dev/null | cksum)"
            _fp_var+="__repository__"$'\t'"$(cksum <<< "$head"$'\n'"$st"$'\n'"$df")"$'\n'
        fi
    fi
    _fp_var="${_fp_var%$'\n'}"
}

# ─── attempt_archive_outputs <plugin_dir> <state_file> <stage> [rc] [before] ─
# [before] is attempt_outputs_fingerprint taken before the run hook (#2186).
attempt_archive_outputs() {
    local plugin_dir="${1:-}" state_file="${2:-}" stage="${3:-}" rc="${4:-}" before="${5:-}"
    [[ -n "$plugin_dir" && -n "$stage" ]] || return 0
    declare -F _registry_resolve_output_path >/dev/null 2>&1 || return 0

    local manifest="$plugin_dir/manifest.yaml"
    [[ -s "$manifest" ]] || return 0

    local state_dir artifact_dir
    if [[ -n "$state_file" ]]; then state_dir="."; [[ "$state_file" == */* ]] && state_dir="${state_file%/*}"
    else state_dir="${ZBUILD_STATE_DIR:-}"; fi
    [[ -n "$state_dir" ]] || return 0
    artifact_dir="${ZBUILD_ARTIFACT_DIR:-$state_dir/artifacts}"
    [[ -d "$artifact_dir" ]] || return 0

    # One path component each, so no stage id or iteration can climb out.
    local _safe_stage="${stage//[^A-Za-z0-9_-]/_}"
    local _iter="${ZBUILD_CYCLE_ITER:-0}"
    [[ "$_iter" =~ ^[0-9]+$ ]] || _iter=0

    # The attempt number is the count of attempt dirs already recorded for this
    # (stage, iteration) — derived from disk, so a redispatch in any arm of the
    # engine numbers itself without the engine having to carry a counter.
    local _base="$artifact_dir/attempts/$_safe_stage"
    local _n=0 _d
    for _d in "$_base/iter-${_iter}-attempt-"*; do [[ -d "$_d" ]] && _n=$(( _n + 1 )); done
    local _dest="$_base/iter-${_iter}-attempt-$(( _n + 1 ))"
    mkdir -p "$_dest" 2>/dev/null || return 0

    # EVERY declared output, not only the required ones: the summary and the
    # error channel are `required: false`, and they are most of what a reader of
    # an old attempt wants. _registry_output_path_rows drops those by design (it
    # serves the fail-closed presence scan), so this reads the block itself —
    # one awk per dispatch, no shared index state to be warm or cold.
    local _facts _paths="" _summ="" _fk _fv
    _attempt_manifest_facts_v _facts "$manifest"
    while IFS=$'\t' read -r _fk _fv; do
        case "$_fk" in P) _paths+="$_fv"$'\n' ;; S) _summ+="$_fv"$'\n' ;; esac
    done <<< "$_facts"
    [[ -n "$_paths" ]] || { rmdir "$_dest" 2>/dev/null || true; return 0; }

    local raw resolved copied=0
    while IFS= read -r raw; do
        [[ -n "$raw" ]] || continue
        _registry_resolve_output_path_v resolved "$raw" "$state_dir" "$artifact_dir"
        [[ -n "$resolved" && -e "$resolved" ]] || continue
        # Flattened to the basename: the archive answers "what did this attempt
        # produce", and a declared output's basename is unique within a plugin.
        cp -p "$resolved" "$_dest/${resolved##*/}" 2>/dev/null && copied=$(( copied + 1 ))
    done <<< "$_paths"

    if [[ "$copied" -eq 0 ]]; then
        rmdir "$_dest" 2>/dev/null || true
        return 0
    fi
    # What the copy is OF — the archive is useless without the attempt's own
    # identity, and a reader must not have to infer it from the directory name.
    # `generated_at`, not a private name: the parity check normalises exactly
    # this field, and a per-run timestamp under another name reads as divergence.
    # jq, not printf (review #2184): every other JSON write in the tree escapes
    # its values, and a stage id is interpolated here.
    # #2186: which declared outputs THIS dispatch changed. Without a before
    # fingerprint there is nothing to compare, and the record says nothing.
    local -a _outputs=()
    local _unchanged="" _name _was _now _state _progress="" _after _bn _bs
    if [[ -n "$before" ]]; then
        # #2252: progress is a change to the WORK. For a repository-writing
        # stage that is the tree (__repository__); otherwise any declared output
        # except a narrative summary. A report rewritten every attempt is not it.
        local _repo_stage=0
        [[ $'\n'"$before" == *$'\n__repository__\t'* ]] && _repo_stage=1
        _progress=false
        attempt_outputs_fingerprint_v _after "$plugin_dir" "$state_file" "$before"
        while IFS=$'\t' read -r _name _now; do
            [[ -n "$_name" ]] || continue
            _was=""
            while IFS=$'\t' read -r _bn _bs; do
                [[ "$_bn" == "$_name" ]] && { _was="$_bs"; break; }
            done <<< "$before"
            if [[ "$_now" == "absent" ]]; then _state="absent"
            elif [[ "$_now" == "$_was" ]]; then _state="unchanged"; _unchanged+="${_unchanged:+,}$_name"
            else _state="changed"; fi
            if [[ "$_state" == "changed" ]]; then
                if (( _repo_stage )); then
                    [[ "$_name" == "__repository__" ]] && _progress=true
                elif [[ $'\n'"$_summ" != *$'\n'"$_name"$'\n'* ]]; then
                    _progress=true
                fi
            fi
            _outputs+=("$_name" "$_state")
        done <<< "$_after"
    fi
    # One jq for the whole record: the outputs go in as name/state pairs, and
    # the time is jq's own, in UTC as `date -u` gave it.
    jq -n --arg s "$stage" --argjson i "$_iter" --argjson a "$(( _n + 1 ))" \
          --arg rc "${rc:-}" --argjson f "$copied" --arg pg "$_progress" \
          '($ARGS.positional | [range(0; length; 2) as $j | {(.[$j]): .[$j + 1]}] | add // {}) as $o
           | {stage:$s, cycle_iter:$i, attempt:$a, rc:$rc, generated_at:(now | strftime("%Y-%m-%dT%H:%M:%SZ")), files:$f}
           + (if $o == {} then {} else {outputs:$o} end)
           + (if $pg == "" then {} else {progress:($pg == "true")} end)' \
          --args "${_outputs[@]+"${_outputs[@]}"}" \
        > "$_dest/attempt.json" 2>/dev/null || true
    if [[ -n "$_unchanged" ]] && declare -F emit_event >/dev/null 2>&1; then
        emit_event "stage.outputs.unchanged" "stage=$stage" "iter=$_iter" \
            "attempt=$(( _n + 1 ))" "outputs=$_unchanged" >/dev/null 2>&1 || true
    fi
    return 0
}
