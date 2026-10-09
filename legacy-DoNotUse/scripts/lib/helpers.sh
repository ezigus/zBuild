#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   shipwright shared helpers — Colors, output, events, timestamps
#   Source this from any script: source "$SCRIPT_DIR/lib/helpers.sh"
# ═══════════════════════════════════════════════════════════════════
#
# Exit code convention:
#   0 — success / nothing to do
#   1 — error (invalid args, missing deps, runtime failure)
#   2 — check condition failed (regressions found, quality below threshold, etc.)
#         Callers should distinguish: exit 1 = broken, exit 2 = check negative
#
# This is the canonical reference for common boilerplate that was
# previously duplicated across 18+ scripts. Existing scripts are NOT
# being modified to source this (too risky for a sweep), but all NEW
# scripts should source this instead of copy-pasting the boilerplate.
#
# Provides:
#   - Color definitions (respects NO_COLOR)
#   - Output helpers: info(), success(), warn(), error()
#   - Timestamp helpers: now_iso(), now_epoch()
#   - Event logging: emit_event()
#
# Usage in new scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/helpers.sh"
#   # Optional: source "$SCRIPT_DIR/lib/compat.sh" for platform helpers

# ─── Double-source guard ─────────────────────────────────────────
[[ -n "${_SW_HELPERS_LOADED:-}" ]] && return 0
_SW_HELPERS_LOADED=1

# ─── Colors (matches Seth's tmux theme) ──────────────────────────
if [[ -z "${NO_COLOR:-}" ]]; then
    CYAN='\033[38;2;0;212;255m'     # #00d4ff — primary accent
    PURPLE='\033[38;2;124;58;237m'  # #7c3aed — secondary
    BLUE='\033[38;2;0;102;255m'     # #0066ff — tertiary
    GREEN='\033[38;2;74;222;128m'   # success
    YELLOW='\033[38;2;250;204;21m'  # warning
    RED='\033[38;2;248;113;113m'    # error
    DIM='\033[2m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    CYAN='' PURPLE='' BLUE='' GREEN='' YELLOW='' RED='' DIM='' BOLD='' RESET=''
fi

# ─── Output Helpers ──────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── String Helpers ──────────────────────────────────────────────
# Trim leading/trailing whitespace without xargs (which chokes on quotes).
_trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ─── Timestamp Helpers ───────────────────────────────────────────
now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# ─── Structured Event Log ────────────────────────────────────────
# Appends JSON events to ~/.shipwright/events.jsonl for metrics/traceability
EVENTS_FILE="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

# Memoized repo slug for emit_event. Assignment must happen outside subshells so the
# cached value persists across calls within the same shell session.
_EMIT_REPO_SLUG=""

emit_event() {
    local event_type="$1"
    shift

    # Memoize repo slug in parent shell (not inside $(...)) so cache actually persists.
    if [[ -z "$_EMIT_REPO_SLUG" ]]; then
        _EMIT_REPO_SLUG=$(_sw_detect_repo_slug 2>/dev/null || _sw_repo_hash 2>/dev/null || echo "unknown")
    fi
    # Inject repo only when no caller-supplied repo= key is already present.
    local _has_repo=0
    local _kv
    for _kv in "$@"; do
        if [[ "${_kv%%=*}" == "repo" ]]; then
            _has_repo=1
            break
        fi
    done
    if [[ $_has_repo -eq 0 ]]; then
        set -- "repo=${_EMIT_REPO_SLUG}" "$@"
    fi

    # Try SQLite first (via sw-db.sh's db_add_event)
    if type db_add_event >/dev/null 2>&1; then
        db_add_event "$event_type" "$@" 2>/dev/null || true
    fi

    # Always write to JSONL (dual-write period for backward compat)
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            val="${val//\\/\\\\}"       # escape backslashes first
            val="${val//\"/\\\"}"       # then quotes
            val="${val//$'\n'/\\n}"     # then newlines
            val="${val//$'\t'/\\t}"     # then tabs
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "${HOME}/.shipwright"
    local _event_line="{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}"
    # Use flock to prevent concurrent write corruption
    local _lock_file="${EVENTS_FILE}.lock"
    (
        if command -v flock >/dev/null 2>&1; then
            if ! flock -w 2 200 2>/dev/null; then
                echo "WARN: emit_event lock timeout — concurrent write possible" >&2
            fi
        fi
        echo "$_event_line" >> "$EVENTS_FILE"
    ) 200>"$_lock_file"

    # Schema validation — auto-detect config repo from BASH_SOURCE location
    local _schema_dir="${_CONFIG_REPO_DIR:-}"
    if [[ -z "$_schema_dir" ]]; then
        local _helpers_dir
        _helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
        if [[ -n "$_helpers_dir" && -f "${_helpers_dir}/../../config/event-schema.json" ]]; then
            _schema_dir="$(cd "${_helpers_dir}/../.." && pwd)"
        fi
    fi
    if [[ -n "$_schema_dir" && -f "${_schema_dir}/config/event-schema.json" ]]; then
        local known_types
        known_types=$(jq -r '.event_types | keys[]' "${_schema_dir}/config/event-schema.json" 2>/dev/null || true)
        if [[ -n "$known_types" ]] && ! echo "$known_types" | grep -qx "$event_type"; then
            # Warn-only: never reject events, just log to stderr on first unknown type per session
            if [[ -z "${_SW_SCHEMA_WARNED:-}" ]]; then
                echo "WARN: Unknown event type '$event_type' — update config/event-schema.json" >&2
                _SW_SCHEMA_WARNED=1
            fi
        fi
    fi
}

