#!/usr/bin/env bash
# tests/unit/lint-doc-style-test.sh — DOC-STYLE.md newcomer-opening enforcement (#1406).
#
# Verifies scripts/lib/lint-doc-style.sh:
#   - PASSES on a conforming fixture (H1 followed by a plain prose sentence)
#   - FAILS (rc=1, names the file) on non-conforming fixtures (H1 immediately
#     followed by a code fence / table / bullet list)
#   - PASSES on the real in-scope repo docs (README + top-level wiki pages),
#     so a future non-conforming page trips CI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/lint-doc-style.sh — DOC-STYLE.md newcomer opening (#1406)"
setup_test_env "lint-doc-style"

CHECKER="$REPO_ROOT/scripts/lib/lint-doc-style.sh"

# Build a self-contained fixture repo so the checker resolves ITS root (two
# dirs up from the script) to our temp tree, not the real repo. We copy the
# real checker in and lay down README.md + docs/wiki/*.md around it.
build_fixture_repo() {
    local root="$1"
    mkdir -p "$root/scripts/lib" "$root/docs/wiki"
    cp "$CHECKER" "$root/scripts/lib/lint-doc-style.sh"
}

# --- TC-1: conforming fixture passes -----------------------------------------
FX_OK="$TEST_TEMP_DIR/ok"
build_fixture_repo "$FX_OK"
cat > "$FX_OK/README.md" <<'EOF'
# Widget

Widget is a small tool that helps you do a thing quickly and consistently.

## Details
EOF
cat > "$FX_OK/docs/wiki/Home.md" <<'EOF'
# Widget

**Widget runs your task through the same steps every time, so results stay predictable.**

## More
EOF
# _Sidebar.md is out of scope and must be ignored even though it has no opening.
cat > "$FX_OK/docs/wiki/_Sidebar.md" <<'EOF'
- [[Home]]
EOF
rc=0
out="$(bash "$FX_OK/scripts/lib/lint-doc-style.sh" 2>&1)" || rc=$?
assert_eq "TC-1: conforming fixture passes (rc=0)" "0" "$rc"
assert_contains "TC-1: prints a clean pass line" "$out" "OK"

# --- TC-2: H1 immediately followed by a code fence fails ---------------------
FX_CODE="$TEST_TEMP_DIR/code"
build_fixture_repo "$FX_CODE"
cat > "$FX_CODE/README.md" <<'EOF'
# Widget

The widget is a plain-language opener that keeps README conforming and green.

## OK
EOF
# The code fence and its contents fill the whole post-H1 window with no prose
# sentence, so there is no newcomer opening to find.
cat > "$FX_CODE/docs/wiki/Home.md" <<'EOF'
# Widget

```bash
widget --run
widget --status
widget --resume
```
EOF
rc=0
out="$(bash "$FX_CODE/scripts/lib/lint-doc-style.sh" 2>&1)" || rc=$?
assert_eq "TC-2: code-fence opening fails (rc=1)" "1" "$rc"
assert_contains "TC-2: diagnostic names the offending file" "$out" "Home.md"

# --- TC-3: H1 immediately followed by a table fails --------------------------
FX_TABLE="$TEST_TEMP_DIR/table"
build_fixture_repo "$FX_TABLE"
cat > "$FX_TABLE/README.md" <<'EOF'
# Widget

The widget is a plain-language opener that keeps README conforming and green.

## OK
EOF
cat > "$FX_TABLE/docs/wiki/Home.md" <<'EOF'
# Widget

| Command | Purpose |
|---|---|
| run | do the thing |
EOF
rc=0
out="$(bash "$FX_TABLE/scripts/lib/lint-doc-style.sh" 2>&1)" || rc=$?
assert_eq "TC-3: table opening fails (rc=1)" "1" "$rc"
assert_contains "TC-3: diagnostic names the offending file" "$out" "Home.md"

# --- TC-4: H1 immediately followed by a bullet list fails --------------------
FX_LIST="$TEST_TEMP_DIR/list"
build_fixture_repo "$FX_LIST"
cat > "$FX_LIST/README.md" <<'EOF'
# Widget

The widget is a plain-language opener that keeps README conforming and green.

## OK
EOF
cat > "$FX_LIST/docs/wiki/Home.md" <<'EOF'
# Widget

- first bullet item without any opening prose
- second bullet item that is also not a sentence
- third one
EOF
rc=0
out="$(bash "$FX_LIST/scripts/lib/lint-doc-style.sh" 2>&1)" || rc=$?
assert_eq "TC-4: bullet-list opening fails (rc=1)" "1" "$rc"
assert_contains "TC-4: diagnostic names the offending file" "$out" "Home.md"

# --- TC-5: blockquote sentence counts as a conforming opening ----------------
FX_BQ="$TEST_TEMP_DIR/blockquote"
build_fixture_repo "$FX_BQ"
cat > "$FX_BQ/README.md" <<'EOF'
# Widget

> Widget is a small tool that helps you do a thing quickly and consistently.

## Details
EOF
cat > "$FX_BQ/docs/wiki/Home.md" <<'EOF'
# Widget

Widget keeps your work consistent by running the same steps on every task.
EOF
rc=0
out="$(bash "$FX_BQ/scripts/lib/lint-doc-style.sh" 2>&1)" || rc=$?
assert_eq "TC-5: blockquote-sentence opening passes (rc=0)" "0" "$rc"

# --- TC-6: the REAL repo docs pass (a future bad page would trip CI) ---------
rc=0
out="$(bash "$CHECKER" 2>&1)" || rc=$?
assert_eq "TC-6: real in-scope repo docs pass lint (rc=0)" "0" "$rc"
assert_contains "TC-6: pass line reports in-scope page count" "$out" "in-scope page"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
