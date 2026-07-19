#!/usr/bin/env bash
# scripts/lib/vision-init.sh — vision document authoring helpers (ADR-049 Phase 1.1).
#
# Source-only library (guard-loaded, no side-effects on source).
# Public API:
#   vision_init_blank <out_path>                   — write a minimal conforming skeleton
#   vision_init_draft <repo_root> <out_path>       — auto-draft via LLM from repo context
#   vision_condense   <in_path>  <out_path>        — condense an existing doc to ≤300 words
#
# vision_init_blank is usable without the pipeline stack (no LLM calls).
# vision_init_draft and vision_condense lazily source the router stack on first call.

[[ -n "${_VISION_INIT_LOADED:-}" ]] && return 0
_VISION_INIT_LOADED=1

# shellcheck source=vision.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vision.sh"

# ─── vision_init_blank <out_path> ────────────────────────────────────────────
# Writes a bare conforming skeleton with conventional headings and
# placeholder body text that keeps body word count under 300.
vision_init_blank() {
    local out_path="${1:-}"
    if [[ -z "$out_path" ]]; then
        printf 'vision_init_blank: out_path required\n' >&2
        return 1
    fi
    mkdir -p "$(dirname "$out_path")"
    cat > "$out_path" <<'EOF'
## Intent

Describe the primary purpose and goal of this project here.

## Principles

- Replace this with the core values that guide every decision in this project.
- Add one principle per bullet — keep each statement short and concrete.
EOF
}

# ─── _vision_ensure_router ───────────────────────────────────────────────────
# Lazy-source the router and its dependencies. Called only by draft/condense
# so that vision_init_blank works in test environments without the full stack.
_vision_ensure_router() {
    local _lib_root
    _lib_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _repo_root
    _repo_root="$(cd "$_lib_root/../.." && pwd)"

    if ! declare -F route_to_model >/dev/null 2>&1; then
        source "$_repo_root/core/event-bus/event-bus.sh"
        source "$_repo_root/core/config/config.sh"
        zbuild_config_init
        source "$_repo_root/core/router/route.sh"
        if declare -F apply_scope_redaction >/dev/null 2>&1; then
            : # already loaded
        else
            source "$_repo_root/core/redaction/redaction.sh" 2>/dev/null || true
        fi
    fi
}