# Rotate a JSONL file to keep it within max_lines.
# Usage: rotate_jsonl <file> <max_lines>
# ─── Retry Helper ─────────────────────────────────────────────────
# Retries a command with exponential backoff for transient failures.
# Usage: with_retry <max_attempts> <command> [args...]
with_retry() {
    local max_attempts="${1:-3}"
    shift
    local attempt=1
    local delay=1
    while [[ "$attempt" -le "$max_attempts" ]]; do
        "$@" && return 0
        local exit_code=$?
        if [[ "$attempt" -lt "$max_attempts" ]]; then
            warn "Attempt $attempt/$max_attempts failed (exit $exit_code), retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
            [[ "$delay" -gt 30 ]] && delay=30
        fi
        attempt=$((attempt + 1))
    done
    error "All $max_attempts attempts failed"
    return 1
}

# ─── JSON Validation + Recovery ───────────────────────────────────
# Validates a JSON file and recovers from backup if corrupt.
# Usage: validate_json <file> [backup_suffix]
validate_json() {
    local file="$1"
    local backup_suffix="${2:-.bak}"
    [[ ! -f "$file" ]] && return 0

    if jq '.' "$file" >/dev/null 2>&1; then
        # Valid — create backup
        cp "$file" "${file}${backup_suffix}" 2>/dev/null || true
        return 0
    fi

    # Corrupt — try to recover from backup
    warn "Corrupt JSON detected: $file"
    if [[ -f "${file}${backup_suffix}" ]] && jq '.' "${file}${backup_suffix}" >/dev/null 2>&1; then
        cp "${file}${backup_suffix}" "$file"
        warn "Recovered from backup: ${file}${backup_suffix}"
        return 0
    fi

    error "No valid backup for $file — manual intervention needed"
    return 1
}

rotate_jsonl() {
    local file="$1"
    local max_lines="${2:-10000}"
    [[ ! -f "$file" ]] && return 0
    local current_lines
    current_lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    if [[ "$current_lines" -gt "$max_lines" ]]; then
        local tmp_rotate
        tmp_rotate=$(mktemp)
        tail -n "$max_lines" "$file" > "$tmp_rotate" && mv "$tmp_rotate" "$file" || rm -f "$tmp_rotate"
    fi
}

# ─── Atomic Write Helpers ────────────────────────────────────────
# atomic_write: Write data to a file atomically (write to tmp, validate, mv)
# Usage: atomic_write <target_file> <data>
atomic_write() {
    local target="$1"
    local data="$2"

    [[ -z "$target" ]] && { error "atomic_write: target file not specified"; return 1; }

    local tmp
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1

    # Write to tmp file
    echo -n "$data" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Atomically move into place
    mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }

    return 0
}

# atomic_append: Append a line to a JSONL file atomically
# Usage: atomic_append <target_file> <json_line>
# Thread-safe via flock; validates line before appending
atomic_append() {
    local target="$1"
    local line="$2"

    [[ -z "$target" ]] && { error "atomic_append: target file not specified"; return 1; }
    [[ -z "$line" ]] && { error "atomic_append: line not specified"; return 1; }

    # Validate JSON line
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then
        error "atomic_append: invalid JSON: $line"
        return 1
    fi

    local tmp lock_file
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    lock_file="${target}.lock"

    (
        # Acquire exclusive lock with 5s timeout
        if ! flock -w 5 200 2>/dev/null; then
            error "atomic_append: failed to acquire lock on $target"
            return 1
        fi

        # Append to tmp file
        echo "$line" > "$tmp" || { rm -f "$tmp"; return 1; }

        # Append tmp to target (atomic cat)
        cat "$tmp" >> "$target" 2>/dev/null || { rm -f "$tmp"; return 1; }

        rm -f "$tmp"
        return 0
    ) 200>"$lock_file"
}

# ─── Tmpfile Tracking & Cleanup ──────────────────────────────────
# Registers a temp file for automatic cleanup on exit
# Usage: register_tmpfile <tmpfile_path>
# Set up trap handler: trap '_cleanup_tmpfiles' EXIT
_REGISTERED_TMPFILES=()

register_tmpfile() {
    local tmpfile="$1"
    [[ -z "$tmpfile" ]] && { error "register_tmpfile: path not specified"; return 1; }
    _REGISTERED_TMPFILES+=("$tmpfile")
}

# Cleanup all registered temp files
_cleanup_tmpfiles() {
    for f in "${_REGISTERED_TMPFILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
        [[ -d "$f" ]] && rm -rf "$f"
    done
}

# ─── Disk Space Check ───────────────────────────────────────────
# Validates minimum free disk space before critical writes
# Usage: check_disk_space <path> [min_mb]
check_disk_space() {
    local target_path="${1:-.}"
    local min_mb="${2:-100}"  # Default 100MB minimum

    # Get available space in KB
    local free_kb
    free_kb=$(df -k "$target_path" 2>/dev/null | tail -1 | awk '{print $4}')

    if [[ -z "$free_kb" ]] || [[ ! "$free_kb" =~ ^[0-9]+$ ]]; then
        warn "Could not determine free disk space — proceeding anyway"
        return 0
    fi

    local free_mb=$((free_kb / 1024))
    if [[ "$free_mb" -lt "$min_mb" ]]; then
        error "Insufficient disk space: ${free_mb}MB free, need ${min_mb}MB minimum"
        return 1
    fi

    return 0
}

