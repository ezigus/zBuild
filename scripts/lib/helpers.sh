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

# ─── Colors (NO_COLOR-aware, FORCE_COLOR override) ───────────────────────────
# FORCE_COLOR=1 wins over the tty check so tests/CI can pin colored output
# without a real terminal. NO_COLOR still wins over FORCE_COLOR (POSIX-ish
# convention: explicit opt-out beats explicit opt-in).
if [[ -n "${NO_COLOR:-}" || ( "${FORCE_COLOR:-0}" != "1" && ! -t 1 ) ]]; then
    CYAN=''; PURPLE=''; BLUE=''; LIGHT_BLUE=''; GREEN=''; YELLOW=''; RED=''; DIM=''; BOLD=''; RESET=''
else
    CYAN='\033[38;2;0;212;255m'
    PURPLE='\033[38;2;124;58;237m'
    BLUE='\033[38;2;0;102;255m'
    LIGHT_BLUE='\033[38;2;100;200;255m'
    GREEN='\033[38;2;74;222;128m'
    YELLOW='\033[38;2;250;204;21m'
    RED='\033[38;2;248;113;113m'
    DIM='\033[2m'
    BOLD='\033[1m'
    RESET='\033[0m'
fi
export CYAN PURPLE BLUE LIGHT_BLUE GREEN YELLOW RED DIM BOLD RESET

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

# ─── Terminal width helper (#492) ────────────────────────────────────────────
# Returns the terminal column count; memoized per-process so repeated calls
# don't shell out to `tput cols`. Tests inject ZBUILD_TERM_WIDTH_OVERRIDE to
# pin layout; they MUST `unset _ZBUILD_TERM_WIDTH` between cases so the
# memoization doesn't fossilize a previous test's value.
#
# Resolution order:
#   1. ZBUILD_TERM_WIDTH_OVERRIDE (test pin)
#   2. Memoized _ZBUILD_TERM_WIDTH (set on first uncached call)
#   3. NO_COLOR or non-tty → 80 (stable layout for goldens / CI logs)
#   4. tput cols  →  COLUMNS  →  80 (final fallback)
_term_width() {
    if [[ -n "${ZBUILD_TERM_WIDTH_OVERRIDE:-}" ]]; then
        printf '%s' "$ZBUILD_TERM_WIDTH_OVERRIDE"
        return 0
    fi
    if [[ -n "${_ZBUILD_TERM_WIDTH:-}" ]]; then
        printf '%s' "$_ZBUILD_TERM_WIDTH"
        return 0
    fi
    local w=""
    if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
        w=80
    else
        w="$(tput cols 2>/dev/null || true)"
        [[ -z "$w" || ! "$w" =~ ^[0-9]+$ ]] && w="${COLUMNS:-80}"
        [[ ! "$w" =~ ^[0-9]+$ ]] && w=80
    fi
    _ZBUILD_TERM_WIDTH="$w"
    printf '%s' "$_ZBUILD_TERM_WIDTH"
}

# ─── ANSI stripping ─────────────────────────────────────────────────────────
# Unused as of 2026-06-12; if revived, add LC_ALL=C prefix per #830 to avoid
# BSD sed "RE error: illegal byte sequence" on non-UTF-8 input. See
# scripts/lib/test-output-sanitize.sh + core/output/stage-io.sh for the
# pattern.
strip_ansi() {
    # Strip ANSI color/style codes from stdin
    LC_ALL=C sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g'
}

