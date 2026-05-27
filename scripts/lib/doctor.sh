#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild doctor — environment and configuration health checks              ║
# ║  issues #58, #90                                                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_ZBUILD_DOCTOR_LOADED:-}" ]] && return 0
_ZBUILD_DOCTOR_LOADED=1

_ZBUILD_DOCTOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
source "$_ZBUILD_DOCTOR_SCRIPT_DIR/helpers.sh"

DOCTOR_PASS=0
DOCTOR_WARN=0
DOCTOR_FAIL=0

_doc_pass() { info "  [PASS] $*"; DOCTOR_PASS=$((DOCTOR_PASS + 1)); }
_doc_warn() { warn "  [WARN] $*"; DOCTOR_WARN=$((DOCTOR_WARN + 1)); }
_doc_fail() { error "  [FAIL] $*"; DOCTOR_FAIL=$((DOCTOR_FAIL + 1)); }

# ─── Prerequisites ───────────────────────────────────────────────────────────

_check_bash_version() {
    # Note: helpers.sh (sourced above) hard-fails on Bash <5, so the bash 3/4
    # branches below can only execute when this function is invoked from a
    # Bash 5+ shell that is checking the *system default* bash version.
    # In practice major will always be ≥5 when reached via normal sourcing.
    local major="${BASH_VERSINFO[0]}"
    if (( major >= 5 )); then
        _doc_pass "bash ${BASH_VERSION}"
    elif (( major == 4 )); then
        _doc_warn "bash 4 functional but 5 recommended; Fix: brew install bash"
    else
        _doc_fail "bash 3 not supported; Fix: brew install bash"
    fi
}

_check_jq() {
    if command -v jq >/dev/null 2>&1; then
        _doc_pass "jq $(jq --version 2>/dev/null || echo 'found')"
    else
        _doc_fail "jq not found; Fix: brew install jq  /  apt install jq"
    fi
}

_check_git() {
    if command -v git >/dev/null 2>&1; then
        _doc_pass "git $(git --version 2>/dev/null | head -1 || echo 'found')"
    else
        _doc_fail "git not found; Fix: brew install git  /  apt install git"
    fi
}

_check_claude() {
    if command -v claude >/dev/null 2>&1; then
        _doc_pass "claude CLI found"
    else
        _doc_fail "claude CLI not found; Fix: npm install -g @anthropic-ai/claude-code"
    fi
}

_check_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        _doc_warn "gh CLI not found (optional); Fix: install gh CLI — https://cli.github.com/"
        return
    fi
    if gh auth status >/dev/null 2>&1; then
        _doc_pass "gh CLI found and authenticated"
    else
        _doc_warn "gh CLI found but not authenticated; Fix: gh auth login"
    fi
}

_check_sqlite3() {
    if command -v sqlite3 >/dev/null 2>&1; then
        _doc_pass "sqlite3 found"
    else
        _doc_warn "sqlite3 not found (optional); Fix: brew install sqlite3  /  apt install sqlite3"
    fi
}

# ─── PATH & CLI ──────────────────────────────────────────────────────────────

