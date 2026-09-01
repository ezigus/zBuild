#!/usr/bin/env bash
# plugins/tool/assertion-integrity/plugin.sh — the assertion boundary's backstop
# (#2022, ADR-036, ADR-054).
#
# Kind: tool  (NO LLM — ADR-040 §5: only a mechanical stage may gate.)
# Build is denied Edit() on the acceptance TESTFILES at the spawn, but #1919 P5
# measured that a Write(...) deny rule matches nothing, so prevention is
# incomplete BY CONSTRUCTION. This compares the files against the digests the
# author stage recorded and fails the cycle when they differ.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_ASSERTION_INTEGRITY_LOADED:-}" ]] && return 0
_ZBUILD_ASSERTION_INTEGRITY_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_AI_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_AI_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true

_ai_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

_AI_DIGESTS="assertion-digests.txt"

_ai_digest_of() {
    [[ -f "$1" ]] || { printf 'ABSENT'; return 0; }
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || printf 'UNREADABLE'
}

# ─── assertion_integrity_record <artifact_dir> <repo_root> ───────────────────
# Records the digest of every declared TESTFILE. Called by the stage that
# AUTHORS the assertions, immediately after it writes them — the recorded state
# is by definition the author's, so any later difference is someone else's edit.
assertion_integrity_record() {
    local art="${1:-}" repo="${2:-}"
    [[ -n "$art" && -n "$repo" ]] || return 0
    local design="$art/design.md"
    [[ -f "$design" ]] || return 0
    declare -f acceptance_list_testfiles >/dev/null 2>&1 || return 0
    local tf out=""
    while IFS= read -r tf; do
        [[ -n "$tf" ]] || continue
        out="${out}$(_ai_digest_of "$repo/$tf")  $tf"$'\n'
    done < <(acceptance_list_testfiles "$design" 2>/dev/null || true)
    [[ -n "$out" ]] || return 0
    printf '%s' "$out" > "$art/$_AI_DIGESTS" 2>/dev/null || true
}

# ─── assertion_integrity_run <stage_id> <state_file> ─────────────────────────
# ADR-054 §4: rc is binary. Finding a violation is rc=0 with verdict=fail — the
# stage ran fine, the VERDICT carries the bad news (§6). A nonzero rc here would
# say "this stage is broken", which is a different and false claim.
assertion_integrity_run() {
    local stage_id="${1:-assertion-integrity}"; : "$stage_id"
    local state_file="${2:-}"

    local art
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        art="$(dirname "$state_file")/artifacts"
    else
        art="${ZBUILD_ARTIFACT_DIR:-}"
    fi
    [[ -n "$art" ]] || return 1
    mkdir -p "$art" 2>/dev/null || true

    local repo="${ZBUILD_REPO_ROOT:-$_AI_ROOT}"
    local rec="$art/$_AI_DIGESTS"
    local verdict reason violated=""

    if [[ ! -s "$rec" ]]; then
        # Nothing to compare against. A run whose author stage has not yet run
        # has no boundary to violate, and failing closed here would stall the
        # cycle on the first iteration for a condition that is not a defect.
        verdict="skip"
        reason="no recorded assertion digests — the author stage has not run yet"
    else
        local line want got path
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            want="${line%% *}"
            path="${line##*  }"
            got="$(_ai_digest_of "$repo/$path")"
            [[ "$want" == "$got" ]] || violated="${violated}${path} "
        done < "$rec"
        if [[ -n "$violated" ]]; then
            verdict="fail"
            reason="acceptance assertions modified after authoring: ${violated% }"
            _ai_emit "assertion_integrity.violation" "files=${violated% }"
        else
            verdict="pass"
            reason="declared acceptance testfiles are unchanged since authoring"
        fi
    fi

    # ADR-054 §5/§6: one result file; disposition describes how the STAGE
    # stopped, not what it concluded. This stage completed either way.
    if ! jq -n --arg v "$verdict" --arg r "$reason" --arg f "${violated% }" \
        '{result_contract: 2, verdict: $v, disposition: "complete", reason: $r,
          data: {violated: (if $f == "" then [] else ($f | split(" ")) end)}}' \
        | atomic_write "$art/assertion-integrity-result.json"; then
        _ai_emit "assertion_integrity.result.write_failed" "dir=$art"
    fi

    stage_summary_write "$art/assertion-integrity-summary.md" "assertion-integrity" "$verdict" \
        "$reason" \
        "$(printf -- '- files checked against the authored digests\n- violations: %s' \
            "${violated:-none}")"
    return 0
}

assertion_integrity_cleanup() { return 0; }
