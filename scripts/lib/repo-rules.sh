#!/usr/bin/env bash
# scripts/lib/repo-rules.sh — the target repository's rules, given to every
# stage that declares it needs them (ADR-032 amendment).
#
# A stage declares `prompt.repo_rules: true` in its manifest. The router — the
# one funnel every model call passes through — then appends the target repo's
# `.zbuild/prompts/rules.md`, or zBuild's default rule set when the repo has
# none. No stage reads the file itself and none needs to know another exists.
#
# Why a declaration and not every stage: a rule set costs prompt budget, and a
# stage that only judges has no use for "how to write files here". The stages
# that WRITE into the repository need it most — #1845 run 36274909946's
# test-author wrote `grep … | grep -q` twice, and the repo's own SIGPIPE guard
# failed the suite on it.
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_REPO_RULES_LOADED:-}" ]] && return 0
_ZBUILD_REPO_RULES_LOADED=1

_RR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./prompt-overrides.sh
source "$_RR_DIR/prompt-overrides.sh"

# Opens the injected block; also the idempotence guard (the agentic loop
# redacts the same prompt file once per iteration).
_ZB_REPO_RULES_MARKER='## REPOSITORY RULES (engine-provided)'
_ZB_REPO_RULES_DEFAULT="$_RR_DIR/../../config/prompts/default-rules.md"

# repo_rules_declared <manifest> — rc 0 when the stage declares
# `prompt.repo_rules: true`. Its own two-line reader: the router must not
# depend on the registry's yaml_get being loaded in the calling shell.
repo_rules_declared() {
    local manifest="${1:-}"
    [[ -n "$manifest" && -f "$manifest" ]] || return 1
    awk '
        /^[^[:space:]#]/ { inblk = ($0 ~ /^prompt:[[:space:]]*(#.*)?$/); next }
        inblk && /^[[:space:]]+repo_rules:[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
        END { exit(found ? 0 : 1) }' "$manifest" 2>/dev/null
}

# _repo_rules_strip_comments — drop <!-- … --> maintainer notes (they cost
# prompt budget and are not rules) and leading blank lines.
_repo_rules_strip_comments() {
    awk '
        { line = $0 }
        incom { if (index(line, "-->")) { line = substr(line, index(line, "-->") + 3); incom = 0 } else next }
        { while (index(line, "<!--")) {
              pre = substr(line, 1, index(line, "<!--") - 1); rest = substr(line, index(line, "<!--") + 4)
              if (index(rest, "-->")) line = pre substr(rest, index(rest, "-->") + 3)
              else { line = pre; incom = 1; break } }
          if (!started && line ~ /^[[:space:]]*$/) next
          started = 1; print line }'
}

# _repo_rules_stage_writes <manifest> — rc 0 when the stage declares
# capabilities.writes_repository: true. Same rule as stage_declares_repo_writes
# (core/pipeline/input-resolve.sh) and _wb_declares_repo_writes
# (core/pipeline/write-boundary-repo.sh) — keep the three in step.
_repo_rules_stage_writes() {
    local manifest="${1:-}"
    [[ -n "$manifest" && -f "$manifest" ]] || return 1
    awk '
        /^[^[:space:]#]/ { inblk = ($0 ~ /^capabilities:[[:space:]]*(#.*)?$/); next }
        inblk && /^[[:space:]]+writes_repository:[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
        END { exit(found ? 0 : 1) }' "$manifest" 2>/dev/null
}

# repo_rules_prompt_block <manifest> <repo_root> — the block for a declaring
# stage; empty (and the prompt unchanged) for any other.
repo_rules_prompt_block() {
    local manifest="${1:-}" repo_root="${2:-}"
    repo_rules_declared "$manifest" || return 0

    local body="" source_line=""
    [[ -n "$repo_root" ]] && body="$(load_repo_rules "$repo_root" | _repo_rules_strip_comments)"
    if [[ -n "${body//[[:space:]]/}" ]]; then
        source_line="These are this repository's rules (.zbuild/prompts/rules.md)."
    else
        body="$(_repo_rules_strip_comments < "$_ZB_REPO_RULES_DEFAULT" 2>/dev/null || true)"
        [[ -n "${body//[[:space:]]/}" ]] || return 0
        source_line="This repository has no .zbuild/prompts/rules.md, so these are zBuild's default rules."
    fi

    printf '%s\n\n' "$_ZB_REPO_RULES_MARKER"
    printf '%s\n' "$source_line"
    if _repo_rules_stage_writes "$manifest"; then
        printf 'Every file you write must follow them, and must pass the repository'\''s\n'
        printf 'own lint and guard tests.\n\n'
    else
        # A stage that does not write the repository reviews against them.
        printf 'You do not write files; judge against them:\n'
        printf 'a change that breaks one is a finding.\n'
        printf 'Facts stated here are true of this repository — do not report them as risks.\n\n'
    fi
    printf '%s\n' "$body"
}
