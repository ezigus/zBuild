#!/usr/bin/env bash
# scripts/lib/lint-doc-freshness.sh — coverage, orphan, conformance, and freshness
# checks for docs/wiki/plugins/ and docs/wiki/mechanics/ (#1418).
#
# Checks (all run; failures accumulate before exit):
#   coverage    — every plugin id (from manifest.yaml id: field) and every
#                 mechanic name (from config/mechanics.yaml) has a wiki page
#   orphan      — every wiki page in both subdirs has a backing plugin/mechanic entry
#   conformance — every page opens with a plain-language newcomer prose sentence
#                 within the first 12 non-blank lines after its H1 (DOC-STYLE rule 1/5)
#   freshness   — opt-in per page: when a page contains a footer of the form
#                 <!-- zbuild-doc-hash: <hex> --> the sha256 of the source file
#                 (manifest.yaml for plugins; defined_in path from mechanics.yaml
#                 for mechanics) must match; pages without the footer are skipped
#
# Uses portable sha256 (sha256sum || shasum -a 256).
# Uses /usr/bin/grep for H1 scan (repo default grep may be ugrep).
# Exit 0 on clean pass; exit 1 if any check fails.
#
# Usage:
#   bash scripts/lib/lint-doc-freshness.sh

set -euo pipefail

SYSGREP=/usr/bin/grep

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
_PLUGINS_WIKI="$_REPO_ROOT/docs/wiki/plugins"
_MECHANICS_WIKI="$_REPO_ROOT/docs/wiki/mechanics"
_MECHANICS_YAML="$_REPO_ROOT/config/mechanics.yaml"

_failures=0
_fail() { printf '%s\n' "$1" >&2; _failures=$((_failures + 1)); }

# Portable sha256 hash of a file.
_sha256() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | cut -d' ' -f1
    else
        shasum -a 256 "$f" | cut -d' ' -f1
    fi
}

# Inlined from lint-doc-style.sh (not sourced) to avoid its load-time side effects.
_is_prose_opening() {
    local line="$1"

    # Strip a leading blockquote marker.
    line="${line#> }"; line="${line#>}"

    # Trim leading whitespace.
    line="${line#"${line%%[![:space:]]*}"}"

    [[ -n "$line" ]] || return 1

    # Reject structural / non-prose patterns by first token(s).
    case "$line" in
        '#'*)              return 1 ;;
        '```'*|'~~~'*)     return 1 ;;
        '|'*)              return 1 ;;
        '!['*|'<'*)        return 1 ;;
        '- '*|'* '*|'+ '*) return 1 ;;
        [0-9]'. '*|[0-9][0-9]'. '*) return 1 ;;
    esac

    # Must end in sentence punctuation (allowing one trailing `)` or emphasis close).
    local trimmed="${line%%[[:space:]]}"
    trimmed="${trimmed%[*_\`]}"
    trimmed="${trimmed%[*_\`]}"
    trimmed="${trimmed%)}"
    case "$trimmed" in
        *'.'|*'!'|*'?') : ;;
        *) return 1 ;;
    esac

    # Require at least 5 words — a real sentence, not a label fragment.
    local wc
    wc=$(printf '%s\n' "$line" | wc -w | tr -d '[:space:]')
    [[ "$wc" -ge 5 ]] || return 1

    return 0
}

# Conformance + (opt-in, footer-gated) freshness check for one wiki page.
_check_page() {
    local page="$1" source="$2"

    # ── conformance ──────────────────────────────────────────────────────────
    local h1_ln
    h1_ln="$($SYSGREP -n -m1 -E '^# ' "$page" | cut -d: -f1 || true)"
    if [[ -z "$h1_ln" ]]; then
        _fail "$page — no H1 title (# ...) found"
    else
        local found=0 nonblank=0 lineno=0 l
        while IFS= read -r l; do
            lineno=$((lineno + 1))
            [[ "$lineno" -le "$h1_ln" ]] && continue
            [[ -z "${l//[[:space:]]/}" ]] && continue
            nonblank=$((nonblank + 1))
            [[ "$nonblank" -gt 12 ]] && break
            if _is_prose_opening "$l"; then found=1; break; fi
        done < "$page"
        if [[ "$found" -ne 1 ]]; then
            _fail "$page — no newcomer prose opening in first 12 non-blank lines after H1 (DOC-STYLE rule 1/5)"
        fi
    fi

    # ── freshness (opt-in: skipped when footer absent) ────────────────────
    local hash_line embedded_hash
    hash_line="$($SYSGREP -E '<!-- zbuild-doc-hash: [0-9a-f]+ -->' "$page" | tail -1 || true)"
    if [[ -n "$hash_line" ]]; then
        embedded_hash="${hash_line#*<!-- zbuild-doc-hash: }"
        embedded_hash="${embedded_hash% -->*}"
        if [[ ! -f "$source" ]]; then
            _fail "$page — hash footer present but source file missing: $source"
        else
            local actual_hash
            actual_hash="$(_sha256 "$source")"
            if [[ "$actual_hash" != "$embedded_hash" ]]; then
                _fail "$page — doc hash mismatch (footer: ${embedded_hash:0:12}…, actual: ${actual_hash:0:12}…); regenerate with DOC-D"
            fi
        fi
    fi
}

