#!/usr/bin/env bash
# scripts/run-mutation.sh — mutation testing harness (issue #298)
#
# For each tests/mutation/*.md spec:
#   1. Lint required structural sections (## File / ## Mutation /
#      ## Expected failing test / ## Result / ## Patch / ## Test).
#   2. Extract the ```bash code block under ## Patch — apply it (mutates code).
#   3. Extract the ```bash code block under ## Test — run it; expect non-zero.
#   4. Restore EVERY patch-touched file (tracked → git checkout; untracked →
#      rm). EXIT trap restores on crash too.
#
# Safety invariants:
#   - Refuses to run if any mutation-target dir (core/plugins/scripts/tests)
#     has uncommitted tracked changes OR untracked files. Prevents conflating
#     user's WIP with patch artifacts.
#   - Restores ONLY patch-introduced changes (tracks pre/post snapshots);
#     never touches user's pre-existing work elsewhere.
#   - .mutbak cleanup scoped to mutation-target dirs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUTATION_DIR="$REPO_ROOT/tests/mutation"
MUTATE_DIRS=(core plugins scripts tests)

passed=0
failed=0
results=()

# Files the current/last patch added or modified — for EXIT-trap restore.
declare -a _PATCH_MODIFIED=()
declare -a _PATCH_UNTRACKED=()

# ─── Helpers ────────────────────────────────────────────────────────────────

_extract_bash_block() {
    local file="$1" header="$2"
    awk -v hdr="$header" '
        $0 == hdr            { in_section = 1; next }
        in_section && /^## / { in_section = 0 }
        in_section && /^```bash[[:space:]]*$/ { in_code = 1; next }
        in_code && /^```[[:space:]]*$/ { in_code = 0; exit }
        in_code              { print }
    ' "$file"
}