# ─── GitHub API Retry Helper ────────────────────────────────────
# Retries gh CLI calls with exponential backoff on 403 (rate limit)
# Usage: gh_with_retry <max_attempts> gh issue view <args>
# Returns: command output on success, empty on failure
gh_with_retry() {
    local max_attempts="${1:-4}"
    shift
    local attempt=1
    local backoff_secs=30

    while [[ "$attempt" -le "$max_attempts" ]]; do
        # Execute gh command
        local output result
        output=$("$@" 2>&1)
        result=$?

        # Success
        if [[ "$result" -eq 0 ]]; then
            echo "$output"
            return 0
        fi

        # Check for rate limit (403) or API error
        if echo "$output" | grep -qE "HTTP 403|API rate limit|rate limited|You have exceeded"; then
            if [[ "$attempt" -lt "$max_attempts" ]]; then
                warn "GitHub API rate limit detected — backing off ${backoff_secs}s (attempt $attempt/$max_attempts)"
                emit_event "github.rate_limited" "attempt=$attempt" "backoff=$backoff_secs"
                sleep "$backoff_secs"
                backoff_secs=$((backoff_secs * 2))
                [[ "$backoff_secs" -gt 300 ]] && backoff_secs=300
            fi
        else
            # Non-rate-limit error — fail immediately
            return "$result"
        fi

        attempt=$((attempt + 1))
    done

    # Exhausted all retries
    error "GitHub API call failed after $max_attempts attempts: ${output##*$'\n'}"
    emit_event "github.api_failed" "attempts=$max_attempts"
    return 1
}

# ─── Project Identity ────────────────────────────────────────────
# Auto-detect GitHub owner/repo from git remote, with fallbacks
_sw_github_repo() {
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || echo "")"
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        echo "${SHIPWRIGHT_GITHUB_REPO:-sethdford/shipwright}"
    fi
}

# Like _sw_github_repo but returns non-zero when no GitHub remote is detected.
# Used by emit_event so the fallback to _sw_repo_hash is reachable.
_sw_detect_repo_slug() {
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || echo "")"
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

_sw_github_owner() {
    local repo
    repo="$(_sw_github_repo)"
    echo "${repo%%/*}"
}

_sw_docs_url() {
    local owner
    owner="$(_sw_github_owner)"
    echo "${SHIPWRIGHT_DOCS_URL:-https://${owner}.github.io/shipwright}"
}

_sw_github_url() {
    local repo
    repo="$(_sw_github_repo)"
    echo "https://github.com/${repo}"
}

# Compute 12-char repo hash from git remote origin URL (Bash 3.2-safe).
# Returns REPO_HASH env var value if already set (avoids redundant subprocesses).
_sw_repo_hash() {
    if [[ -n "${REPO_HASH:-}" ]]; then
        printf '%s' "$REPO_HASH"
        return
    fi
    local _origin
    _origin=$(git config --get remote.origin.url 2>/dev/null || echo "local-$(basename "$PWD")")
    local _hash=""
    if command -v shasum >/dev/null 2>&1; then
        _hash=$(printf '%s' "$_origin" | shasum -a 256 2>/dev/null | cut -c1-12) || true
    elif command -v sha256sum >/dev/null 2>&1; then
        _hash=$(printf '%s' "$_origin" | sha256sum 2>/dev/null | cut -c1-12) || true
    fi
    if [[ -n "$_hash" ]]; then
        printf '%s' "$_hash"
    else
        echo "unknown"
    fi
}

# ─── ANSI Escape Code Stripping ─────────────────────────────────────────
# Removes ANSI/CSI escape sequences from text (colors, cursor, formatting)
# Usage: clean=$(strip_ansi "$raw_text")  OR  echo "$raw" | strip_ansi
strip_ansi() {
    if [[ $# -gt 0 ]]; then
        printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
    else
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
    fi
}

# ─── Secret Sanitization ─────────────────────────────────────────────
# Redacts sensitive data from strings before logging
# Redacts: ANTHROPIC_API_KEY, GITHUB_TOKEN, sk-* patterns, Bearer tokens
sanitize_secrets() {
    local text="$1"
    # Redact ANTHROPIC_API_KEY=... (until whitespace or quote)
    text="$(echo "$text" | sed 's/ANTHROPIC_API_KEY=[^ "]*\|ANTHROPIC_API_KEY=[^ ]*/ANTHROPIC_API_KEY=***REDACTED***/g')"
    # Redact GITHUB_TOKEN=... (until whitespace or quote)
    text="$(echo "$text" | sed 's/GITHUB_TOKEN=[^ "]*\|GITHUB_TOKEN=[^ ]*/GITHUB_TOKEN=***REDACTED***/g')"
    # Redact sk-* patterns (Anthropic API key format)
    text="$(echo "$text" | sed 's/sk-[a-zA-Z0-9_-]*/sk-***REDACTED***/g')"
    # Redact Bearer tokens
    text="$(echo "$text" | sed 's/Bearer [a-zA-Z0-9_.-]*/Bearer ***REDACTED***/g')"
    # Redact GitHub OAuth tokens (ghp_, gho_, ghu_, ghs_, ghr_ — 5 known prefixes)
    # Length-bound: GitHub tokens are minimum 36 base62 chars [A-Za-z0-9], no underscores
    text="$(echo "$text" | sed -E 's/gh[pousr]_[A-Za-z0-9]{36,255}/gh_***REDACTED***/g')"
    # Redact GitHub fine-grained PATs (github_pat_ prefix, ≥60 base62+underscore chars)
    text="$(echo "$text" | sed -E 's/github_pat_[A-Za-z0-9_]{60,}/github_pat_***REDACTED***/g')"
    echo "$text"
}

