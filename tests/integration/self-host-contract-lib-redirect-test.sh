#!/usr/bin/env bash
# Integration: self-host contract-lib redirect (#963). A working-tree-only
# acceptance-grammar extension is honored by the acceptance-gate in the SAME run
# via ZBUILD_CONTRACT_LIB_DIR. Subprocess-boundary: the gate runs in a clean
# `bash -c` child so the override env crosses the process boundary like a real run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "self-host contract-lib redirect (#963)"
setup_test_env "self-host-contract-redirect"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# ── Working-tree grammar: copy the real grammar libs, then EXTEND acceptance-
# block.sh to recognize a NEW testfiles sentinel token `TESTS:` that the installed
# reader does not. Models a #956-style grammar extension living only in the
# working tree. merge-base.sh is copied because negctl/reachability source it from
# their own dir.
OVERRIDE_LIB="$TEST_TEMP_DIR/wt-lib"
mkdir -p "$OVERRIDE_LIB"
for f in acceptance-block.sh acceptance-coverage.sh acceptance-negctl.sh \
         acceptance-reachability.sh merge-base.sh; do
    cp "$REPO_ROOT/scripts/lib/$f" "$OVERRIDE_LIB/$f"
done
# Grammar extension: accept `TESTS:` as an alias of the `TESTFILES:` section start
# inside extract_acceptance_block (its normalized output still emits `TESTFILES:`,
# so the sibling parsers need no change).
sed -i.bak "s/\"\$line\" == 'TESTFILES:' \]\]; then/\"\$line\" == 'TESTFILES:' || \"\$line\" == 'TESTS:' ]]; then/" \
    "$OVERRIDE_LIB/acceptance-block.sh"
rm -f "$OVERRIDE_LIB/acceptance-block.sh.bak"
# Guard: the sed actually changed the file (else the test would silently be inert).
if ! grep -q "TESTS:" "$OVERRIDE_LIB/acceptance-block.sh"; then
    echo "FATAL: grammar-extension sed did not patch acceptance-block.sh" >&2
    exit 2
fi

# repo whose `main` lacks impl and whose feature HEAD adds impl + load-bearing test
_build_repo() {
    local repo; repo="$(setup_git_temp_repo "$1")"
    (
        cd "$repo"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
        printf '%s\n' '#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
source "$impl"; my_feature' > tests/feature-test.sh
        chmod +x impl.sh tests/feature-test.sh
        "$GIT" add -A; "$GIT" commit -q -m feat
    )
    printf '%s' "$repo"
}

# design.md declaring TESTFILES via the NEW `TESTS:` token (not `TESTFILES:`).
_write_design() {
    cat > "$1/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTS:
tests/feature-test.sh
```
EOF
}

# Run the gate in a clean subprocess with an optional ZBUILD_CONTRACT_LIB_DIR.
# An empty override string falls back to the installed grammar (`:-` default).
_run_gate() {  # _run_gate <repo> <override_lib_or_empty> → sets RC, RESULT
    local repo="$1" override="$2"
    local state_dir="$repo/.zbuild-state"
    rm -rf "$state_dir"; mkdir -p "$state_dir/artifacts"
    cp "$repo/design.md" "$state_dir/artifacts/design.md"
    local ev_dir="$state_dir/events"; mkdir -p "$ev_dir"
    RC=0
    env _ZBUILD_ACCEPTANCE_GATE_LOADED= \
        ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
        ZBUILD_EVENTS_DIR="$ev_dir" \
        ZBUILD_EVENTS_JSONL="$ev_dir/events.jsonl" \
        ZBUILD_CONTRACT_LIB_DIR="$override" \
        bash -c '
            cd "$1" || exit 99
            source "$2/plugins/agent/spec-acceptance/plugin.sh"
            acceptance_gate_run "acceptance-gate" "$3/pipeline-state.json"
        ' _ "$repo" "$REPO_ROOT" "$state_dir" || RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
}

# ── WITH override: the working-tree grammar extension is honored → gate passes ─
print_test_section "1. override honors working-tree grammar extension"
REPO_W="$(_build_repo wt-redirect)"
_write_design "$REPO_W"
set +e; _run_gate "$REPO_W" "$OVERRIDE_LIB"; set -e
assert_eq "[SPEC-3] gate parses the new TESTS: token via override → rc=0" "0" "$RC"
assert_eq "[SPEC-3] gate verdict=pass with working-tree grammar" \
    "pass" "$(jq -r '.verdict' <<<"$RESULT")"

# ── CONTROL without override: the new token is NOT recognized → malformed fail ─
print_test_section "2. control — without override the new token is unrecognized"
REPO_C="$(_build_repo wt-control)"
_write_design "$REPO_C"
set +e; _run_gate "$REPO_C" ""; set -e
assert_eq "[SPEC-3] control: installed grammar rejects TESTS: token → rc=1" "1" "$RC"
assert_eq "[SPEC-3] control: verdict=fail (malformed, token unrecognized)" \
    "fail" "$(jq -r '.verdict' <<<"$RESULT")"
assert_contains "[SPEC-3] control: failure is malformed_acceptance_block" \
    "$(jq -r '.failures[]?, .reason // empty' <<<"$RESULT")" "malformed_acceptance_block"

cleanup_test_env
print_test_results
