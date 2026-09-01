#!/usr/bin/env bash
# scripts/lib/lint-stage-checkpoint.sh — #1879
#
# ADR-054 catalogues a recurring defect in this project: a declaration nothing
# enforces. `valid_verdicts` sat in manifests for the life of the project with no
# engine code reading it (closed by #1876); `cleanup` was implemented by 20+
# plugins and never called. A `role: checkpoint` output is the same shape of
# claim, and an unknown key on an outputs entry is IGNORED by every manifest
# parser in the tree — so a typo is silent, and a checkpoint that is declared but
# unreadable would fail exactly the way the feature is supposed to prevent.
#
# This lint makes the declaration load-bearing at BUILD time. For every manifest
# declaring `role: checkpoint` it asserts:
#   1. the entry also declares a `path:` (a role with no path resolves to nothing);
#   2. the path resolves OUTSIDE the repository — a checkpoint written inside the
#      work tree would land in the build diff and trip a scope violation;
#   3. the entry declares `required: false` — a stage that converges early writes
#      no checkpoint, and a required-but-absent output fails the run closed;
#   4. the engine can actually resolve it (checkpoint_prompt_block emits a block).
#
# Usage: bash scripts/lib/lint-stage-checkpoint.sh [plugins_root]
# Exit:  0 = every declared checkpoint is well-formed and readable; 1 = violation.
set -euo pipefail

_LSC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LSC_ROOT="$(cd "$_LSC_DIR/../.." && pwd)"

PLUGINS_ROOT="${1:-$_LSC_ROOT/plugins}"

if [[ ! -d "$PLUGINS_ROOT" ]]; then
    echo "lint-stage-checkpoint: plugins root not found: $PLUGINS_ROOT" >&2
    exit 1
fi

# shellcheck source=../../core/pipeline/verdict.sh
source "$_LSC_ROOT/core/pipeline/verdict.sh" >/dev/null 2>&1 || true
# shellcheck source=./stage-checkpoint.sh
source "$_LSC_ROOT/scripts/lib/stage-checkpoint.sh"

# #2010: zbuild_engine_tmpdir names where engine code writes temp files.
# Lazy-sourced, same pattern lifecycle.sh uses for stage-scratch.sh: this
# file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmpdir >/dev/null 2>&1; then
    # shellcheck source=./helpers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/." && pwd)/helpers.sh" 2>/dev/null || true
fi


if ! declare -F checkpoint_prompt_block >/dev/null 2>&1; then
    echo "lint-stage-checkpoint: checkpoint_prompt_block not defined after sourcing stage-checkpoint.sh" >&2
    exit 1
fi

# A state dir that is definitively OUTSIDE the repo, used to resolve declared
# paths for the containment check.
_probe_state="$(mktemp -d "$(zbuild_engine_tmpdir)/zb-lint-cp.XXXXXX")"
trap 'rm -rf "$_probe_state"' EXIT
mkdir -p "$_probe_state/artifacts"

violations=0
declared=0

while IFS= read -r manifest; do
    grep -qE '^[[:space:]]+role:[[:space:]]*checkpoint([[:space:]]|$|#)' "$manifest" 2>/dev/null || continue
    declared=$((declared + 1))
    rel="${manifest#"$_LSC_ROOT"/}"

    # (1)+(4): the engine must resolve it to a real path and emit a block.
    resolved="$(_checkpoint_declared_path "$manifest" "$_probe_state" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
        echo "✗ $rel: declares 'role: checkpoint' but the engine resolves no path for it" >&2
        echo "    the same outputs[] entry must also declare a 'path:'." >&2
        violations=$((violations + 1))
        continue
    fi
    # Captured, NOT piped into `grep -q`: grep exits on the first match and
    # SIGPIPEs the producer, which under `set -o pipefail` makes the pipeline
    # fail and reports a violation for a perfectly good manifest.
    _block="$(checkpoint_prompt_block "$manifest" "$_probe_state" 2>/dev/null || true)"
    if [[ "$_block" != *'STAGE CHECKPOINT'* ]]; then
        echo "✗ $rel: declares 'role: checkpoint' but the engine emits no checkpoint block" >&2
        violations=$((violations + 1))
        continue
    fi

    # (2): containment. A checkpoint inside the work tree would enter the diff.
    case "$resolved" in
        "$_probe_state"/*) : ;;
        *)
            echo "✗ $rel: the checkpoint path does not resolve under the state dir: $resolved" >&2
            echo "    it must use \${artifact_dir}/ or \${state_dir}/ so it stays OUTSIDE the repository —" >&2
            echo "    a checkpoint written into the work tree lands in the build diff and trips scope." >&2
            violations=$((violations + 1))
            ;;
    esac

    # (3): required:false. A stage that converges early writes no checkpoint.
    if ! awk '
        /^outputs:/ { in_out=1 }
        in_out && /^[a-zA-Z_]/ && !/^outputs:/ { in_out=0 }
        in_out && /^[[:space:]]*-[[:space:]]*id:/ { req=""; role="" }
        in_out && /^[[:space:]]+required:[[:space:]]*false([[:space:]]|$|#)/ { req="false" }
        in_out && /^[[:space:]]+role:[[:space:]]*checkpoint([[:space:]]|$|#)/ {
            role="checkpoint"; if (req == "false") { ok=1; exit }
        }
        END { exit(ok ? 0 : 1) }
    ' "$manifest"; then
        echo "✗ $rel: the 'role: checkpoint' entry must also declare 'required: false'" >&2
        echo "    a stage that converges before writing one would otherwise fail closed." >&2
        violations=$((violations + 1))
    fi
done < <(find "$PLUGINS_ROOT" -name manifest.yaml -type f | sort)

if [[ "$violations" -gt 0 ]]; then
    echo "lint-stage-checkpoint: $violations violation(s) across $declared declaring manifest(s)" >&2
    exit 1
fi

echo "lint-stage-checkpoint: $declared manifest(s) declare a checkpoint, all resolve"
