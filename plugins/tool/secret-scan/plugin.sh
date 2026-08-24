#!/usr/bin/env bash
# plugins/tool/secret-scan/plugin.sh — Secret Scan Gate (ADR-040, issue #1136)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-004 redaction-chokepoint is irrelevant here
# because this stage never sends text to a model; it is a purely local scan.)
# Blocks when hardcoded secrets/credentials or .env files are introduced in the
# merge-base..HEAD diff (CLAUDE.md security rules). Writes verdict to
# secret-scan-result.json and ALWAYS returns 0 (ADR-040 verdict-in-artifact
# convention, mirrors shape-floor).
#
# Hook prefix: secret_scan_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_SECRET_SCAN_LOADED:-}" ]] && return 0
_ZBUILD_SECRET_SCAN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_SS_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_SS_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# #1783: source via the contract-reader seam — merge-base resolution decides the
# baseline this scan diffs against, so it belongs to the same seam.
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/merge-base.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
# shellcheck source=../../../scripts/lib/secret-patterns.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/secret-patterns.sh"

_ss_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── _ss_scan_content ─────────────────────────────────────────────────────────
# Conservative secret matcher for a single added line. Echoes a rule name and
# returns 0 on a match, returns 1 (silent) otherwise. The PEM header pattern is
# assembled from fragments so this file's own source never contains the literal
# header string — that would otherwise let the gate flag its own plugin.sh.
# #1071: the patterns moved to scripts/lib/secret-patterns.sh when the persist
# stage became a second consumer. This stays as the plugin-local name every
# call site in this file already uses.
_ss_scan_content() { zbuild_scan_secret_content "$@"; }

# ─── _ss_path_is_env ──────────────────────────────────────────────────────────
# True (rc=0) when the path is a real .env secrets file. Example/template
# variants (.env.example/.sample/.template/.dist) are excluded — they are the
# documented, secret-free counterparts.
_ss_path_is_env() {
    local base="${1##*/}"
    case "$base" in
        .env.example | .env.sample | .env.template | .env.dist | .env.*.example) return 1 ;;
    esac
    case "$base" in
        .env | .env.* | *.env) return 0 ;;
    esac
    return 1
}

# ─── _ss_path_allowlisted ─────────────────────────────────────────────────────
# True when the diff path matches a glob in ZBUILD_SECRET_SCAN_ALLOWLIST_FILE
# (one pattern per line; '#' comments and blank lines ignored). The allowlist is
# the documented escape hatch for obvious test fixtures / example creds.
_ss_path_allowlisted() {
    local p="$1"
    local f="${ZBUILD_SECRET_SCAN_ALLOWLIST_FILE:-}"
    [[ -z "$f" || ! -f "$f" ]] && return 1
    local pat
    while IFS= read -r pat || [[ -n "$pat" ]]; do
        pat="${pat%$'\r'}"
        [[ -z "$pat" || "$pat" == \#* ]] && continue
        # Glob match (unquoted RHS) against the diff path.
        # shellcheck disable=SC2053
        [[ "$p" == $pat ]] && return 0
    done < "$f"
    return 1
}

# ─── _ss_line_pragma_allowlisted ──────────────────────────────────────────────
# True when the offending line carries an inline allowlist pragma. Mirrors the
# common detect-secrets idiom so a deliberate fixture can opt out in place.
_ss_line_pragma_allowlisted() {
    case "$1" in
        *"allowlist secret"* | *"secret-scan:allow"*) return 0 ;;
    esac
    return 1
}

# ─── _ss_scan_diff ────────────────────────────────────────────────────────────
# Reads a unified diff on stdin and prints one `file<TAB>line<TAB>rule` record
# per finding. Tracks the new-file line number from @@ hunk headers; checks each
# added (+) line against _ss_scan_content and each new file path against
# _ss_path_is_env. Allowlisted paths / pragma'd lines are skipped.
_ss_scan_diff() {
    local line current_file="" new_lineno=0 hunk content rule
    while IFS= read -r line; do
        case "$line" in
            "+++ "*)
                current_file="${line#+++ }"
                current_file="${current_file#b/}"
                [[ "$current_file" == "/dev/null" ]] && { current_file=""; continue; }
                if _ss_path_is_env "$current_file" && ! _ss_path_allowlisted "$current_file"; then
                    printf '%s\t0\tenv_file\n' "$current_file"
                fi
                continue
                ;;
            "--- "*) continue ;;
            "@@ "*)
                # @@ -a,b +c,d @@ → start counting new-file lines at c.
                hunk="${line#@@ -}"
                hunk="${hunk#*+}"
                new_lineno="${hunk%%,*}"
                new_lineno="${new_lineno%% *}"
                [[ "$new_lineno" =~ ^[0-9]+$ ]] || new_lineno=0
                continue
                ;;
            "+"*)
                content="${line:1}"
                if [[ -n "$current_file" ]] && ! _ss_path_allowlisted "$current_file" \
                    && ! _ss_line_pragma_allowlisted "$content"; then
                    if rule="$(_ss_scan_content "$content")"; then
                        printf '%s\t%s\t%s\n' "$current_file" "$new_lineno" "$rule"
                    fi
                fi
                new_lineno=$((new_lineno + 1))
                ;;
            " "*) new_lineno=$((new_lineno + 1)) ;;
            *) : ;; # removed (-) lines and metadata advance nothing
        esac
    done
}