# Extract the first backticked path from the line(s) following a ## header.
# Returns the path with surrounding backticks stripped, empty on miss.
# Pure-awk so the function never trips errexit/pipefail (the previous
# `grep -oE ... | head -1` pipeline could exit non-zero on no-match or
# SIGPIPE on multi-match — #322 review L56).
_extract_backticked_path() {
    local file="$1" header="$2"
    awk -v hdr="$header" '
        $0 == hdr            { in_section = 1; next }
        in_section && /^## / { exit }
        in_section {
            line = $0
            while (match(line, /`[^`]+`/)) {
                tok = substr(line, RSTART + 1, RLENGTH - 2)
                if (tok != "") {
                    print tok
                    exit
                }
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$file" 2>/dev/null || true
}

# Verify the doc's "## Expected failing test" path is *plausibly related*
# to the "## File" being mutated — i.e., the test either lives in a path that
# shares a stem with the mutated file, OR it references the mutated file
# path/basename in its contents. Issue #309: prevents a mutation that patches
# core/router/ from naming an unrelated tests/unit/core-redaction-test.sh as
# its expected-failing test (which would pass for the wrong reason).
#
# Returns 0 if related, 1 if not relateable, 2 if either path is missing.
_check_mutation_relevance() {
    local doc="$1"
    local file_path test_path
    file_path="$(_extract_backticked_path "$doc" "## File")"
    test_path="$(_extract_backticked_path "$doc" "## Expected failing test")"

    if [[ -z "$file_path" || -z "$test_path" ]]; then
        return 2
    fi

    # The test file must exist on disk relative to repo root.
    if [[ ! -f "$REPO_ROOT/$test_path" ]]; then
        return 2
    fi

    # Stem overlap: the mutated file's basename stem (without .sh) AND each
    # directory component contributes a candidate token. The test path must
    # contain at least one of them.
    local file_base="${file_path##*/}"
    local file_stem="${file_base%.*}"            # e.g., scope-redaction
    local file_dir="${file_path%/*}"             # e.g., core/redaction
    local file_dir_leaf="${file_dir##*/}"        # e.g., redaction

    local token tokens=("$file_stem" "$file_dir_leaf")
    # Also tokenize the stem on '-' to allow partial-stem matches
    # (e.g., scope-redaction → scope, redaction).
    local IFS_BAK="$IFS"; IFS="-"
    # shellcheck disable=SC2206
    local stem_parts=( $file_stem )
    IFS="$IFS_BAK"
    for token in "${stem_parts[@]}"; do
        [[ ${#token} -ge 4 ]] && tokens+=("$token")
    done

    local t
    for t in "${tokens[@]}"; do
        [[ -z "$t" ]] && continue
        if [[ "$test_path" == *"$t"* ]]; then
            return 0
        fi
        # Or the test source references the mutated file path/basename.
        # `-F` keeps the search literal — file stems can include `.` or `[`
        # (multi-dot names) which would otherwise be interpreted as regex
        # metacharacters and silently miss or false-match (#322 review L108).
        if grep -qF -- "$t" "$REPO_ROOT/$test_path" 2>/dev/null; then
            return 0
        fi
    done

    # Last chance: does the test source the mutated file directly?
    if grep -qF "$file_path" "$REPO_ROOT/$test_path" 2>/dev/null \
       || grep -qF "$file_base" "$REPO_ROOT/$test_path" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Restore everything the last patch touched: `git checkout --` tracked
# modifications (always tried, even if file was deleted), and `rm` untracked
# files the patch created. Then forget the lists.
_restore_patches() {
    local f
    for f in "${_PATCH_MODIFIED[@]:-}"; do
        [[ -z "$f" ]] && continue
        # Try checkout unconditionally — handles deleted/renamed files too.
        git -C "$REPO_ROOT" checkout -- "$f" 2>/dev/null || true
    done
    for f in "${_PATCH_UNTRACKED[@]:-}"; do
        [[ -z "$f" ]] && continue
        rm -f "$REPO_ROOT/$f" 2>/dev/null || true
    done
    _PATCH_MODIFIED=()
    _PATCH_UNTRACKED=()
}

# Refuse if the working tree has ANY change in mutation-target dirs.
# This is essential: patch detection compares snapshots, and a pre-existing
# diff would be either silently restored (data loss) or silently skipped
# (mutation leaks past the cleanup). Both are bad.
_assert_clean_targets() {
    local dirty untracked
    dirty="$(cd "$REPO_ROOT" && git diff --name-only -- "${MUTATE_DIRS[@]}" 2>/dev/null || true)"
    untracked="$(cd "$REPO_ROOT" && git ls-files --others --exclude-standard -- "${MUTATE_DIRS[@]}" 2>/dev/null || true)"
    if [[ -n "$dirty" || -n "$untracked" ]]; then
        echo "run-mutation.sh: refusing — working tree has uncommitted changes" >&2
        echo "  in mutation-target dirs (${MUTATE_DIRS[*]})." >&2
        [[ -n "$dirty" ]]     && echo "  modified:" >&2 && echo "$dirty"     | sed 's/^/    /' >&2
        [[ -n "$untracked" ]] && echo "  untracked:" >&2 && echo "$untracked" | sed 's/^/    /' >&2
        echo "  Commit or stash them first." >&2
        exit 1
    fi
}

# Snapshot current tracked-modifications + untracked in mutation-target dirs.
# Emits two newline-delimited lists separated by a sentinel "---".
_snapshot_targets() {
    (cd "$REPO_ROOT" && git diff --name-only -- "${MUTATE_DIRS[@]}" 2>/dev/null || true)
    echo "---SNAPSHOT-SEPARATOR---"
    (cd "$REPO_ROOT" && git ls-files --others --exclude-standard -- "${MUTATE_DIRS[@]}" 2>/dev/null || true)
}

# Diff two snapshots; populate _PATCH_MODIFIED + _PATCH_UNTRACKED with NEW
# entries only (entries that appeared post-patch but not pre-patch).
_compute_patch_delta() {
    local pre="$1" post="$2"
    local pre_mod pre_unt post_mod post_unt
    pre_mod="$(echo "$pre"  | awk '/^---SNAPSHOT-SEPARATOR---$/{exit} {print}')"
    pre_unt="$(echo "$pre"  | awk '/^---SNAPSHOT-SEPARATOR---$/{seen=1; next} seen{print}')"
    post_mod="$(echo "$post" | awk '/^---SNAPSHOT-SEPARATOR---$/{exit} {print}')"
    post_unt="$(echo "$post" | awk '/^---SNAPSHOT-SEPARATOR---$/{seen=1; next} seen{print}')"

    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        grep -Fxq "$f" <<< "$pre_mod" || _PATCH_MODIFIED+=("$f")
    done <<< "$post_mod"

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        grep -Fxq "$f" <<< "$pre_unt" || _PATCH_UNTRACKED+=("$f")
    done <<< "$post_unt"
}

# EXIT trap restores last patch's touched files; never touches pre-existing.
trap '_restore_patches' EXIT INT TERM

# ─── Main loop ──────────────────────────────────────────────────────────────

_assert_clean_targets

for doc in "$MUTATION_DIR"/*.md; do
    [[ -f "$doc" ]] || continue
    name="$(basename "$doc")"

    structural_ok=1
    for section in "## File" "## Mutation" "## Expected failing test" "## Result" "## Patch" "## Test"; do
        if ! grep -qF "$section" "$doc"; then
            echo "FAIL $name: missing section '$section'" >&2
            structural_ok=0
        fi
    done
    if [[ $structural_ok -eq 0 ]]; then
        failed=$((failed + 1))
        results+=("FAIL  $name  (structural)")
        continue
    fi

    # Relevance gate (#309): expected-failing-test must plausibly exercise the
    # mutated file. Refuses to run mutations that name an unrelated test.
    relevance_rc=0
    _check_mutation_relevance "$doc" || relevance_rc=$?
    if [[ $relevance_rc -eq 2 ]]; then
        echo "FAIL $name: could not parse File and/or Expected failing test paths (missing or test file absent)" >&2
        failed=$((failed + 1))
        results+=("FAIL  $name  (relevance: unparseable / missing test file)")
        continue
    fi
    if [[ $relevance_rc -eq 1 ]]; then
        file_path_msg="$(_extract_backticked_path "$doc" "## File")"
        test_path_msg="$(_extract_backticked_path "$doc" "## Expected failing test")"
        echo "FAIL $name: expected-failing-test '$test_path_msg' has no path/content link to mutated '$file_path_msg' (#309)" >&2
        failed=$((failed + 1))
        results+=("FAIL  $name  (relevance: test does not exercise mutated file)")
        continue
    fi

    patch_code="$(_extract_bash_block "$doc" "## Patch")"
    test_code="$(_extract_bash_block "$doc" "## Test")"
    if [[ -z "$patch_code" || -z "$test_code" ]]; then
        echo "FAIL $name: ## Patch and/or ## Test bash block is empty" >&2
        failed=$((failed + 1))
        results+=("FAIL  $name  (empty patch/test block)")
        continue
    fi

    # Snapshot, patch, snapshot, compute delta.
    pre_snap="$(_snapshot_targets)"

    if ! (cd "$REPO_ROOT" && bash -c "set -euo pipefail; $patch_code"); then
        echo "FAIL $name: patch script returned non-zero" >&2
        # Compute delta first so _restore_patches knows what to clean.
        post_snap="$(_snapshot_targets)"
        _compute_patch_delta "$pre_snap" "$post_snap"
        _restore_patches
        failed=$((failed + 1))
        results+=("FAIL  $name  (patch failed)")
        continue
    fi

    post_snap="$(_snapshot_targets)"
    _compute_patch_delta "$pre_snap" "$post_snap"

    if [[ ${#_PATCH_MODIFIED[@]} -eq 0 && ${#_PATCH_UNTRACKED[@]} -eq 0 ]]; then
        echo "FAIL $name: patch ran but touched no files (sed/awk no-op?)" >&2
        _restore_patches   # cleans any spurious .mutbak even if patch was no-op
        failed=$((failed + 1))
        results+=("FAIL  $name  (no-op patch)")
        continue
    fi

    # Run targeted test; expect NON-ZERO.
    set +e
    (cd "$REPO_ROOT" && bash -c "$test_code") >/dev/null 2>&1
    test_rc=$?
    set -e

    _restore_patches

    if [[ $test_rc -ne 0 ]]; then
        passed=$((passed + 1))
        results+=("PASS  $name  (caught: rc=$test_rc)")
    else
        echo "FAIL $name: mutation was NOT caught — test passed despite the mutation" >&2
        failed=$((failed + 1))
        results+=("FAIL  $name  (mutation slipped past test — coverage gap)")
    fi
done

# Match the other tiers' output shape: emit just the count line on full pass.
# On failure, surface the per-spec results table so the failing entries are
# visible without re-running.
if [[ $failed -ne 0 ]]; then
    echo
    echo "─── Mutation test results ──────────────────────────────"
    for line in "${results[@]}"; do
        echo "  $line"
    done
    echo "──────────────────────────────────────────────────────"
fi
echo "mutation: $passed/$((passed + failed)) passed"

[[ $failed -eq 0 ]]