# Portable SHA-1 hash of stdin — macOS (shasum) and Linux (sha1sum / openssl).
# Returns a 40-char hex digest, or a unique no-hasher sentinel to disable dedup.
# Usage: echo "data" | _compute_sha1
_compute_sha1() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 1 | awk '{print $1}'
    elif command -v sha1sum >/dev/null 2>&1; then
        sha1sum | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha1 -hex | awk '{print $NF}'
    else
        printf 'no-hasher-%s-%s' "$PPID" "$(date +%s 2>/dev/null || echo 0)"
    fi
}

# Validates a git ref/branch name against safe-ref rules.
# Usage: _validate_ref <ref> [label]
# Returns 0 for empty ref (unset is allowed; caller supplies default later).
# Returns 1 if the ref is unsafe so callers can: _validate_ref "$BASE_BRANCH" || BASE_BRANCH=main
# Rejects leading dashes (option-injection vector for git commands), `..` path
# traversal sequences, and anything else `git check-ref-format` flags. Falls back to
# a tight charset regex when git is unavailable in the environment.
_validate_ref() {
    local ref="${1:-}"
    local label="${2:-ref}"
    [[ -z "$ref" ]] && return 0
    # Hard reject: leading dash, embedded "..", whitespace, or git-ref reserved chars.
    case "$ref" in
        -*|*..*|*' '*|*$'\t'*|*$'\n'*|*'~'*|*'^'*|*':'*|*'?'*|*'*'*|*'['*|*'\\'*)
            error "_validate_ref: unsafe ${label} value '${ref}' (option/traversal/reserved char) — refusing"
            return 1
            ;;
    esac
    if command -v git >/dev/null 2>&1; then
        # Authoritative check: git's own ref-format validator (branch form).
        git check-ref-format --branch "$ref" >/dev/null 2>&1 && return 0
        error "_validate_ref: git check-ref-format rejected '${ref}' for ${label}"
        return 1
    fi
    # No git available — fall back to a conservative charset check.
    [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] && return 0
    error "_validate_ref: unsafe ${label} value '${ref}' — only [A-Za-z0-9._/-] allowed"
    return 1
}

# ─── Git Bookkeeping Exclusions ──────────────────────────────────
# Two categories of files excluded from loop progress/diff tracking:
#
# 1. Bookkeeping files: tracked in git, NOT gitignored. Must be excluded
#    from auto-commits (safe_git_stage) AND diff/progress checks.
# 2. Runtime files: already gitignored so they never get committed, but
#    excluded from diff checks as belt-and-suspenders safety.
#
# Add new files here — all consumers read these lists.

_GIT_BOOKKEEPING_FILES=(
    ".claude/pipeline-tasks.md"
    ".claude/tasks.md"
)

_GIT_RUNTIME_EXCLUDES=(
    ".claude/loop-state.md"
    ".claude/pipeline-state.md"
    "**/progress.md"
    "**/error-summary.json"
    ".shipwright/events-*.jsonl"
    ".claude/pipeline-artifacts/"
    ".claude/pipeline-status.json"
    ".ai-standards/generated/"
    ".github/copilot-instructions.md"
    "AGENTS.md"
)

# Git diff --stat excluding all bookkeeping and runtime files.
# Returns the summary line (e.g. "3 files changed, 10 insertions(+), 2 deletions(-)").
# Usage: _git_diff_stat_excluded [git-dir]
_git_diff_stat_excluded() {
    local _dir="${1:-${PROJECT_ROOT:-.}}"
    local _excl_args=()
    local _f
    for _f in "${_GIT_BOOKKEEPING_FILES[@]+"${_GIT_BOOKKEEPING_FILES[@]}"}"; do
        _excl_args+=(":!$_f")
    done
    for _f in "${_GIT_RUNTIME_EXCLUDES[@]+"${_GIT_RUNTIME_EXCLUDES[@]}"}"; do
        _excl_args+=(":!$_f")
    done
    git -C "$_dir" diff --stat HEAD~1 \
        -- . "${_excl_args[@]+"${_excl_args[@]}"}" \
        2>/dev/null | tail -1 || echo ""
}

# Print space-separated `:!path` pathspecs for all bookkeeping + runtime files.
# Usage: git diff --quiet -- $(_git_excluded_pathspecs)
# Word-splitting on the unquoted result is intentional; paths contain no spaces.
# Use for loop quality gates / dirty-tree checks where runtime files should not
# count as deliverable changes.
_git_excluded_pathspecs() {
    local _f
    for _f in "${_GIT_BOOKKEEPING_FILES[@]+"${_GIT_BOOKKEEPING_FILES[@]}"}"; do
        printf ':!%s ' "$_f"
    done
    for _f in "${_GIT_RUNTIME_EXCLUDES[@]+"${_GIT_RUNTIME_EXCLUDES[@]}"}"; do
        printf ':!%s ' "$_f"
    done
}

