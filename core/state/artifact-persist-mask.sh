#!/usr/bin/env bash
# core/state/artifact-persist-mask.sh — the engine's own tokens never leave the
# machine in a saved, pushed or uploaded file, and a refused push says why
# (#2588, ADR-050). Sourced by artifact-persist.sh; split out to keep that file
# from growing.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_ARTIFACT_PERSIST_MASK_LOADED:-}" ]] && return 0
_ZBUILD_ARTIFACT_PERSIST_MASK_LOADED=1

# _artifact_persist_own_tokens_v <array_var> — the engine's own secrets as
# they are in this process: the job's GitHub tokens and the model provider's
# keys (each 20+ characters; a shorter value is not a real one).
_artifact_persist_own_tokens_v() {
    local -n _aot="$1"; local v
    _aot=()
    for v in "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${GH_ENTERPRISE_TOKEN:-}" "${GITHUB_ENTERPRISE_TOKEN:-}" \
             "${CLAUDE_CODE_OAUTH_TOKEN:-}" "${ANTHROPIC_API_KEY:-}"; do
        (( ${#v} >= 20 )) || continue
        # One grep per value: GH_TOKEN and GITHUB_TOKEN are often the same.
        [[ " ${_aot[*]-} " == *" $v "* ]] || _aot+=("$v")
    done
    return 0
}

# _artifact_persist_push_reason_v <var> <stderr_file> — git push's stderr as
# one line that keeps GitHub's words (#2588): "remote:" prefixes, blank lines
# and banner rules (rows of dashes) set aside, the job's own token masked,
# capped at 1500 characters. The old 300-character cut kept only the banner of
# a push-protection refusal (#2532 run 45102665787).
_artifact_persist_push_reason_v() {
    local -n _apr="$1"; local _f="$2" l out="" v
    _apr=""
    [[ -r "$_f" ]] || return 0
    while IFS= read -r l || [[ -n "$l" ]]; do
        l="${l#remote:}"; l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
        [[ -n "$l" ]] || continue
        [[ "${l//[—─=\-[:space:]]/}" == "" ]] && continue
        l="${l//—/}"; l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
        out+="${out:+ | }$l"
    done < "$_f"
    local -a _aprv=(); _artifact_persist_own_tokens_v _aprv
    for v in ${_aprv[@]+"${_aprv[@]}"}; do out="${out//"$v"/<secret>}"; done
    (( ${#out} > 1500 )) && out="${out:0:1500}…"
    _apr="$out"
}

# ─── _artifact_persist_mask_secrets <dir> (#2588, ADR-050) ───────────────────
# The engine's own credentials (_artifact_persist_own_tokens_v) are replaced by <secret> in every file
# under <dir> before anything leaves the machine. A test or a stage that printed
# the job's token (#2532 run 45102665787) is then saved without it, instead of
# the push being refused (or, as there, GitHub revoking the token). Any other
# credential is left for the scan to refuse. One fixed-string grep per token.
_artifact_persist_mask_secrets() {
    local dir="${1%/}" f body v
    [[ -d "$dir" ]] || return 0
    local -a vals=(); _artifact_persist_own_tokens_v vals
    (( ${#vals[@]} > 0 )) || return 0
    for v in "${vals[@]}"; do
        while IFS= read -r -d '' f; do
            [[ -f "$f" ]] || continue
            IFS= read -r -d '' body < "$f" || true
            # Written whole, then moved over: never a half-written file.
            printf '%s' "${body//"$v"/<secret>}" > "$f.zbmask.$$" && mv -f "$f.zbmask.$$" "$f" || rm -f "$f.zbmask.$$"
        done < <(grep -rIlF --null -e "$v" -- "$dir" 2>/dev/null)
    done
    return 0
}
