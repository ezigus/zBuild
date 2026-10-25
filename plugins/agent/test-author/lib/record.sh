#!/usr/bin/env bash
# plugins/agent/test-author/lib/record.sh — test-author records the assertions it
# wrote: a digest of each testfile and a copy of its bytes (#2022, #2163), so a
# later edit can be undone. (#2372: the check that compared them was the
# assertion-integrity stage; test now compares the testfiles' content against the
# fingerprints test-author's own result carries, data.testfiles.)
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TA_RECORD_LOADED:-}" ]] && return 0
_ZBUILD_TA_RECORD_LOADED=1
# shellcheck source=../../../../scripts/lib/earlier-output.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../../../.." && pwd)/scripts/lib/earlier-output.sh"

_AI_DIGESTS="assertion-digests.txt"
_AI_COPIES="authored-testfiles"

_ai_digest_of() {
    [[ -f "$1" ]] || { printf 'ABSENT'; return 0; }
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || printf 'UNREADABLE'
}

# ─── assertion_integrity_record <artifact_dir> <repo_root> ───────────────────
# Records the digest of every declared TESTFILE. Called by the stage that
# AUTHORS the assertions, immediately after it writes them — the recorded state
# is by definition the author's, so any later difference is someone else's edit.
# The acceptance contract is found among the earlier outputs by what it is (#2364).
assertion_integrity_record() {
    local art="${1:-}" repo="${2:-}" design
    [[ -n "$art" && -n "$repo" ]] || return 0
    design="$(earlier_acceptance_contract "$art" 2>/dev/null || true)"
    [[ -n "$design" && -f "$design" ]] || return 0
    declare -f acceptance_list_testfiles >/dev/null 2>&1 || return 0
    local tf out=""
    # #2163: keep the authored BYTES too, under authored-testfiles/<path>, so a
    # modified file can be restored (by the stage that owns repo writes) instead
    # of only being reported. A digest can prove a change; only a copy can undo it.
    rm -rf "${art:?}/${_AI_COPIES:?}" 2>/dev/null || true
    while IFS= read -r tf; do
        [[ -n "$tf" ]] || continue
        out="${out}$(_ai_digest_of "$repo/$tf")  $tf"$'\n'
        if [[ -f "$repo/$tf" ]]; then
            mkdir -p "$art/$_AI_COPIES/$(dirname "$tf")" 2>/dev/null || true
            cp -p "$repo/$tf" "$art/$_AI_COPIES/$tf" 2>/dev/null || true
        fi
    done < <(acceptance_list_testfiles "$design" 2>/dev/null || true)
    [[ -n "$out" ]] || return 0
    # #2180: record WHICH stage authored these files. The engine resolves the
    # owner of a finding about one of them from this line, so a criticism of an
    # assertion reaches the stage that can change it. The caller is that stage.
    printf '# authored_by: %s\n%s' "${ZBUILD_CURRENT_STAGE:-}" "$out" \
        > "$art/$_AI_DIGESTS" 2>/dev/null || true
}

