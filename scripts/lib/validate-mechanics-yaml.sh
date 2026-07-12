#!/usr/bin/env bash
# scripts/lib/validate-mechanics-yaml.sh — validate config/mechanics.yaml structure.
#
# A→B strategy:
#   A: parse with python3 + PyYAML + validate required fields
#   B: pure-bash/awk structural walk when python3 or PyYAML is unavailable
#
# Also verifies:
#   - every defined_in path resolves to an existing file in the repo
#   - every docs/wiki/mechanics/<name>.md has a matching registry entry
#
# Exit 0 on pass. Exit non-zero with error message on any failure.
# Override registry path via ZBUILD_MECHANICS_YAML env var (for tests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MECHANICS_YAML="${ZBUILD_MECHANICS_YAML:-$REPO_ROOT/config/mechanics.yaml}"
WIKI_MECHANICS_DIR="$REPO_ROOT/docs/wiki/mechanics"

# ─── helpers ─────────────────────────────────────────────────────────────────
_fail() { echo "validate-mechanics-yaml: ERROR: $*" >&2; exit 1; }
_info() { echo "validate-mechanics-yaml: $*"; }

[[ -f "$MECHANICS_YAML" ]] || _fail "registry not found: $MECHANICS_YAML"

# ─── Path A: python3 + PyYAML ────────────────────────────────────────────────
_validate_python() {
    python3 - "$MECHANICS_YAML" "$REPO_ROOT" <<'PYEOF'
import sys, os
try:
    import yaml
except ImportError:
    sys.exit(99)  # PyYAML unavailable — caller falls through to path B

registry_path, repo_root = sys.argv[1], sys.argv[2]

with open(registry_path) as f:
    data = yaml.safe_load(f)

if not isinstance(data, dict) or "mechanics" not in data:
    print("validate-mechanics-yaml: ERROR: missing top-level 'mechanics' key", file=sys.stderr)
    sys.exit(1)

mechanics = data["mechanics"]
if not isinstance(mechanics, list) or len(mechanics) == 0:
    print("validate-mechanics-yaml: ERROR: 'mechanics' must be a non-empty list", file=sys.stderr)
    sys.exit(1)

errors = []
names = []
for i, m in enumerate(mechanics):
    entry = f"mechanics[{i}]"
    if not isinstance(m, dict):
        errors.append(f"{entry}: not an object")
        continue
    name = m.get("name", "")
    defined_in = m.get("defined_in", "")
    if not name:
        errors.append(f"{entry}: missing or empty 'name'")
    if not defined_in:
        errors.append(f"{entry} ({name!r}): missing or empty 'defined_in'")
    else:
        full_path = os.path.join(repo_root, defined_in)
        if not os.path.isfile(full_path):
            errors.append(f"{entry} ({name!r}): defined_in path not found: {defined_in}")
    if name:
        names.append(name)

if errors:
    for e in errors:
        print(f"validate-mechanics-yaml: ERROR: {e}", file=sys.stderr)
    sys.exit(1)

# Verify wiki pages have registry entries
wiki_dir = os.path.join(repo_root, "docs", "wiki", "mechanics")
if os.path.isdir(wiki_dir):
    for fname in sorted(os.listdir(wiki_dir)):
        if fname.endswith(".md"):
            mechanic_name = fname[:-3]
            if mechanic_name not in names:
                print(f"validate-mechanics-yaml: ERROR: wiki page {fname} has no registry entry",
                      file=sys.stderr)
                sys.exit(1)

print(f"validate-mechanics-yaml: OK — {len(names)} mechanics validated")
PYEOF
}

# ─── Path B: pure-bash structural walk ───────────────────────────────────────
_validate_bash() {
    local -a names=()
    local current_name="" current_defined_in="" in_mechanics=0 entry_open=0

    _flush_entry() {
        [[ "$entry_open" -eq 0 ]] && return
        [[ -z "$current_name" ]]       && _fail "entry missing 'name' field"
        [[ -z "$current_defined_in" ]] && _fail "entry '$current_name' missing 'defined_in' field"
        [[ -f "$REPO_ROOT/$current_defined_in" ]] || \
            _fail "entry '$current_name': defined_in path not found: $current_defined_in"
        names+=("$current_name")
        current_name="" current_defined_in="" entry_open=0
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^mechanics: ]]; then
            in_mechanics=1; continue
        fi
        [[ "$in_mechanics" -eq 0 ]] && continue

        # new list item
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
            _flush_entry
            entry_open=1
            local rest="${line#*- }"
            if [[ "$rest" =~ ^name:[[:space:]]*(.*) ]]; then
                current_name="${BASH_REMATCH[1]}"
            fi
            continue
        fi

        [[ "$entry_open" -eq 0 ]] && continue

        if [[ "$line" =~ ^[[:space:]]+name:[[:space:]]*(.*) ]]; then
            current_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+defined_in:[[:space:]]*(.*) ]]; then
            current_defined_in="${BASH_REMATCH[1]}"
        fi
    done < "$MECHANICS_YAML"
    _flush_entry

    [[ "${#names[@]}" -gt 0 ]] || _fail "no mechanics entries found"

    # Verify wiki pages have registry entries
    if [[ -d "$WIKI_MECHANICS_DIR" ]]; then
        for wiki_file in "$WIKI_MECHANICS_DIR"/*.md; do
            [[ -f "$wiki_file" ]] || continue
            local mechanic_name found=0
            mechanic_name="$(basename "$wiki_file" .md)"
            for n in "${names[@]}"; do
                [[ "$n" == "$mechanic_name" ]] && found=1 && break
            done
            [[ "$found" -eq 1 ]] || \
                _fail "wiki page $(basename "$wiki_file") has no registry entry"
        done
    fi

    _info "OK (bash fallback) — ${#names[@]} mechanics validated"
}

# ─── dispatch: A first, fall through to B if python3/PyYAML unavailable ──────
if python3 -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
    py_rc=0
    _validate_python || py_rc=$?
    if [[ "$py_rc" -eq 99 ]]; then
        # PyYAML not installed — use bash fallback
        _validate_bash
    elif [[ "$py_rc" -ne 0 ]]; then
        exit "$py_rc"
    fi
else
    _validate_bash
fi