# ── Build plugin id → manifest path map ──────────────────────────────────────
declare -A _plugin_manifests   # id → absolute manifest path
declare -A _persona_ids        # id → 1 for kind:persona plugins
while IFS= read -r _manifest; do
    _id="$(grep '^id:' "$_manifest" | head -1 | sed 's/^id:[[:space:]]*//')"
    _kind="$(grep '^kind:' "$_manifest" | head -1 | sed 's/^kind:[[:space:]]*//')"
    [[ -n "$_id" ]] && _plugin_manifests["$_id"]="$_manifest"
    [[ "$_kind" == "persona" ]] && [[ -n "$_id" ]] && _persona_ids["$_id"]=1
done < <(find "$_REPO_ROOT/plugins" -name "manifest.yaml" | sort)

# ── Build mechanic name → defined_in path map ─────────────────────────────────
declare -A _mechanic_defined_in  # name → repo-relative defined_in path
_cur_mechanic=""
while IFS= read -r _yaml_line; do
    case "$_yaml_line" in
        *'- name: '*)
            _cur_mechanic="${_yaml_line##*- name: }"
            ;;
        *'defined_in: '*)
            if [[ -n "$_cur_mechanic" ]]; then
                _mechanic_defined_in["$_cur_mechanic"]="${_yaml_line##*defined_in: }"
            fi
            ;;
    esac
done < "$_MECHANICS_YAML"

# ── 1. Coverage: every plugin id must have a wiki page ───────────────────────
# kind:persona plugins are exempt — their coverage is enforced via personas.md (section 1a).
for _id in "${!_plugin_manifests[@]}"; do
    [[ -n "${_persona_ids[$_id]+x}" ]] && continue
    _page="$_PLUGINS_WIKI/$_id.md"
    if [[ ! -f "$_page" ]]; then
        _fail "coverage: missing plugin wiki page for '$_id' (expected docs/wiki/plugins/$_id.md)"
    fi
done

# ── 1a. Persona index: personas.md must exist and list every persona id ───────
# Use ${_persona_ids[*]+x} rather than ${#_persona_ids[@]} — bash 5.x set -u treats
# an empty declared associative array as unbound for the # form.
if [[ -n "${_persona_ids[*]+x}" ]]; then
    _personas_page="$_PLUGINS_WIKI/personas.md"
    if [[ ! -f "$_personas_page" ]]; then
        _fail "coverage: docs/wiki/plugins/personas.md missing — required index for kind:persona plugins"
    else
        _check_page "$_personas_page" ""
        for _id in "${!_persona_ids[@]}"; do
            if ! $SYSGREP -qF "$_id" "$_personas_page"; then
                _fail "coverage: persona id '$_id' not listed in docs/wiki/plugins/personas.md"
            fi
        done
    fi
fi

# ── 2. Coverage: every mechanic must have a wiki page ────────────────────────
for _name in "${!_mechanic_defined_in[@]}"; do
    _page="$_MECHANICS_WIKI/$_name.md"
    if [[ ! -f "$_page" ]]; then
        _fail "coverage: missing mechanic wiki page for '$_name' (expected docs/wiki/mechanics/$_name.md)"
    fi
done

# ── 3. Conformance + freshness for plugin wiki pages ─────────────────────────
for _id in "${!_plugin_manifests[@]}"; do
    _page="$_PLUGINS_WIKI/$_id.md"
    [[ -f "$_page" ]] || continue
    _check_page "$_page" "${_plugin_manifests[$_id]}"
done

# ── 4. Conformance + freshness for mechanic wiki pages ───────────────────────
for _name in "${!_mechanic_defined_in[@]}"; do
    _page="$_MECHANICS_WIKI/$_name.md"
    [[ -f "$_page" ]] || continue
    _defined_in_path="${_mechanic_defined_in[$_name]}"
    _check_page "$_page" "$_REPO_ROOT/$_defined_in_path"
done

# ── 5. Orphan check: every plugin wiki page must have a backing manifest ──────
# 'personas' is the persona index page — no manifest with id:personas exists by design.
while IFS= read -r -d '' _page; do
    _slug="$(basename "$_page" .md)"
    [[ "$_slug" == "personas" ]] && continue
    if [[ -z "${_plugin_manifests[$_slug]+x}" ]]; then
        _fail "orphan: docs/wiki/plugins/$_slug.md has no backing plugin manifest with id '$_slug'"
    fi
done < <(find "$_PLUGINS_WIKI" -maxdepth 1 -name '*.md' -print0 | sort -z)

# ── 6. Orphan check: every mechanic wiki page must have a backing entry ───────
while IFS= read -r -d '' _page; do
    _slug="$(basename "$_page" .md)"
    if [[ -z "${_mechanic_defined_in[$_slug]+x}" ]]; then
        _fail "orphan: docs/wiki/mechanics/$_slug.md has no backing mechanic entry for '$_slug'"
    fi
done < <(find "$_MECHANICS_WIKI" -maxdepth 1 -name '*.md' -print0 | sort -z)

# ── Report ────────────────────────────────────────────────────────────────────
if [[ "$_failures" -gt 0 ]]; then
    printf '\nlint-doc-freshness: %d failure(s) — coverage, orphan, conformance, and freshness checks.\n' \
        "$_failures" >&2
    exit 1
fi

printf 'lint-doc-freshness: OK — %d plugin(s), %d mechanic(s) — all checks passed.\n' \
    "${#_plugin_manifests[@]}" "${#_mechanic_defined_in[@]}"
exit 0