_check_zbuild_path() {
    if command -v zbuild >/dev/null 2>&1; then
        _doc_pass "zbuild found at $(command -v zbuild)"
    else
        _doc_fail "zbuild not in PATH; Fix: export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

# ─── State ───────────────────────────────────────────────────────────────────

_check_state_dir() {
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    mkdir -p "$state_dir" 2>/dev/null || true
    if [[ -d "$state_dir" && -w "$state_dir" ]]; then
        _doc_pass "state dir: $state_dir"
    else
        _doc_fail "state dir missing or not writable: $state_dir; Fix: mkdir -p ~/.zbuild/state"
    fi
}

_check_state_health() {
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    local in_progress=0
    local f
    if ! command -v jq >/dev/null 2>&1; then
        _doc_warn "state health check skipped: jq not available"
        return
    fi
    # Scan for corrupt JSON and count in_progress runs
    for f in "$state_dir"/pipeline-state*.json; do
        [[ -f "$f" ]] || continue
        if ! jq empty "$f" >/dev/null 2>&1; then
            _doc_fail "corrupt state file: $f"
        else
            local status
            status="$(jq -r '.status // empty' "$f" 2>/dev/null || true)"
            if [[ "$status" == "in_progress" ]]; then
                in_progress=$((in_progress + 1))
            fi
        fi
    done
    if (( in_progress > 1 )); then
        _doc_warn "$in_progress in_progress pipelines found (expected ≤1); stale state may exist"
    else
        _doc_pass "state dir: $state_dir"
    fi
}

# ─── Plugin Registry ─────────────────────────────────────────────────────────

_check_plugin_registry() {
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-}"
    if [[ -z "$plugins_root" ]]; then
        # Derive from doctor script location: scripts/lib/doctor.sh → repo root
        local repo_root
        repo_root="$(cd "$_ZBUILD_DOCTOR_SCRIPT_DIR/../.." && pwd)"
        plugins_root="$repo_root/plugins"
    fi
    local count
    count="$(find "$plugins_root" -name "manifest.yaml" 2>/dev/null | wc -l | tr -d ' ')"
    if (( count == 0 )); then
        _doc_warn "no plugin manifests found under $plugins_root"
    else
        _doc_pass "$count plugin manifest(s) found"
    fi
}

# ─── Configuration ───────────────────────────────────────────────────────────

_check_config_files() {
    # Use _ZBUILD_ROOT if already set (e.g. sourced via route.sh), else compute.
    local repo_root="${_ZBUILD_ROOT:-$(cd "$_ZBUILD_DOCTOR_SCRIPT_DIR/../.." && pwd)}"
    local models_json="$repo_root/config/models.json"
    local event_schema="$repo_root/config/event-schema.json"

    if [[ ! -f "$models_json" ]]; then
        _doc_fail "config/models.json missing (expected at $models_json)"
    elif ! command -v jq >/dev/null 2>&1; then
        _doc_warn "config/models.json found but JSON validation skipped: jq not available"
    elif ! jq empty "$models_json" >/dev/null 2>&1; then
        _doc_fail "config/models.json is not valid JSON"
    else
        _doc_pass "config/models.json valid"
    fi

    if [[ ! -f "$event_schema" ]]; then
        _doc_fail "config/event-schema.json missing (expected at $event_schema)"
    elif ! command -v jq >/dev/null 2>&1; then
        _doc_warn "config/event-schema.json found but JSON validation skipped: jq not available"
    elif ! jq empty "$event_schema" >/dev/null 2>&1; then
        _doc_fail "config/event-schema.json is not valid JSON"
    else
        _doc_pass "config/event-schema.json valid"
    fi
}

# ─── Main entry point ────────────────────────────────────────────────────────

run_doctor() {
    local version="${1:-}"
    DOCTOR_PASS=0
    DOCTOR_WARN=0
    DOCTOR_FAIL=0
    echo ""
    info "zbuild doctor${version:+ v$version}"
    echo ""
    info "PREREQUISITES"
    _check_bash_version
    _check_jq
    _check_git
    _check_claude
    _check_gh
    _check_sqlite3
    echo ""
    info "PATH & CLI"
    _check_zbuild_path
    echo ""
    info "STATE"
    _check_state_dir
    _check_state_health
    echo ""
    info "PLUGIN REGISTRY"
    _check_plugin_registry
    echo ""
    info "CONFIGURATION"
    _check_config_files
    echo ""
    echo "  $DOCTOR_PASS passed  $DOCTOR_WARN warnings  $DOCTOR_FAIL failed  ($((DOCTOR_PASS + DOCTOR_WARN + DOCTOR_FAIL)) checks)"
    echo ""
    if [[ $DOCTOR_FAIL -gt 0 ]]; then
        error "Some checks failed. Fix the issues above and re-run zbuild doctor."
        return 1
    elif [[ $DOCTOR_WARN -gt 0 ]]; then
        warn "Setup mostly OK, but there are warnings above."
        return 0
    else
        success "Everything looks good!"
        return 0
    fi
}
