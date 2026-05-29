#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild helpers — color output, atomic writes, JSON validation            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Phase 0 minimal primitives. Full safety chokepoints (validate_json hot-path
# wiring, check_disk_space on every artifact write, etc.) land as part of the
# core/ engine when individual keepers migrate from legacy/.

[[ -n "${_ZBUILD_HELPERS_LOADED:-}" ]] && return 0
_ZBUILD_HELPERS_LOADED=1

# Source compat first (Bash 5 check, platform detection)
_ZBUILD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./compat.sh
source "$_ZBUILD_SCRIPT_DIR/compat.sh"

# ─── Colors (NO_COLOR-aware) ─────────────────────────────────────────────────
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    CYAN=''; PURPLE=''; BLUE=''; GREEN=''; YELLOW=''; RED=''; DIM=''; BOLD=''; RESET=''
else
    CYAN='\033[38;2;0;212;255m'
    PURPLE='\033[38;2;124;58;237m'
    BLUE='\033[38;2;0;102;255m'
    GREEN='\033[38;2;74;222;128m'
    YELLOW='\033[38;2;250;204;21m'
    RED='\033[38;2;248;113;113m'
    DIM='\033[2m'
    BOLD='\033[1m'
    RESET='\033[0m'
fi
export CYAN PURPLE BLUE GREEN YELLOW RED DIM BOLD RESET

info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*" >&2; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

# ─── Atomic write (tmp + mv + .bak rotation) ────────────────────────────────
# Usage: atomic_write <target_path> < content_on_stdin
atomic_write() {
    local target="$1"
    local dir; dir="$(dirname "$target")"
    [[ -d "$dir" ]] || mkdir -p "$dir"

    # Disk-space precheck — refuse to write if < 50MB free
    local free_mb
    if [[ "$ZBUILD_PLATFORM" == "macos" ]]; then
        free_mb=$(df -m "$dir" | tail -1 | awk '{print $4}')
    else
        free_mb=$(df -m "$dir" | tail -1 | awk '{print $4}')
    fi
    if (( free_mb < 50 )); then
        error "atomic_write refusing: only ${free_mb}MB free at $dir (need >= 50MB)"
        return 1
    fi

    local tmp; tmp="$(mktemp "${target}.tmp.XXXXXX")"
    cat > "$tmp"
    # Rotate previous to .bak before replacing
    [[ -f "$target" ]] && cp "$target" "${target}.bak"
    mv "$tmp" "$target"
}

# ─── JSON validation with .bak recovery ─────────────────────────────────────
# Usage: validate_json <path> — returns 0 if valid; on corruption, tries .bak;
# returns 0 if .bak was restored, 2 if both corrupt.
validate_json() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    if jq empty "$path" >/dev/null 2>&1; then
        return 0
    fi
    warn "validate_json: $path is corrupt; attempting .bak recovery"
    if [[ -f "${path}.bak" ]] && jq empty "${path}.bak" >/dev/null 2>&1; then
        cp "${path}.bak" "$path"
        success "validate_json: recovered $path from .bak"
        return 0
    fi
    error "validate_json: both $path and ${path}.bak are corrupt"
    return 2
}

# ─── ANSI stripping ─────────────────────────────────────────────────────────
strip_ansi() {
    # Strip ANSI color/style codes from stdin
    sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g'
}

# ─── Emit event sentinel ─────────────────────────────────────────────────────
# Guards against calling emit_event before core/event-bus/event-bus.sh is
# sourced. When event-bus.sh is sourced after helpers.sh, its emit_event
# definition overwrites this sentinel.
# Returns 0 (not 1) so callers running under set -euo pipefail are not aborted
# by missing event-bus; the warning is sufficient for debugging.
emit_event() {
    if [[ -n "${ZBUILD_DEBUG:-}" ]]; then
        echo "[helpers] WARN: emit_event called before event-bus.sh was sourced" >&2
    fi
    return 0
}

# ─── run_captured_command — ADR-015 v2 command-kind capture wrapper (#439) ──
# Usage: run_captured_command <stage> <argv...>
#
# Wraps an external command, captures its merged stdout+stderr, exit code, and
# wall-clock duration, then forwards the record to capture_stage_io as a
# command-kind artifact. Stage MUST come first; argv must be non-empty. The
# wrapper is transparent: it preserves the caller's errexit state, returns the
# child's exit code, and flows captured output to its own stdout so it is a
# drop-in replacement for `$(cmd)` patterns.
#
# Bash 3.2-compatible. Sub-second commands record duration_ms=0 (SECONDS-based
# integer seconds × 1000 — no EPOCHREALTIME).
#
# Truncation: captured output is read back via `head -c $RUN_CAPTURED_CMD_MAX_BYTES`
# (default 1 MiB). When the on-disk size exceeds the cap, a "[truncated: ...]"
# marker is appended. Binary data is lossy — embedded NULs are stripped via
# `tr -d '\0'` before being passed to capture_stage_io.
: "${RUN_CAPTURED_CMD_MAX_BYTES:=1048576}"

