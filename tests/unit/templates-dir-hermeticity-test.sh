#!/usr/bin/env bash
# tests/unit/templates-dir-hermeticity-test.sh
# #1268: static guard — NO test may WRITE into the tracked
# $REPO_ROOT/config/templates/. Copying a fixture there and removing it via a
# bare _test_cleanup_hook (NOT a trap EXIT) leaks the fixture into the source
# tree on any interrupted / early-exit run (the perf-fixture stray that derailed
# the #1214/#1215/#945-run-1 dogfoods). Tests must instead call
# install_template_fixture, which stages fixtures under TEST_TEMP_DIR and points
# the resolver there via ZBUILD_TEMPLATES_DIR (reaped by the master trap).
#
# READS are fine: `load_template "$REPO_ROOT/config/templates/…"` and a
# STANDARD_TPL="…/config/templates/…" that is only ever passed to load_template.
# The setup_git_temp_repo sandbox ($REPO/config/templates, $FAKE_ROOT/…,
# $TEST_TEMP_DIR/…) is a temp tree, not the real repo dir, so it is excluded by
# matching the REPO_ROOT var only.
#
# SPEC-6 [guard]: bidirectional — RED on the pre-migration tree (9 writers),
# GREEN once every writer moves to install_template_fixture.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# The repo's default `grep` is ugrep with ERE quirks (MEMORY #1260); use the
# system grep for deterministic matching in a guard scan.
GREP=/usr/bin/grep

print_test_header "templates-dir hermeticity — no test writes into config/templates/ (#1268)"

# A safety guard must NEVER pass vacuously. If /usr/bin/grep is missing or not
# executable every scan grep would fail, the offender list would come back empty,
# and the guard would report a FALSE GREEN. Assert the tool up front and FAIL
# loudly (non-zero) instead — a broken scanner is a test failure, not a pass.
if [[ ! -x "$GREP" ]]; then
    assert_fail "[SPEC-6] scanner precondition: $GREP is executable" \
        "the hermeticity scan requires an executable $GREP; refusing to scan-and-pass vacuously"
    print_test_results
fi

# Repo-rooted config/templates path fragment. Matches only the REAL repo dir
# ($REPO_ROOT / ${REPO_ROOT}); sandbox roots ($REPO, $FAKE_ROOT, $TEST_TEMP_DIR)
# never carry the REPO_ROOT name and so are excluded.
#
# KNOWN COVERAGE TRADEOFF (#1268): detection keys on the literal var name
# REPO_ROOT. A future writer that reaches the REAL config/templates/ through a
# DIFFERENTLY-named var (e.g. `MYROOT="$(git rev-parse --show-toplevel)"; cp …
# "$MYROOT/config/templates/…"`) would be missed. This is deliberate: widening
# the path regex to any `…/config/templates` would false-positive on the many
# legitimate sandbox writes ($REPO/$FAKE_ROOT/$FIX/$TEST_TEMP_DIR — see the
# survey in #1268). REPO_ROOT is the one convention every real test uses for the
# repo root, so anchoring on it is the high-precision choice; broadening is left
# as an explicit non-goal.
_rp='\$\{?REPO_ROOT\}?/config/templates'

# _is_write_target <file> — 0 if the file WRITES into $REPO_ROOT/config/templates
_is_write_target() {
    local f="$1"
    # A) direct literal write: `cp … $REPO_ROOT/config/templates` or a
    #    `> $REPO_ROOT/config/templates` redirect (no variable indirection).
    if "$GREP" -Eq "cp[[:space:]].*${_rp}" "$f" \
       || "$GREP" -Eq ">>?[[:space:]]*\"?${_rp}" "$f"; then
        return 0
    fi
    # B) indirect: a variable assigned to $REPO_ROOT/config/templates that is
    #    then used as a `cp` destination or a `>`/`>>` redirect target. Read
    #    vars (assigned but only fed to load_template) never match the usage
    #    grep, so STANDARD_TPL/SIMPLE_TPL-style reads stay clean.
    local vars v
    vars="$("$GREP" -oE "[A-Za-z_][A-Za-z0-9_]*=\"?${_rp}" "$f" 2>/dev/null \
            | "$GREP" -oE "^[A-Za-z_][A-Za-z0-9_]*" | sort -u)"
    for v in $vars; do
        # The var is always the DESTINATION for these installs, so matching it
        # anywhere on a cp line (trailing `2>/dev/null || true` and all) is safe.
        # Anchor the var name so `FOO` does NOT match a `$FOOBAR` usage: accept
        # the braced form `${FOO}` (self-delimited) OR the bare form `$FOO`
        # followed by a non-word char or end-of-line.
        local _vref="(\\\$\\{${v}\\}|\\\$${v}([^A-Za-z0-9_]|\$))"
        if "$GREP" -Eq "cp[[:space:]].*${_vref}" "$f" \
           || "$GREP" -Eq ">>?[[:space:]]*\"?${_vref}" "$f"; then
            return 0
        fi
    done
    return 1
}

# This guard file itself is a READER (it greps for the write patterns); its
# source necessarily contains the very cp/redirect strings it hunts for, so it
# must be excluded from its own scan.
_self="${BASH_SOURCE[0]##*/}"
offenders=()
while IFS= read -r f; do
    [[ "${f##*/}" == "$_self" ]] && continue
    _is_write_target "$f" && offenders+=("${f#"$REPO_ROOT/"}")
done < <(find "$REPO_ROOT/tests" -name '*.sh' -type f | sort)

if [[ ${#offenders[@]} -eq 0 ]]; then
    assert_pass "[SPEC-6] zero tests write into \$REPO_ROOT/config/templates/"
else
    printf '  offender: %s\n' "${offenders[@]}" >&2
    assert_fail "[SPEC-6] zero tests write into \$REPO_ROOT/config/templates/" \
        "${#offenders[@]} writer(s): ${offenders[*]}"
fi

print_test_results
