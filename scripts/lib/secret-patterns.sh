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

# ─── zbuild_scan_secret_content <content> ────────────────────────────────────
# Echo a finding KIND and return 0 when the content looks like it carries a
# credential; return 1 (silent) when it does not.
zbuild_scan_secret_content() {
    local content="$1"

    # AWS access-key id: AKIA followed by exactly 16 base32-ish chars.
    if grep -qE 'AKIA[0-9A-Z]{16}' <<< "$content"; then
        printf 'aws_access_key_id'
        return 0
    fi

    # PEM private-key header (-----BEGIN ... PRIVATE KEY-----), fragments joined
    # at runtime to keep the literal out of this source file.
    local _begin='BEGIN' _pk='PRIVATE'' KEY'
    if grep -qE -- "-----${_begin} [A-Z0-9 ]*${_pk}-----" <<< "$content"; then
        printf 'private_key_header'
        return 0
    fi

    # High-entropy credential assignment (quoted or unquoted, #1755). The value
    # must be a single contiguous run of >=8 non-space characters, and the
    # whitespace exclusion is what makes the rest of the guard hold:
    # `[[:space:]]*` can match zero characters, so without it the leading
    # `[^$...]` happily consumes the space in `token: ${{ secrets.X }}` and the
    # variable-reference exclusion is defeated — that alone flagged every
    # workflow env block in this repo. Parens and commas are excluded too: no
    # real credential contains them, but `token = substr(rest, RSTART)` does.
    # 8-char minimum keeps bare `keyword=` references from matching. The
    # optional quote BEFORE the delimiter is for JSON keys: `"api_key": "v..."`.
    local _cred_re
    _cred_re=$'(api[_-]?key|secret|token|password|passwd)[\'"]?[[:space:]]*[:=][[:space:]]*[\'"]?[^$\'"[:space:](),][^[:space:]\'"(),]{7,}'
    if grep -qiE -- "$_cred_re" <<< "$content"; then
        printf 'credential_assignment'
        return 0
    fi

    return 1
}