# ─── secret_scan_run ──────────────────────────────────────────────────────────
# Scans the merge-base..HEAD diff. Writes verdict (fail|pass|skip) to
# secret-scan-result.json and ALWAYS returns 0.
# Args: $1 = stage_id, $2 = state_file
secret_scan_run() {
    local stage_id="${1:-secret-scan}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-ss-artifacts}"
    fi
    mkdir -p "$artifacts_dir"
    local result_path="$artifacts_dir/secret-scan-result.json"

    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo)}"
    local base=""
    [[ -n "$repo_root" ]] && base="$(zbuild_resolve_merge_base "$repo_root")"

    # No baseline → nothing to compare; skip rather than block.
    if [[ -z "$repo_root" || -z "$base" ]]; then
        printf '{"verdict":"skip","reason":"no_baseline","baseline":"","finding_count":0,"findings":[]}\n' \
            | atomic_write "$result_path"
        _ss_emit "secret_scan.skip" "reason=no_baseline"
        _ss_emit "plugin.result" "plugin=secret-scan" "verdict=skip"
        return 0
    fi

    local diff_text
    diff_text="$(git -C "$repo_root" diff "$base..HEAD" 2>/dev/null || true)"

    # Empty diff → skip.
    if [[ -z "$diff_text" ]]; then
        printf '{"verdict":"skip","reason":"empty_diff","baseline":"%s","finding_count":0,"findings":[]}\n' "$base" \
            | atomic_write "$result_path"
        _ss_emit "secret_scan.skip" "reason=empty_diff"
        _ss_emit "plugin.result" "plugin=secret-scan" "verdict=skip"
        return 0
    fi

    local findings
    findings="$(printf '%s\n' "$diff_text" | _ss_scan_diff)"

    if [[ -n "$findings" ]]; then
        # Build the findings[] JSON from the file<TAB>line<TAB>rule records.
        local findings_json
        findings_json="$(printf '%s\n' "$findings" \
            | jq -R 'select(length>0) | split("\t") | {file:.[0], line:(.[1]|tonumber), rule:.[2]}' \
            | jq -sc .)"
        local count
        count="$(printf '%s\n' "$findings_json" | jq 'length')"
        jq -n --arg base "$base" --argjson n "$count" --argjson f "$findings_json" \
            '{verdict:"fail", reason:"secret_found", baseline:$base, finding_count:$n, findings:$f}' \
            | atomic_write "$result_path"
        _ss_emit "secret_scan.fail" "finding_count=$count"
        _ss_emit "plugin.result" "plugin=secret-scan" "verdict=fail"
        return 0
    fi

    printf '{"verdict":"pass","reason":"clean","baseline":"%s","finding_count":0,"findings":[]}\n' "$base" \
        | atomic_write "$result_path"
    _ss_emit "secret_scan.pass"
    _ss_emit "plugin.result" "plugin=secret-scan" "verdict=pass"
    return 0
}

# ─── secret_scan_cleanup ──────────────────────────────────────────────────────
secret_scan_cleanup() {
    # No self-emit (#1705): plugin_hook_call already brackets this hook with
    # plugin.cleanup.start/complete. A second pair from here is the same
    # two-emitters-one-name collision the run pair was filed for.
    return 0
}