# ─── extract_first_json_object (#478) ───────────────────────────────────────
# Durable safety net for ADR-018 Pattern 1: the JSON envelope (#476) separates
# reasoning *turns* from the final turn, but the model can still emit prose
# inside the final assistant message before/after its JSON. Slice the LAST
# top-level balanced JSON object out of stdin.
#
# "LAST wins" — despite the name "first" (kept for the #478 issue thread), the
# algorithm returns the LAST balanced top-level object. Models typically emit
# reasoning/examples first and the real answer last (e.g. "Here's an example
# {a:1}. Real plan: {...}"). The caller's strict schema check (jq -e) provides
# the layered defense for cases where the LAST object is itself inline noise.
#
# Markdown ```json … ``` fence stripping is folded into a pre-pass so callers
# can drop their ad-hoc sed pipelines.
#
# Contract: stdin -> stdout, rc=0 always. No JSON validation here; if no
# balanced object is found the input passes through verbatim so the caller's
# downstream diagnostics (e.g. #476 reason=schema_violation /
# empty_result_envelope) still see the prose and can classify it correctly.
extract_first_json_object() {
    awk '
        BEGIN { buf = "" }
        { buf = buf $0 "\n" }
        END {
            # Strip a UTF-8 BOM and surrounding markdown json fences if present
            # (pre-pass; idempotent — no-op if no fence).
            sub(/^\xef\xbb\xbf/, "", buf)
            sub(/^[[:space:]]*```json[[:space:]]*\n?/, "", buf)
            sub(/^[[:space:]]*```[[:space:]]*\n?/, "", buf)
            sub(/\n?[[:space:]]*```[[:space:]]*$/, "", buf)

            n = length(buf)
            depth = 0       # brace nesting depth
            arr_depth = 0   # bracket nesting depth (object-only contract:
                            # skip `{` while inside `[...]`)
            in_string = 0
            escape = 0
            start = -1
            last_start = -1
            last_end = -1
            for (i = 1; i <= n; i++) {
                c = substr(buf, i, 1)
                if (escape) { escape = 0; continue }
                if (in_string) {
                    if (c == "\\") { escape = 1; continue }
                    if (c == "\"") { in_string = 0 }
                    continue
                }
                if (c == "\"") { in_string = 1; continue }
                if (c == "[") {
                    if (depth == 0) { arr_depth++ }
                    continue
                }
                if (c == "]") {
                    if (depth == 0 && arr_depth > 0) { arr_depth-- }
                    continue
                }
                if (c == "{") {
                    if (depth == 0 && arr_depth > 0) { continue }
                    if (depth == 0) { start = i }
                    depth++
                    continue
                }
                if (c == "}") {
                    if (depth > 0) {
                        depth--
                        if (depth == 0 && start > 0) {
                            last_start = start
                            last_end = i
                            start = -1
                        }
                    }
                }
            }
            if (last_start > 0 && last_end >= last_start) {
                printf "%s", substr(buf, last_start, last_end - last_start + 1)
            } else {
                # Passthrough: restore the original (sans fence pre-pass) so
                # #476 diagnostics see the prose verbatim. Strip the trailing
                # newline we appended while accumulating.
                sub(/\n$/, "", buf)
                printf "%s", buf
            }
        }
    '
}

# ─── extract_json_and_surrounding_prose (#510) ──────────────────────────────
# Sibling of extract_first_json_object that ALSO returns the surrounding prose
# so renderers can present both the structured artifact AND any free-text
# commentary the model emitted in the same assistant turn (envelope mode
# separates turns but not in-turn prose).
#
# Mirrors the LAST-balanced-object algorithm of extract_first_json_object so
# both helpers agree on which slice is "the" JSON. extract_first_json_object
# itself is unchanged for parser back-compat (e.g. plan plugin schema check).
#
# Output contract: stdout, two lines, prefixed with sentinels so the slices can
# carry embedded newlines without colliding with the field separator. rc=0
# always (no-match → empty slices).
#
#   __PROSE__
#   <prose bytes — pre-object concat post-object, single blank line between
#                  when both non-empty; markdown ```json fences stripped BEFORE
#                  slicing so fenced JSON does not pollute prose>
#   __JSON__
#   <json bytes — empty if no balanced object found>
#
# Consumers parse via awk on the sentinels (see render_plan_md).
extract_json_and_surrounding_prose() {
    awk '
        BEGIN { buf = "" }
        { buf = buf $0 "\n" }
        END {
            # Pre-pass identical to extract_first_json_object so slicing math
            # operates on the same buffer the LAST-wins parser saw.
            sub(/^\xef\xbb\xbf/, "", buf)
            sub(/^[[:space:]]*```json[[:space:]]*\n?/, "", buf)
            sub(/^[[:space:]]*```[[:space:]]*\n?/, "", buf)
            sub(/\n?[[:space:]]*```[[:space:]]*$/, "", buf)
            # Strip the trailing newline we appended while accumulating so
            # prose slices do not carry phantom blank lines.
            sub(/\n$/, "", buf)

            n = length(buf)
            depth = 0
            arr_depth = 0
            in_string = 0
            escape = 0
            start = -1
            last_start = -1
            last_end = -1
            for (i = 1; i <= n; i++) {
                c = substr(buf, i, 1)
                if (escape) { escape = 0; continue }
                if (in_string) {
                    if (c == "\\") { escape = 1; continue }
                    if (c == "\"") { in_string = 0 }
                    continue
                }
                if (c == "\"") { in_string = 1; continue }
                if (c == "[") {
                    if (depth == 0) { arr_depth++ }
                    continue
                }
                if (c == "]") {
                    if (depth == 0 && arr_depth > 0) { arr_depth-- }
                    continue
                }
                if (c == "{") {
                    if (depth == 0 && arr_depth > 0) { continue }
                    if (depth == 0) { start = i }
                    depth++
                    continue
                }
                if (c == "}") {
                    if (depth > 0) {
                        depth--
                        if (depth == 0 && start > 0) {
                            last_start = start
                            last_end = i
                            start = -1
                        }
                    }
                }
            }

            prose = ""
            json = ""
            if (last_start > 0 && last_end >= last_start) {
                json = substr(buf, last_start, last_end - last_start + 1)
                pre  = (last_start > 1) ? substr(buf, 1, last_start - 1) : ""
                post = (last_end < n)   ? substr(buf, last_end + 1)       : ""
                # Trim surrounding whitespace on each prose slice so a typical
                # "Here is the plan.\n\n{...}\n\nLet me know..." input does
                # not yield empty-looking-but-whitespace prose blocks.
                sub(/^[[:space:]]+/, "", pre);  sub(/[[:space:]]+$/, "", pre)
                sub(/^[[:space:]]+/, "", post); sub(/[[:space:]]+$/, "", post)
                if (pre != "" && post != "") {
                    prose = pre "\n\n" post
                } else if (pre != "") {
                    prose = pre
                } else if (post != "") {
                    prose = post
                }
            } else {
                # No balanced JSON object found: the entire buffer is prose.
                # Strip surrounding whitespace for the same reason as above.
                prose = buf
                sub(/^[[:space:]]+/, "", prose); sub(/[[:space:]]+$/, "", prose)
            }

            printf "__PROSE__\n"
            printf "%s", prose
            printf "\n__JSON__\n"
            printf "%s", json
        }
    '
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
# Duration is measured via $EPOCHREALTIME (Bash 5+; zBuild requires it per
# scripts/lib/compat.sh) for true millisecond resolution.
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
    # EPOCHREALTIME is a Bash 5+ builtin: "<sec>.<usec>". Strip the dot
    # to convert to an all-microsecond integer for arithmetic.
    local _t0_us="${EPOCHREALTIME/./}"
    "$@" >"$capfile" 2>&1
    local rc=$?
    local _t1_us="${EPOCHREALTIME/./}"
    # Guard against leading-zero octal interpretation in arithmetic context.
    local _dur_ms=$(( (10#${_t1_us} - 10#${_t0_us}) / 1000 ))
    (( _dur_ms < 0 )) && _dur_ms=0

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

# ─── branch_numstat — compact "files=N add=A del=D" diff summary (#567) ─────
# Fail-OPEN helper for the test_assessment LLM input. Returns a single line on
# stdout describing the current branch's diff against a base ref. NEVER aborts
# the caller (rc=0 always) — this is LLM signal, not a safety gate.
#
# Output shapes:
#   files=<N> add=<A> del=<B>     when a base ref resolves
#   unknown                       when no usable ref or no git repo
#
# Base-ref fallback chain: origin/main → main → master → HEAD~50..HEAD →
#   HEAD~1..HEAD → unknown. Binary files in numstat appear as "-\t-\tpath";
# we treat their adds/dels as 0 when summing.
branch_numstat() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'unknown\n'
        return 0
    fi

    local base="" range="" cand
    for cand in "origin/main" "main" "master"; do
        if git rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
            base="$(git merge-base "$cand" HEAD 2>/dev/null || true)"
            if [[ -n "$base" ]]; then
                range="${base}..HEAD"
                break
            fi
        fi
    done

    if [[ -z "$range" ]]; then
        # HEAD~50 ancestor probe (skip if shallow / fewer commits than 50).
        if git rev-parse --verify --quiet "HEAD~50" >/dev/null 2>&1; then
            range="HEAD~50..HEAD"
        elif git rev-parse --verify --quiet "HEAD~1" >/dev/null 2>&1; then
            range="HEAD~1..HEAD"
        fi
    fi

    if [[ -z "$range" ]]; then
        printf 'unknown\n'
        return 0
    fi

    local raw
    raw="$(git diff --numstat "$range" 2>/dev/null || true)"
    if [[ -z "$raw" ]]; then
        printf 'files=0 add=0 del=0\n'
        return 0
    fi

    local files=0 add=0 del=0
    local adds dels path a_n d_n
    while IFS=$'\t' read -r adds dels path; do
        [[ -z "$path" ]] && continue
        files=$((files + 1))
        a_n=0; d_n=0
        [[ "$adds" =~ ^[0-9]+$ ]] && a_n="$adds"
        [[ "$dels" =~ ^[0-9]+$ ]] && d_n="$dels"
        add=$((add + a_n))
        del=$((del + d_n))
    done <<< "$raw"
    printf 'files=%d add=%d del=%d\n' "$files" "$add" "$del"
    return 0
}