run_captured_command() {
    if [[ $# -eq 0 ]]; then
        error "run_captured_command: usage: <stage> <argv...> (stage and argv required)"
        return 2
    fi
    local stage="$1"; shift
    if [[ -z "$stage" ]]; then
        error "run_captured_command: <stage> is required (non-empty)"
        return 2
    fi
    # Stage-name shape guard: stages are agent-internal identifiers from the
    # canonical list, not user-facing flags. Reject anything that could be a
    # misordered call where the caller forgot the stage arg and passed argv[0]
    # (e.g. `--check`, `gh`, `git`) as the stage.
    if [[ ! "$stage" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error "run_captured_command: stage '$stage' must match ^[a-z_][a-z0-9_-]*$ (likely a misordered call — pass <stage> before argv)"
        return 2
    fi
    if [[ $# -eq 0 ]]; then
        error "run_captured_command: argv is required (non-empty)"
        return 2
    fi
    # Defensive guard — caller must have sourced core/output/stage-io.sh first.
    if ! declare -f capture_stage_io >/dev/null 2>&1; then
        error "run_captured_command: capture_stage_io not loaded (source core/output/stage-io.sh first)"
        return 2
    fi

    # Save caller's errexit so we can run the wrapper body with `set +e`
    # without leaking the disable back to a `set -e` caller.
    local _had_errexit=0
    [[ $- == *e* ]] && _had_errexit=1
    set +e

    # Encode argv via printf %q (trim trailing space).
    local argv_str
    argv_str="$(printf '%q ' "$@")"
    argv_str="${argv_str% }"

    # Capture into a temp file (merged streams).
    # Use explicit template form (router precedent — `mktemp -t` resolution
    # varies across BSD/GNU; this idiom matches `core/router/route.sh`).
    local capfile
    capfile="$(mktemp "${TMPDIR:-/tmp}/zbuild-capcmd.XXXXXX")"
    local _start=$SECONDS
    "$@" >"$capfile" 2>&1
    local rc=$?
    local _dur_ms=$(( (SECONDS - _start) * 1000 ))

    # Determine on-disk size; read back up to the cap; append truncation marker
    # if the on-disk size exceeds the cap.
    local _max="${RUN_CAPTURED_CMD_MAX_BYTES:-1048576}"
    local _actual
    _actual="$(wc -c <"$capfile" | tr -d ' ')"
    local out
    # Strip NULs before passing to capture (binary lossy but documented).
    out="$(head -c "$_max" "$capfile" | tr -d '\0')"
    if [[ "$_actual" -gt "$_max" ]]; then
        out="${out}"$'\n'"[truncated: ${_actual} bytes total, captured ${_max}]"
    fi

    # Forward to chokepoint. Failure to capture is logged but does not change
    # the wrapped command's return code (caller cares about the wrapped rc).
    capture_stage_io \
        --stage "$stage" \
        --kind command \
        --input "$argv_str" \
        --output "$out" \
        --exit-code "$rc" \
        --duration-ms "$_dur_ms" \
        --metadata "pwd=$PWD" \
        || warn "run_captured_command: capture failed for stage=$stage; wrapped rc=$rc preserved"

    # Drop-in $(...) compatibility — flow captured output to wrapper stdout.
    printf '%s' "$out"

    rm -f "$capfile"

    # Restore errexit if caller had it on.
    [[ $_had_errexit -eq 1 ]] && set -e
    return $rc
}

# ─── Project root resolution ────────────────────────────────────────────────
# Returns zBuild repo root via git rev-parse; falls back to env var; error if neither.
zbuild_project_root() {
    if [[ -n "${ZBUILD_PROJECT_ROOT:-}" ]]; then
        echo "$ZBUILD_PROJECT_ROOT"
        return 0
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$root" ]]; then
        error "zbuild_project_root: not in a git repo and ZBUILD_PROJECT_ROOT unset"
        return 1
    fi
    echo "$root"
}