# Print space-separated `:!path` pathspecs for bookkeeping files only (NOT runtime).
# Usage: git diff --quiet -- $(_git_bookkeeping_pathspecs)
# Use for artifact-push commit guards where runtime files (pipeline-state.md,
# progress.md) are intentionally force-added and must trigger the commit.
_git_bookkeeping_pathspecs() {
    local _f
    for _f in "${_GIT_BOOKKEEPING_FILES[@]+"${_GIT_BOOKKEEPING_FILES[@]}"}"; do
        printf ':!%s ' "$_f"
    done
}

# ─── Scope-redaction helpers (PR-B invariant) ───────────────────────────────
#
# Invariant: no file path token in any agent prompt may name a file outside the
# design.md ```scope allow-list (except inside <out-of-scope-context> blocks).
# Codified at prompt-construction time — detective guards (safe_git_stage) remain
# as defense-in-depth but are not the primary enforcement mechanism.

# _file_in_scope — Test whether a single file path is permitted by the scope allowlist.
# Usage: _file_in_scope <file> <allowlist_newline_sep>
# Returns 0 (in-scope / allowed) or 1 (out-of-scope).
# When allowlist is empty, returns 0 (fail-open — warn-mode default).
# Handles: literals, directory prefixes (entry ends /), single-star globs, double-star globs.
# Do NOT reuse _compute_scope_violations — that is set-difference via comm and silently
# no-ops on dir/glob entries (different contract).
_file_in_scope() {
    local file="$1" allowlist="$2" entry _pfx _sdir _spat _fdir _fbase
    [ -z "$allowlist" ] && return 0
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        case "$entry" in
            \#*) continue ;;
            */)  case "$file" in "${entry}"*) return 0 ;; esac ;;
            *\*\**)
                # Double-star: recursive match with optional prefix and suffix
                # e.g. scripts/** → prefix="scripts/", suffix=""
                #      **/*.ts  → prefix="",           suffix="*.ts"
                _pfx="${entry%%\*\**}"
                _sfx="${entry##*\*\*}"
                case "$_sfx" in /*) _sfx="${_sfx#/}" ;; esac   # strip leading /
                local _pmatch=1 _smatch=1
                if [ -n "$_pfx" ]; then
                    case "$file" in "${_pfx}"*) ;; *) _pmatch=0 ;; esac
                fi
                if [ -n "$_sfx" ]; then
                    case "${file##*/}" in $_sfx) ;; *) _smatch=0 ;; esac
                fi
                [ "$_pmatch" -eq 1 ] && [ "$_smatch" -eq 1 ] && return 0
                ;;
            *\**)
                # Single-star: must NOT cross directory boundaries (star ≠ /)
                case "$entry" in
                    */*) _sdir="${entry%/*}"; _spat="${entry##*/}" ;;
                    *)   _sdir="";            _spat="$entry" ;;
                esac
                case "$file" in
                    */*) _fdir="${file%/*}"; _fbase="${file##*/}" ;;
                    *)   _fdir="";           _fbase="$file" ;;
                esac
                if [ "$_sdir" = "$_fdir" ]; then
                    case "$_fbase" in $_spat) return 0 ;; esac
                fi ;;
            *) [ "$file" = "$entry" ] && return 0 ;;
        esac
    done <<< "$allowlist"
    return 1
}