# ─── vision_init_draft <repo_root> <out_path> ────────────────────────────────
# Inspects <repo_root> for README, language markers, and ADR docs, then calls
# route_to_model T2 to produce a conforming vision draft. Writes to <out_path>.
vision_init_draft() {
    local repo_root="${1:-}" out_path="${2:-}"
    if [[ -z "$repo_root" || -z "$out_path" ]]; then
        printf 'vision_init_draft: repo_root and out_path required\n' >&2
        return 1
    fi

    _vision_ensure_router

    # Gather repo context signals
    local readme_excerpt="" lang_markers="" adr_titles=""
    local readme_file=""
    for _rf in "$repo_root/README.md" "$repo_root/README.rst" "$repo_root/README"; do
        if [[ -f "$_rf" ]]; then
            readme_file="$_rf"
            break
        fi
    done
    if [[ -n "$readme_file" ]]; then
        # First 60 lines of the README for context (avoid extremely long prompts)
        readme_excerpt="$(head -60 "$readme_file" 2>/dev/null || true)"
    fi

    # Language markers
    local _lang_files=()
    [[ -f "$repo_root/package.json" ]] && _lang_files+=("package.json (Node.js/JavaScript)")
    [[ -f "$repo_root/go.mod" ]]       && _lang_files+=("go.mod (Go)")
    [[ -f "$repo_root/setup.py" ]]     && _lang_files+=("setup.py (Python)")
    [[ -f "$repo_root/Cargo.toml" ]]   && _lang_files+=("Cargo.toml (Rust)")
    [[ -f "$repo_root/pom.xml" ]]      && _lang_files+=("pom.xml (Java/Maven)")
    if [[ ${#_lang_files[@]} -gt 0 ]]; then
        lang_markers="${_lang_files[*]}"
    fi

    # ADR titles (first line of each ADR file)
    if [[ -d "$repo_root/docs/adr" ]]; then
        while IFS= read -r _adr_file; do
            local _first_line
            _first_line="$(head -1 "$_adr_file" 2>/dev/null || true)"
            [[ -n "$_first_line" ]] && adr_titles+="$_first_line"$'\n'
        done < <(find "$repo_root/docs/adr" -maxdepth 1 -name "*.md" | sort | head -10)
    fi

    local prompt
    prompt="$(cat <<PROMPT
Write a concise vision document for this software project. The document MUST:
1. Start with a "## Intent" section describing what the project does and why it exists.
2. Include a "## Principles" section with 3-5 bulleted core principles.
3. Keep the total body word count (non-heading lines) to 250 words or fewer.
4. Use clear, direct language — no marketing language.

Project signals:
$([ -n "$readme_excerpt" ] && printf 'README excerpt:\n%s\n\n' "$readme_excerpt")
$([ -n "$lang_markers" ] && printf 'Language markers: %s\n\n' "$lang_markers")
$([ -n "$adr_titles" ] && printf 'Architecture decisions:\n%s\n' "$adr_titles")

Output ONLY the markdown document — no preamble, no triple backticks, no explanation.
PROMPT
)"

    mkdir -p "$(dirname "$out_path")"
    local _draft_output=""
    _draft_output="$(route_to_model T2 "$prompt" --skip-precondition)" || {
        printf 'vision_init_draft: route_to_model failed (rc=%d)\n' "$?" >&2
        return 1
    }
    printf '%s\n' "$_draft_output" > "$out_path"
}

# ─── vision_condense <in_path> <out_path> ────────────────────────────────────
# Reads an existing vision document, condenses its body to ≤300 words while
# preserving headings, writes to <out_path>, then verifies the result
# passes validate_vision_doc before committing it.
vision_condense() {
    local in_path="${1:-}" out_path="${2:-}"
    if [[ -z "$in_path" || -z "$out_path" ]]; then
        printf 'vision_condense: in_path and out_path required\n' >&2
        return 1
    fi
    if [[ ! -f "$in_path" ]]; then
        printf 'vision_condense: file not found: %s\n' "$in_path" >&2
        return 1
    fi

    _vision_ensure_router

    local existing_content
    existing_content="$(<"$in_path")"

    local prompt
    prompt="$(cat <<PROMPT
Condense the following vision document. Requirements:
1. Preserve all headings exactly as they appear.
2. Reduce body text (non-heading lines) to 250 words or fewer.
3. Retain the essential meaning — do not change the substance.
4. Output ONLY the condensed markdown — no preamble, no triple backticks.

Document to condense:
${existing_content}
PROMPT
)"

    mkdir -p "$(dirname "$out_path")"
    local _tmp_out
    _tmp_out="$(mktemp)"
    local _condense_rc=0
    local _condensed=""
    _condensed="$(route_to_model T2 "$prompt" --skip-precondition)" || _condense_rc=$?
    if [[ $_condense_rc -ne 0 ]]; then
        rm -f "$_tmp_out"
        printf 'vision_condense: route_to_model failed (rc=%d)\n' "$_condense_rc" >&2
        return 1
    fi
    printf '%s\n' "$_condensed" > "$_tmp_out"

    # Validate before committing
    if ! validate_vision_doc "$_tmp_out" >/dev/null 2>&1; then
        local _diag
        _diag="$(validate_vision_doc "$_tmp_out" 2>&1 || true)"
        printf 'vision_condense: condensed output failed validation:\n%s\n' "$_diag" >&2
        rm -f "$_tmp_out"
        return 1
    fi

    mv "$_tmp_out" "$out_path"
}
