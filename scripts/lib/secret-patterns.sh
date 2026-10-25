#!/usr/bin/env bash
# scripts/lib/secret-patterns.sh — the one definition of "does this text look
# like a credential?"
#
# Extracted from plugins/tool/secret-scan (#1755) because a SECOND consumer
# appeared: the persist stage (#1071) pushes a run's artifacts to a remote, and
# "about to leave this machine" is exactly when this question needs asking.
#
# Extracted rather than cross-called, per #1809's precedent — a boundary whose
# two halves disagree about what counts as a secret is not a boundary. The
# patterns were calibrated against this repository in #1755 (the issue's premise
# was false until they were MEASURED, not read), so they must not drift.
#
# NOTE: `apply_scope_redaction` is NOT this. That is a SCOPE filter for
# LLM-bound text — it restricts which file paths a prompt may mention. It does
# not scrub credentials, and reaching for it here would be security theatre.

[[ -n "${_ZBUILD_SECRET_PATTERNS_LOADED:-}" ]] && return 0
_ZBUILD_SECRET_PATTERNS_LOADED=1

# The patterns, defined once for the per-content scan and the whole-dir
# prefilter. AWS access-key id: AKIA followed by exactly 16 base32-ish chars.
_ZB_SECRET_AWS_RE='AKIA[0-9A-Z]{16}'
# PEM private-key header (-----BEGIN ... PRIVATE KEY-----), fragments joined
# to keep the literal out of this source file.
_ZB_SECRET_PEM_RE="-----""BEGIN [A-Z0-9 ]*PRIVATE"" KEY-----"
# High-entropy credential assignment (quoted or unquoted, #1755), matched
# case-insensitively. The value must be a single contiguous run of >=8
# non-space characters, and the whitespace exclusion is what makes the rest of
# the guard hold: `[[:space:]]*` can match zero characters, so without it the
# leading `[^$...]` happily consumes the space in `token: ${{ secrets.X }}` and
# the variable-reference exclusion is defeated — that alone flagged every
# workflow env block in this repo. Parens and commas are excluded too: no real
# credential contains them, but `token = substr(rest, RSTART)` does. 8-char
# minimum keeps bare `keyword=` references from matching. The optional quote
# BEFORE the delimiter is for JSON keys: `"api_key": "v..."`.
_ZB_SECRET_CRED_RE=$'(api[_-]?key|secret|token|password|passwd)[\'"]?[[:space:]]*[:=][[:space:]]*[\'"]?[^$\'"[:space:](),][^[:space:]\'"(),]{7,}'

# ─── zbuild_scan_secret_content <content> ────────────────────────────────────
# Echo a finding KIND and return 0 when the content looks like it carries a
# credential; return 1 (silent) when it does not.
zbuild_scan_secret_content() {
    local content="$1"

    if grep -qE -- "$_ZB_SECRET_AWS_RE" <<< "$content"; then
        printf 'aws_access_key_id'
        return 0
    fi

    if grep -qE -- "$_ZB_SECRET_PEM_RE" <<< "$content"; then
        printf 'private_key_header'
        return 0
    fi

    if grep -qiE -- "$_ZB_SECRET_CRED_RE" <<< "$content"; then
        printf 'credential_assignment'
        return 0
    fi

    return 1
}

# ─── zbuild_secret_candidate_files <dir> ─────────────────────────────────────
# Every text file under <dir> that a pattern matches, NUL-separated: two greps
# over the whole dir (the credential pattern is the case-insensitive one), so a
# clean dir costs nothing per file. Binary files are skipped (-I).
zbuild_secret_candidate_files() {
    grep -rIl --null -E -e "$_ZB_SECRET_AWS_RE" -e "$_ZB_SECRET_PEM_RE" -- "$1" 2>/dev/null
    grep -rIl --null -iE -e "$_ZB_SECRET_CRED_RE" -- "$1" 2>/dev/null
    return 0
}

# ─── zbuild_secret_line_allowlisted <line> ───────────────────────────────────
# The inline opt-out both the secret-scan gate and persist honour (the common
# detect-secrets idiom), so a deliberate fixture is allowed in one place.
zbuild_secret_line_allowlisted() {
    case "${1-}" in
        *"allowlist secret"* | *"secret-scan:allow"*) return 0 ;;
    esac
    return 1
}

# ─── zbuild_secret_matching_lines <content> ──────────────────────────────────
# Each line of <content> that zbuild_scan_secret_content flags on its own. Lets
# a caller judge a finding line by line instead of condemning the whole file.
zbuild_secret_matching_lines() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        zbuild_scan_secret_content "$line" >/dev/null && printf '%s\n' "$line"
    done <<< "${1-}"
    return 0
}
