#!/usr/bin/env bash
# plugins/agent/build/lib/secrets.sh — build's scan of its own change for secrets
# (#2371; was the secret-scan stage, ADR-040, #1136).
#
# No model: a local scan of the merge-base..HEAD diff for hardcoded
# secrets/credentials and .env files (CLAUDE.md security rules). Where a secret
# is — file, line, rule — is reported; the value never is, because secrets must
# not spread and the finding goes back to a model.
#
# Sourced by plugin.sh after secret-patterns.sh and merge-base.sh.
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_BUILD_SECRETS_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_SECRETS_LOADED=1

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
# True when the offending line carries an inline allowlist pragma. One
# definition, shared with persist's push gate (secret-patterns.sh).
_ss_line_pragma_allowlisted() {
    zbuild_secret_line_allowlisted "$1"
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

# _build_secret_check <repo_root>
# Sets _BUILD_SECRET_FINDINGS (one plain sentence per secret: where, which rule,
# never the value), _BUILD_SECRET_LOCATIONS (file<TAB>line<TAB>rule, the same
# findings as data) and _BUILD_SECRET_OUTCOME: empty when the scan ran, broken
# when the merge-base library did not load (a diff nobody scanned is not clean).
# No baseline or an empty diff is nothing to scan. rc 0.
_build_secret_check() {
    local repo_root="$1" base diff_text findings f l r
    _BUILD_SECRET_FINDINGS=(); _BUILD_SECRET_LOCATIONS=(); _BUILD_SECRET_OUTCOME=""
    if ! declare -F zbuild_resolve_merge_base >/dev/null 2>&1 || [[ -n "${_ZBUILD_CONTRACT_LOAD_ERRORS:-}" ]]; then
        _BUILD_SECRET_OUTCOME=broken
        return 0
    fi
    [[ -n "$repo_root" ]] || return 0
    base="$(zbuild_resolve_merge_base "$repo_root")"
    [[ -n "$base" ]] || return 0
    diff_text="$(git -C "$repo_root" diff "$base..HEAD" 2>/dev/null || true)"
    [[ -n "$diff_text" ]] || return 0
    findings="$(printf '%s\n' "$diff_text" | _ss_scan_diff)"
    while IFS=$'\t' read -r f l r; do
        [[ -n "$f" ]] || continue
        _BUILD_SECRET_LOCATIONS+=("$f"$'\t'"$l"$'\t'"$r")
        if [[ "$r" == env_file ]]; then
            _BUILD_SECRET_FINDINGS+=("a .env secrets file was added at $f; remove it from the change")
        else
            _BUILD_SECRET_FINDINGS+=("a secret-like value ($r) was added at $f:$l; remove it — read it from the environment or configuration instead")
        fi
    done <<< "$findings"
    return 0
}

# _build_stage_run_checked <same args as _build_stage_run_inner>  (#2371)
# Build checks its own change: after a pass that finished, it scans the change
# for secrets. A secret goes back to build's model — where it is, never the
# value — for another pass, until the change is clean or build's rounds
# (config.check_rounds) run out; then build's one outcome is fail, with the
# findings. A pass that did not finish ends the stage as it said.
_build_stage_run_checked() {
    local summary_json="$4"
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local _rounds; _rounds="$(yaml_get "$_BUILD_DIR/manifest.yaml" config.check_rounds 2>/dev/null || true)"
    [[ "$_rounds" =~ ^[1-9][0-9]*$ ]] || _rounds=3
    local _round=1 rc
    _BUILD_CHECK_FOUND=""
    while :; do
        rc=0
        _build_stage_run_inner "$@" || rc=$?
        [[ $rc -eq 0 ]] || { _BUILD_CHECK_FOUND=""; return "$rc"; }
        _build_secret_check "$repo_root"
        if [[ -n "$_BUILD_SECRET_OUTCOME" ]]; then
            stage_result_add "$summary_json" "$_BUILD_SECRET_OUTCOME" "the change could not be scanned for secrets" 2>/dev/null || true
            _BUILD_CHECK_FOUND=""
            return 0
        fi
        [[ ${#_BUILD_SECRET_FINDINGS[@]} -eq 0 ]] && { _BUILD_CHECK_FOUND=""; return 0; }
        emit_event "build.checks.failed" "plugin=build" "round=$_round" "rounds=$_rounds" \
            "findings=${#_BUILD_SECRET_FINDINGS[@]}" 2>/dev/null || true
        if (( _round >= _rounds )); then
            local _fj _tmp
            _fj="$(printf '%s\n' "${_BUILD_SECRET_FINDINGS[@]}" | stage_findings_json)"
            _tmp="$(jq --argjson f "${_fj:-[]}" '.data = ((.data // {}) + {findings: $f})' "$summary_json" 2>/dev/null)" \
                && printf '%s\n' "$_tmp" | atomic_write "$summary_json" || true
            stage_result_add "$summary_json" fail \
                "the change still holds ${#_BUILD_SECRET_FINDINGS[@]} secret(s) after $_rounds rounds" 2>/dev/null || true
            stage_summary_write "$(dirname "$summary_json")/build-summary.md" "build" "fail" \
                "the change still holds ${#_BUILD_SECRET_FINDINGS[@]} secret(s) after $_rounds rounds" \
                "$(printf -- '- %s\n' "${_BUILD_SECRET_FINDINGS[@]}")"
            _BUILD_CHECK_FOUND=""
            return 0
        fi
        _round=$(( _round + 1 ))
        _BUILD_CHECK_FOUND="$(printf '\n### What the check of your change found (round %s of %s)\nYour change was scanned for secrets, and these were found. Remove each one from the change; keep the rest of your work.\n' "$_round" "$_rounds"; printf -- '- %s\n' "${_BUILD_SECRET_FINDINGS[@]}")"
    done
}
