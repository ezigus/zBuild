#!/usr/bin/env bash
# tests/unit/doc-publish-test.sh — DOC-F: regen + README refresh + wiki publish (#1420).
#
# Verifies scripts/lib/doc-publish.sh:
#   SPEC-1: doc_publish_update_readme inserts the generated-docs block (with counts)
#   SPEC-2: doc_publish_update_readme is idempotent — a second run yields ONE block
#   SPEC-3: _dp_wiki_remote derives <repo>.wiki.git from the origin remote
#   SPEC-4: doc_publish_wiki --dry-run prints "planned wiki:" and does NOT push
#   SPEC-5: doc_publish_wiki (live, mocked git) clones + commits + pushes to .wiki.git
#   SPEC-6: doc_publish_wiki excludes *.md.hash sidecars from the published tree
#   SPEC-7: doc_publish_run --dry-run prints planned regen + planned wiki, no push
#   SPEC-8: CLI `zbuild docs publish --dry-run` exits 0 and prints the planned lines
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/doc-publish.sh — regen + README + wiki publish (DOC-F #1420)"
setup_test_env "doc-publish"

# ── Fixture repo the publish functions operate on ─────────────────────────────
FIX="$TEST_TEMP_DIR/repo"
mkdir -p "$FIX/docs/wiki/plugins" "$FIX/docs/wiki/mechanics"
printf '# zBuild\n\nIntro paragraph.\n' > "$FIX/README.md"
printf '# build\n\nThe build stage writes code.\n' > "$FIX/docs/wiki/plugins/build.md"
printf '# plan\n\nThe plan stage decomposes work.\n' > "$FIX/docs/wiki/plugins/plan.md"
printf 'deadbeef\n' > "$FIX/docs/wiki/plugins/build.md.hash"   # sidecar — must NOT publish
printf '# cycle\n\nA cycle repeats members.\n' > "$FIX/docs/wiki/mechanics/cycle.md"
printf '# Home\n\nWelcome.\n' > "$FIX/docs/wiki/Home.md"

# Unit under test (transitively sources doc-generate.sh; the real generator is
# never invoked here, so no router mock is required).
# shellcheck source=../../scripts/lib/doc-publish.sh
source "$REPO_ROOT/scripts/lib/doc-publish.sh"

# One robust mock git: logs every command to GIT_LOG, and on `add` records the
# staged working tree (relative paths) to TREE_LOG so exclusions are inspectable.
_mockbin="$TEST_TEMP_DIR/bin"; mkdir -p "$_mockbin"
export GIT_LOG="$TEST_TEMP_DIR/git.log"
export TREE_LOG="$TEST_TEMP_DIR/tree.log"
cat > "$_mockbin/git" <<'MOCK'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${GIT_LOG:-/dev/null}"
dir="."
if [[ "${1:-}" == "-C" ]]; then dir="$2"; shift 2; fi
case "${1:-}" in
    remote) echo "https://github.com/ezigus/zBuild.git"; exit 0 ;;  # remote get-url origin
    clone)  dst="${!#}"; mkdir -p "$dst"; exit 0 ;;                 # last arg = destination
    add)    find "$dir" -type f ! -path '*/.git/*' 2>/dev/null | sed "s|^$dir/||" >> "${TREE_LOG:-/dev/null}"; exit 0 ;;
    diff)   exit 1 ;;                                               # pretend staged changes exist
    *)      exit 0 ;;
esac
MOCK
chmod +x "$_mockbin/git"
export ZBUILD_WIKI_GIT_CMD="$_mockbin/git"

# ── SPEC-1: README block insertion names the plugin/mechanic counts ───────────
print_test_section "SPEC-1: README generated-docs block inserted"
doc_publish_update_readme "$FIX" >/dev/null 2>&1
_readme="$(cat "$FIX/README.md")"
assert_contains "[SPEC-1] README gains the BEGIN marker" "$_readme" "<!-- BEGIN:generated-docs -->"
assert_contains "[SPEC-1] README gains the END marker"   "$_readme" "<!-- END:generated-docs -->"
assert_contains "[SPEC-1] README names 2 plugins"        "$_readme" "2 plugins"
assert_contains "[SPEC-1] README names 1 mechanics"      "$_readme" "1 mechanics"
assert_contains "[SPEC-1] original README content preserved" "$_readme" "Intro paragraph."