# _redact_paths_outside_scope — Replace out-of-scope file path tokens in text with
# redaction sentinels. Preserves code-fence blocks and <out-of-scope-context> blocks verbatim.
# Usage: result=$(_redact_paths_outside_scope "$text" "$allowlist" [seam] [cycle])
# When allowlist is empty, returns text unchanged (fail-open / warn-mode default —
# zero behaviour change for existing repos with no scope fence).
# Side effects per redaction:
#   - Appends a record to .claude/pipeline-artifacts/oos-redactions-cycle-N.json
#   - Emits pipeline.prompt_path_redacted via emit_event
_redact_paths_outside_scope() {
    local text="$1"
    local allowlist="$2"
    local seam="${3:-unknown}"
    local cycle="${4:-0}"

    # Pass-through when allowlist empty (warn mode — zero behaviour change for existing repos)
    if [ -z "$allowlist" ]; then
        printf '%s' "$text"
        return 0
    fi

    local token_counter=0
    local in_fence=0
    local in_oos_ctx=0
    local sidecar_dir="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
    local sidecar_file="${sidecar_dir}/oos-redactions-cycle-${cycle}.json"
    local allowlist_hash
    allowlist_hash=$(printf '%s' "$allowlist" | md5sum 2>/dev/null | cut -d' ' -f1 \
        || printf '%s' "$allowlist" | md5 2>/dev/null || echo "nohash")

    [ ! -d "$sidecar_dir" ] && mkdir -p "$sidecar_dir"
    [ ! -f "$sidecar_file" ] && printf '[]' > "$sidecar_file"

    local line processed candidates raw_token candidate suffix sentinel replacement _tmp

    while IFS= read -r line; do
        # Track <out-of-scope-context> escape markers
        case "$line" in
            *'<out-of-scope-context>'*)  in_oos_ctx=1 ;;
            *'</out-of-scope-context>'*) in_oos_ctx=0 ;;
        esac

        # Toggle code-fence state on ``` lines; emit verbatim and skip tokenizer
        case "$line" in
            '```'*)
                if [ "$in_fence" -eq 1 ]; then in_fence=0; else in_fence=1; fi
                printf '%s\n' "$line"
                continue ;;
        esac

        # Preserve lines verbatim inside fences and escape markers
        if [ "$in_fence" -eq 1 ] || [ "$in_oos_ctx" -eq 1 ]; then
            printf '%s\n' "$line"
            continue
        fi

        # Strip URLs before tokenizing so hostnames (example.com) aren't extracted as candidates.
        # Use -E for portable extended-regex (BSD sed and GNU sed both support -E).
        local _stripped_line
        _stripped_line=$(printf '%s' "$line" \
            | sed -E 's|https?://[^[:space:]]*||g; s|ftp://[^[:space:]]*||g; s|git@[^[:space:]]*||g' \
            2>/dev/null || printf '%s' "$line")

        # Extract file-path-shaped tokens.
        # Two shapes:
        #   1. Dotted extension:    foo/bar.sh:42   foo.ts
        #   2. Extensionless slash: scripts/sw      src/main (must contain / to avoid noise)
        # Combined via alternation; sort -u deduplicates overlapping matches.
        candidates=$(printf '%s' "$_stripped_line" \
            | grep -oE '([A-Za-z0-9_./-]+\.[A-Za-z0-9]+(:[0-9]+(-[0-9]+)?)?|[A-Za-z0-9_-]+(/[A-Za-z0-9_.@-]+)+)' \
            2>/dev/null | sort -u || true)

        processed="$line"
        while IFS= read -r raw_token; do
            [ -z "$raw_token" ] && continue

            # Strip line-number suffix before scope check
            candidate="${raw_token%%:*}"

            # Negative filters — skip URLs, absolute paths, lang-prefixed tokens, version strings
            case "$candidate" in
                http://*|https://*|ftp://*|git@*) continue ;;
                //*|/*) continue ;;    # absolute or double-slash (URL path fragment after stripping)
                Node:*|TypeScript:*|v[0-9]*) continue ;;
                [0-9]*) continue ;;
            esac

            # Idempotency: skip already-redacted sentinels so running twice is a no-op
            case "$raw_token" in
                '[redacted:out-of-scope:'*) continue ;;
            esac

            # Scope check — nothing to do when in-scope
            _file_in_scope "$candidate" "$allowlist" && continue

            # Out of scope: assign a stable sentinel for this token
            token_counter=$((token_counter + 1))
            sentinel="[redacted:out-of-scope:TOKEN-${token_counter}]"
            suffix="${raw_token#"$candidate"}"
            replacement="${sentinel}${suffix}"

            # Bash literal string substitution (// form; . and / are literal in bash globs)
            processed="${processed//"$raw_token"/"$replacement"}"

            # Append to sidecar manifest (requires jq; silently skips if absent)
            if command -v jq >/dev/null 2>&1; then
                _tmp="${sidecar_file}.tmp.$$"
                jq -c --arg cycle "$cycle" --arg seam "$seam" \
                    --arg tid "TOKEN-${token_counter}" \
                    --arg orig "$candidate" --arg hash "$allowlist_hash" \
                    '. + [{"cycle":($cycle|tonumber),"source_seam":$seam,"token_id":$tid,"original_path":$orig,"allowlist_snapshot_hash":$hash}]' \
                    "$sidecar_file" > "$_tmp" 2>/dev/null && mv "$_tmp" "$sidecar_file" \
                    || rm -f "$_tmp"
            fi

            # Emit telemetry event
            declare -f emit_event >/dev/null 2>&1 && \
                emit_event "pipeline.prompt_path_redacted" \
                    "stage=${seam}" "file=${candidate}" "token=TOKEN-${token_counter}" \
                    2>/dev/null || true

        done <<< "$candidates"

        printf '%s\n' "$processed"
    done <<< "$text"
}

# Load daemon-config.json, merging the auto-tuned sidecar (~/.shipwright/optimization/tuned-config.json)
# on top of the base config.  Sidecar carries auto-optimizer writes (intelligence flags, DORA
# autotune values) so they do not pollute committed daemon-config.json on feature branches.
# Usage: _load_daemon_config [base_config_path]
# Output: merged JSON to stdout; returns {} if base is absent; sidecar absence is not an error.
_load_daemon_config() {
    local base_config="${1:-${PROJECT_ROOT:-.}/.claude/daemon-config.json}"
    local sidecar="${HOME}/.shipwright/optimization/tuned-config.json"
    local _sc_lock="${HOME}/.shipwright/optimization/.tuned-config.lock"

    if [[ ! -f "$base_config" ]]; then
        printf '{}'
        return 0
    fi

    if [[ -f "$sidecar" ]]; then
        (
            command -v flock >/dev/null 2>&1 && flock -s -w 2 200 2>/dev/null || true
            jq -s '.[0] * .[1]' "$base_config" "$sidecar" 2>/dev/null || cat "$base_config"
        ) 200>>"$_sc_lock"
    else
        cat "$base_config"
    fi
}