# ── SPEC-2: idempotent — second run keeps exactly ONE block, refreshed count ──
print_test_section "SPEC-2: README update is idempotent"
printf '# gates\n\nGates pass or fail a stage.\n' > "$FIX/docs/wiki/mechanics/gates.md"  # now 2 mechanics
doc_publish_update_readme "$FIX" >/dev/null 2>&1
_begins="$(grep -cF '<!-- BEGIN:generated-docs -->' "$FIX/README.md")"
assert_eq "[SPEC-2] exactly one generated-docs block after re-run" "1" "$_begins"
assert_contains "[SPEC-2] count refreshed to 2 mechanics" "$(cat "$FIX/README.md")" "2 mechanics"

# ── SPEC-3: wiki remote derivation from origin ────────────────────────────────
print_test_section "SPEC-3: _dp_wiki_remote derives <repo>.wiki.git"
_remote="$(_dp_wiki_remote "$FIX")"
assert_eq "[SPEC-3] derived wiki remote" "https://github.com/ezigus/zBuild.wiki.git" "$_remote"

# ── SPEC-4: dry-run prints planned + performs NO push ─────────────────────────
print_test_section "SPEC-4: doc_publish_wiki --dry-run does not push"
: > "$GIT_LOG"
_out="$(doc_publish_wiki "$FIX" "v1.0.0.1" "true" 2>&1)"
assert_contains "[SPEC-4] planned wiki line printed" "$_out" "planned wiki:"
if grep -qE 'git (clone|commit|push)' "$GIT_LOG" 2>/dev/null; then
    assert_fail "[SPEC-4] dry-run performs no git clone/commit/push" "$(cat "$GIT_LOG")"
else
    assert_pass "[SPEC-4] dry-run performs no git clone/commit/push"
fi

# ── SPEC-5: live publish clones + commits + pushes to the .wiki.git remote ────
print_test_section "SPEC-5: live wiki publish pushes to .wiki.git"
: > "$GIT_LOG"; : > "$TREE_LOG"
doc_publish_wiki "$FIX" "v1.0.0.1" "false" >/dev/null 2>&1 || true
_gitlog="$(cat "$GIT_LOG")"
assert_contains "[SPEC-5] git clone invoked"  "$_gitlog" "clone"
assert_contains "[SPEC-5] git commit invoked" "$_gitlog" "commit"
assert_contains "[SPEC-5] git push invoked"   "$_gitlog" "push"

# ── SPEC-6: hash sidecars excluded; real pages included ───────────────────────
print_test_section "SPEC-6: *.md.hash sidecars excluded from publish"
_tree="$(cat "$TREE_LOG")"
assert_contains "[SPEC-6] real plugin page published" "$_tree" "plugins/build.md"
if printf '%s\n' "$_tree" | grep -q '\.md\.hash$'; then
    assert_fail "[SPEC-6] no *.md.hash in published tree" "$_tree"
else
    assert_pass "[SPEC-6] no *.md.hash in published tree"
fi

# ── SPEC-7: doc_publish_run --dry-run prints planned regen + wiki, no push ────
print_test_section "SPEC-7: doc_publish_run --dry-run plans only"
: > "$GIT_LOG"
_out="$(doc_publish_run --dry-run --repo-root "$FIX" 2>&1)"
assert_contains "[SPEC-7] planned regen line" "$_out" "planned docs regen:"
assert_contains "[SPEC-7] planned wiki line"  "$_out" "planned wiki:"
if grep -qE 'git (clone|commit|push)' "$GIT_LOG" 2>/dev/null; then
    assert_fail "[SPEC-7] run --dry-run performs no push" "$(cat "$GIT_LOG")"
else
    assert_pass "[SPEC-7] run --dry-run performs no push"
fi

# ── SPEC-8: CLI surface — `zbuild docs publish --dry-run` ─────────────────────
print_test_section "SPEC-8: zbuild docs publish --dry-run"
set +e
_cli_out="$(ZBUILD_WIKI_REMOTE="https://example.invalid/x.wiki.git" \
    bash "$REPO_ROOT/scripts/zbuild" docs publish --dry-run 2>&1)"; _cli_rc=$?
set -e
assert_eq "[SPEC-8] CLI exits 0" "0" "$_cli_rc"
assert_contains "[SPEC-8] CLI prints planned regen" "$_cli_out" "planned docs regen:"
assert_contains "[SPEC-8] CLI prints planned wiki"  "$_cli_out" "planned wiki:"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