# One-shot migration: if daemon-config.json has a committed last_optimization block
# (written by pre-T1.1 code), move it to the sidecar and strip it from the base file.
# Idempotent: no-op when key is absent. Called at daemon startup and persist_artifacts.
_migrate_last_optimization() {
    local _base="${PROJECT_ROOT:-.}/.claude/daemon-config.json"
    [[ -f "$_base" ]] || return 0
    local _has_lo
    _has_lo=$(jq -r 'has("last_optimization")' "$_base" 2>/dev/null || echo "false")
    [[ "$_has_lo" != "true" ]] && return 0

    local _sidecar_dir="${HOME}/.shipwright/optimization"
    local _sidecar="${_sidecar_dir}/tuned-config.json"
    mkdir -p "$_sidecar_dir" 2>/dev/null || true

    # Merge last_optimization into sidecar
    local _lo_block
    _lo_block=$(jq '{last_optimization: .last_optimization}' "$_base" 2>/dev/null || true)
    if [[ -n "$_lo_block" ]]; then
        local _sc_lock="${_sidecar_dir}/.tuned-config.lock"
        (
            if command -v flock >/dev/null 2>&1; then
                if ! flock -w 5 200; then
                    warn "sidecar lock contended; skipping migration write"
                    emit_event "sidecar.lock_contention" "site=migrate_last_optimization" 2>/dev/null || true
                    exit 1
                fi
            fi
            if [[ -f "$_sidecar" ]]; then
                _merged=$(jq -s '.[0] * .[1]' "$_sidecar" <(echo "$_lo_block") 2>/dev/null \
                    || cat "$_sidecar")
            else
                _merged="$_lo_block"
            fi
            printf '%s\n' "$_merged" > "${_sidecar}.tmp.$$" \
                && mv "${_sidecar}.tmp.$$" "$_sidecar" || true
        ) 200>"$_sc_lock"
    fi

    # Strip last_optimization from base and commit if inside a git repo
    local _stripped
    _stripped=$(jq 'del(.last_optimization)' "$_base" 2>/dev/null || true)
    if [[ -n "$_stripped" ]]; then
        printf '%s\n' "$_stripped" > "${_base}.tmp.$$" && mv "${_base}.tmp.$$" "$_base" || true
        if git -C "${PROJECT_ROOT:-.}" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "${PROJECT_ROOT:-.}" add ".claude/daemon-config.json" 2>/dev/null || true
            # --no-verify: infrastructure-automation commit consistent with other pipeline commits
            git -C "${PROJECT_ROOT:-.}" diff --cached --quiet 2>/dev/null || \
                git -C "${PROJECT_ROOT:-.}" commit \
                    -m "chore: migrate last_optimization to tuned-config sidecar" \
                    --no-verify 2>/dev/null || true
        fi
    fi
}

# Filter gitignored paths out of file-list output before it reaches agent prompts.
# Accepts name-status, name-only, and numstat formats from stdin; writes survivors to stdout.
# Any new prompt file-list should pipe through this helper.
# Usage: git diff --name-status base..HEAD | _filter_gitignored_paths
#        ( cd "$dir" && git diff --name-only | _filter_gitignored_paths )
_filter_gitignored_paths() {
    local _lines=() _paths=() _line _path _i _ignored_set
    # Read all input lines and extract the path column from each.
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _lines+=("$_line")
        # name-status (M\tpath) / numstat (adds\tdels\tpath) / rename (R100\told\tnew):
        # take the last tab-separated field. name-only: use the line as-is.
        if printf '%s' "$_line" | grep -q $'\t'; then
            _path="${_line##*$'\t'}"
        else
            _path="$_line"
        fi
        _paths+=("$_path")
    done

    [[ ${#_paths[@]} -eq 0 ]] && return 0

    # One subprocess for all paths. Newline-separated input avoids NUL-in-variable
    # limitations (bash variables cannot hold NUL bytes). --no-index is critical:
    # without it, tracked files are never reported as ignored even when they match
    # .gitignore — which is exactly the condition we're correcting.
    # Exit 0 = at least one path ignored (output = those paths, one per line).
    # Exit 1 = no paths ignored. Exit 128 = fatal error.
    # All non-zero cases yield empty _ignored_set → fail-open (all lines pass through).
    _ignored_set=$(printf '%s\n' "${_paths[@]+"${_paths[@]}"}" \
        | git check-ignore --stdin --no-index 2>/dev/null) || true

    for _i in "${!_lines[@]}"; do
        _path="${_paths[$_i]}"
        # Drop the line only when the path appears in the ignored set.
        if [[ -n "$_ignored_set" ]] && printf '%s\n' "$_ignored_set" | grep -qxF "$_path" 2>/dev/null; then
            continue
        fi
        printf '%s\n' "${_lines[$_i]}"
    done
}

# Resolve the merge-base between HEAD and the repo's default branch.
# Usage: _git_branch_merge_base [base_branch] [fallback_commit]
#   base_branch    — override default branch; auto-detected from origin/HEAD when omitted or empty
#   fallback_commit — returned when merge-base resolution fails (e.g. offline, no remote)
# Outputs the merge-base SHA (or fallback) on stdout.
_git_branch_merge_base() {
    local _base="${1:-}"
    local _fallback="${2:-}"
    local _root="${PROJECT_ROOT:-.}"
    if [[ -z "$_base" ]]; then
        _base="$(git -C "$_root" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||' || true)"
        [[ -z "$_base" || "$_base" == "HEAD" ]] && _base="main"
    fi
    git -C "$_root" merge-base "origin/${_base}" HEAD 2>/dev/null \
        || git -C "$_root" merge-base "${_base}" HEAD 2>/dev/null \
        || echo "${_fallback}"
}

# ─── Pipeline Tasks File Helper ──────────────────────────────────
# Extracts the issue number from the "- Issue:" header line of a
# pipeline-tasks.md file. Returns the normalized issue number (no #)
# on stdout. Accepts "- Issue:" or "Issue:" with any case.
# Exit codes: 0=success, 1=file missing/unreadable/no issue line.
# Usage: issue=$(extract_issue_from_tasks_file "$path") || ...
extract_issue_from_tasks_file() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    local issue
    issue=$(grep -m1 -i "^-\{0,1\} *Issue:" "$file" 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | tr -d '#' | xargs) || return 1
    [[ -n "$issue" && "$issue" =~ ^[0-9]+$ ]] && echo "$issue" || return 1
}

# ─── Git Staging Helper ───────────────────────────────────────────
# Stage all changes, then unstage any bookkeeping files listed in
# _GIT_BOOKKEEPING_FILES so they are not included in commits.
# When SCOPE_GUARD_ENABLED=true and a design.md scope block is present, also
# unstage out-of-scope files and emit a loop.scope_violation event for each.
# Usage: safe_git_stage [dir]   (dir defaults to current directory)
safe_git_stage() {
    local dir="${1:-.}"
    local toplevel
    toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || true
    git -C "$dir" add -A 2>/dev/null || true
    if [[ -n "$toplevel" ]]; then
        local _bf
        for _bf in "${_GIT_BOOKKEEPING_FILES[@]+"${_GIT_BOOKKEEPING_FILES[@]}"}"; do
            git -C "$dir" restore --staged "$toplevel/$_bf" 2>/dev/null || true
        done
    fi

    # Scope guard: when enabled, unstage files outside the declared design scope.
    # Requires _extract_scope_from_design and _compute_scope_violations (pipeline-stages.sh).
    # Operator override: set SCOPE_OVERRIDE=1 and create ~/.shipwright/scope-override.token.
    if [[ "${SCOPE_GUARD_ENABLED:-false}" == "true" ]] && \
       declare -f _extract_scope_from_design >/dev/null 2>&1 && \
       declare -f _compute_scope_violations >/dev/null 2>&1; then
        # Operator escape hatch: both env var AND token file required (agent cannot self-grant)
        if [[ "${SCOPE_OVERRIDE:-0}" == "1" && -f "${HOME}/.shipwright/scope-override.token" ]]; then
            warn "scope guard: SCOPE_OVERRIDE active — skipping scope check"
            return 0
        fi
        # Canonical path — matches classify_quality_findings reader and review-stage reader.
        # Clear unconditionally so a clean commit after a revert doesn't re-trigger scope route.
        local _viol_file="${ARTIFACTS_DIR:-${PROJECT_ROOT:-.}/.claude/pipeline-artifacts}/issue-${ISSUE_NUMBER:-0}/logs/scope-violations.txt"
        mkdir -p "$(dirname "$_viol_file")" 2>/dev/null || true
        rm -f "$_viol_file" 2>/dev/null || true
        local _scope_list
        _scope_list=$(_extract_scope_from_design 2>/dev/null)
        if [[ -n "$_scope_list" ]]; then
            local _staged_files
            _staged_files=$(git -C "$dir" diff --cached --name-only 2>/dev/null || true)
            if [[ -n "$_staged_files" ]]; then
                local _violations
                _violations=$(_compute_scope_violations "$_staged_files" "$_scope_list" 2>/dev/null)
                if [[ -n "$_violations" ]]; then
                    while IFS= read -r _vf; do
                        [[ -z "$_vf" ]] && continue
                        warn "scope guard: unstaging out-of-scope file: ${_vf}"
                        git -C "$dir" restore --staged "${toplevel:+$toplevel/}${_vf}" 2>/dev/null || true
                        declare -f emit_event >/dev/null 2>&1 && \
                            emit_event "loop.scope_violation" "file=${_vf}" "issue=${ISSUE_NUMBER:-0}" || true
                    done <<< "$_violations"
                    # Write violation summary for next iteration prompt injection
                    printf '%s\n' "$_violations" > "$_viol_file" 2>/dev/null || true
                fi
            fi
        fi
    fi
}

# ─── Model Resolution Helpers ────────────────────────────────────
# get_pipeline_model: for pre-loop sites (startup, dry-run, pipeline.started).
# Loop-state.md does not exist yet at these call sites.
# Priority: $MODEL (CLI flag) → pipeline config .defaults.model → "opus"
get_pipeline_model() {
    if [[ -n "${MODEL:-}" ]]; then echo "$MODEL"; return; fi
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
        local _m
        _m=$(jq -r '.defaults.model // ""' "$PIPELINE_CONFIG" 2>/dev/null || echo "")
        if [[ -n "$_m" && "$_m" != "null" ]]; then echo "$_m"; return; fi
    fi
    echo "opus"
}

# get_effective_model: for post-stage / telemetry sites.
# Reads loop-state.md when present so recorded model matches what actually ran.
# Priority: loop-state.md model: → $CLAUDE_MODEL → $MODEL → pipeline config → "opus"
get_effective_model() {
    local _loop_state="${STATE_DIR:-.claude}/loop-state.md"
    if [[ -f "$_loop_state" ]]; then
        local _m
        _m=$(grep -m1 '^model: ' "$_loop_state" 2>/dev/null | sed 's/^model: //' | tr -d '"')
        if [[ -n "$_m" && "$_m" != "null" ]]; then echo "$_m"; return; fi
    fi
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then echo "$CLAUDE_MODEL"; return; fi
    get_pipeline_model
}

