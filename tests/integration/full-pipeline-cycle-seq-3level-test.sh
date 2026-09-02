#!/usr/bin/env bash
# Integration test (#698, Wave 16-A; #718, Wave 19-B; #842): full pipeline with
# cycles enabled exports N-level recursive seq labels for cycle members via
# ZBUILD_SEQ_PREFIX prefix accumulation.
#
# #979: repointed from the retired standard.yaml (whose build_review_cycle wrapped
# an inner build_test_cycle) to the owned minimal fixture
# tests/fixtures/templates/nested-cycle-seq.yaml, which reproduces the SAME 2-level
# nested-cycle topology the seq-label mechanic needs. The SUBJECT is the recursive
# ZBUILD_SEQ_PREFIX/label accumulation — template-agnostic; the fixture only has to
# nest a cycle inside a cycle.
#
# Drives runner.sh end-to-end with the fixture template:
#   stage:intake, stage:plan (leaf), cycle:design_cycle (design→gate),
#   cycle:outer_cycle (inner_cycle + probe), cycle:inner_cycle (build→test).
# Mocks plugins to log the observed ZBUILD_STAGE_IO_SEQ_LABEL and the
# visibility of ZBUILD_SEQ_PREFIX.
#
# Pinned assertions (plan is leaf at cardinal 2, design_cycle is cardinal 3,
# outer_cycle is cardinal 4):
#   intake          = "1"               (linear cardinal, no cycle env)
#   plan            = "2"               (linear leaf, no cycle env)
#   design_cycle (cardinal 3) → leaves:
#     design        = "3.1.1"
#     gate          = "3.1.2"
#   outer_cycle (cardinal 4) → inner_cycle (pos 1) → leaves at prefix "4.1.1":
#       build           = "4.1.1.1.1"
#       test            = "4.1.1.1.2"
#   outer_cycle (cardinal 4) → probe at pos 2 → "4.1.2".
#
# Wave 19-B also requires ZBUILD_SEQ_PREFIX visibility inside cycle members
# (the prefix the orchestrator passes down) AND no leak to pre-cycle stages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "full pipeline N-level recursive cycle seq labels (#698, #718)"
setup_test_env "full-pipeline-cycle-seq-3level"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
# #1921 follow-up: the runner resolves repo_root from CWD, so an in-process
# `main --issue N` snapshots into whatever repository the test happens to be
# standing in. This file used a REAL issue number and ran from the working
# checkout, adding 3 commits per run to refs/heads/zbuild/state/issue-698 —
# fabricated prior work on a real issue, which a later run would restore.
_ZB_ISSUE="$(zb_test_issue)"
_ZB_REPO="$(zb_test_repo cycle-seq-3level)"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
LABEL_LOG="$TEST_TEMP_DIR/labels.log"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_SEQ_LABEL_LOG="$LABEL_LOG"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"
: > "$LABEL_LOG"

# #979: the nested-cycle fixture is a NEW-shape (flow:) standalone template. The
# `.zbuild/templates/` overlay path is old-shape/full-replace-only (extends: + a
# flat stages: list) and cannot express nested cycles, and the runner's shipped-
# template resolver reads ONLY the engine tree's config/templates/ (not CWD). So a
# `bash runner.sh --template <id>` SUBPROCESS could only reach a NEW-shape template
# living in the real engine tree — which would require a guard-violating `cp` into
# $REPO_ROOT/config/templates/ (see templates-dir-hermeticity SPEC-6).
#
# Instead — mirroring runner-cycle-rc-action-mapping-test.sh and
# route-back-budget-config-test.sh — we SOURCE the runner in-process in a subshell
# and override resolve_template_file() to read the fixture directly from its git-
# tracked home under tests/fixtures/templates/. Nothing is ever written into the
# real repo, so the fixture stays hermetic and the SPEC-6 guard stays green.
_FIXTURE_TPL="$REPO_ROOT/tests/fixtures/templates/nested-cycle-seq.yaml"

# Mock plugin factory: every plugin logs the seq label + the visibility of
# ZBUILD_SEQ_PREFIX (so the assertions can pin both the recursive prefix shape
# AND the no-leak-into-pre/post-cycle-stages contract).
# $2 is the fixture's declared role: resolve_stage_plugin fails closed on a
# stage that declares roles: but resolves none, so a stub needs provides.role.
_make_plugin() {
    local id="$1" role="$2"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    local fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: agent
version: 0.0.1
provides:
  role: $role
hooks:
  run: $fn
requires:
  core:
    - redaction
EOF
    cat > "$dir/plugin.sh" <<PLUGIN
${fn}() {
    printf 'stage=%s label=%s prefix_env=%s\n' \\
        "$id" \\
        "\${ZBUILD_STAGE_IO_SEQ_LABEL:-MISSING}" \\
        "\${ZBUILD_SEQ_PREFIX:-UNSET}" \\
        >> "\${ZBUILD_SEQ_LABEL_LOG:-/dev/null}"
    return 0
}
PLUGIN
}

# Override for test: declares a primary output so exit_when can read the verdict,
# and writes {"verdict":"pass"} so inner_cycle converges after iter 1.
_make_verdict_plugin() {
    local id="$1" verdict="$2" role="$3"
    local dir="$PLUGINS_ROOT/agent/$id"
    local fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: agent
version: 0.0.1
provides:
  role: $role
hooks:
  run: $fn
requires:
  core:
    - redaction
outputs:
  - id: ${id}_out
    path: \${artifact_dir}/${id}.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<PLUG
${fn}() {
    printf 'stage=%s label=%s prefix_env=%s\n' \\
        "$id" \\
        "\${ZBUILD_STAGE_IO_SEQ_LABEL:-MISSING}" \\
        "\${ZBUILD_SEQ_PREFIX:-UNSET}" \\
        >> "\${ZBUILD_SEQ_LABEL_LOG:-/dev/null}"
    local state_dir; state_dir="\$(dirname "\$2")"
    mkdir -p "\$state_dir/artifacts"
    printf '{"verdict":"$verdict"}' > "\$state_dir/artifacts/${id}.json"
    return 0
}
PLUG
}

# Roles mirror nested-cycle-seq.yaml's per-stage roles: declarations.
while read -r s r; do
    _make_plugin "$s" "$r"
done <<'STUBS'
intake intake
plan planner
design designer
gate shape_floor
build builder
test tester
probe reviewer
STUBS
# design converges design_cycle (verdict=complete); test converges inner_cycle
# (verdict=pass); probe converges outer_cycle (verdict=approve).
_make_verdict_plugin design complete designer
_make_verdict_plugin test pass tester
_make_verdict_plugin probe approve reviewer

rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
export ZBUILD_STATE_FILE="$STATE_DIR/pipeline-state.json"
set +e
# #979: run the pipeline in-process (sourced runner) instead of a subprocess, so
# resolve_template_file can be overridden to read the fixture from tests/fixtures/
# without copying it into the real engine tree (SPEC-6 hermeticity).
(
    # cd FIRST: repo_root is resolved from CWD, so this is what keeps the
    # snapshot out of the real checkout. The engine is still sourced by
    # absolute path, so moving CWD does not change which code runs.
    cd "$_ZB_REPO" || exit 1
    # shellcheck disable=SC1091
    source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null
    resolve_template_file() { echo "$_FIXTURE_TPL"; }
    main --issue "$_ZB_ISSUE" --template nested-cycle-seq
) >"$TEST_TEMP_DIR/runner.out" 2>&1
rc=$?
set -e

# The runner returns non-zero for many post-pipeline conditions in this mock
# environment; we only care that the cycle members and post-cycle stages saw
# the expected labels. Don't assert rc=0.

_label_for() {
    local stage="$1" iter="$2"
    grep "^stage=${stage} " "$LABEL_LOG" \
        | sed -n "${iter}s/.*label=\([^ ]*\).*/\1/p"
}

_prefix_env_for() {
    local stage="$1"
    grep "^stage=${stage} " "$LABEL_LOG" \
        | head -1 \
        | sed -n 's/.*prefix_env=\(.*\)$/\1/p'
}

assert_eq "intake observed cardinal label 1"     "1"       "$(_label_for intake 1)"
# plan is a leaf at cardinal 2 (no cycle env).
assert_eq "plan observed label 2"                "2"       "$(_label_for plan 1)"
# design_cycle is cardinal 3; design=3.1.1, gate=3.1.2.
assert_eq "design observed label 3.1.1"          "3.1.1"   "$(_label_for design 1)"
assert_eq "gate observed label 3.1.2"            "3.1.2"   "$(_label_for gate 1)"

# build/test live inside inner_cycle (pos 1) inside outer_cycle (card 4)
# → leaves at "4.1.1.<inner_iter>.<inner_pos>".
assert_eq "build iter 1 label = 4.1.1.1.1"           "4.1.1.1.1" "$(_label_for build 1)"
assert_eq "test iter 1 label = 4.1.1.1.2"            "4.1.1.1.2" "$(_label_for test 1)"

# probe is outer_cycle pos 2 (after inner_cycle).
assert_eq "probe iter 1 label = 4.1.2"               "4.1.2"     "$(_label_for probe 1)"

# Inside the nested inner_cycle, members must see ZBUILD_SEQ_PREFIX="4.1.1"
# (outer_cycle's prefix 4 → its iter 1, pos 1 = inner_cycle).
assert_eq "build saw ZBUILD_SEQ_PREFIX=4.1.1"        "4.1.1" "$(_prefix_env_for build)"
assert_eq "test saw ZBUILD_SEQ_PREFIX=4.1.1"         "4.1.1" "$(_prefix_env_for test)"

# probe is a direct leaf member of outer_cycle; it sees prefix "4".
assert_eq "probe saw ZBUILD_SEQ_PREFIX=4"            "4" "$(_prefix_env_for probe)"

# Leak check: ZBUILD_SEQ_PREFIX must NOT leak into pre-cycle stages.
assert_eq "intake saw ZBUILD_SEQ_PREFIX UNSET" "UNSET" "$(_prefix_env_for intake)"
# plan is a linear leaf (no cycle); it sees ZBUILD_SEQ_PREFIX UNSET.
assert_eq "plan saw ZBUILD_SEQ_PREFIX UNSET (linear leaf, no cycle)" "UNSET" "$(_prefix_env_for plan)"
# design + gate are inside design_cycle (cardinal 3); they see prefix "3".
assert_eq "design saw ZBUILD_SEQ_PREFIX=3" "3" "$(_prefix_env_for design)"
assert_eq "gate saw ZBUILD_SEQ_PREFIX=3" "3" "$(_prefix_env_for gate)"

# ─── #833: cycle INPUT/OUTPUT banners appear (kind=cycle) ────────────────────
# The orchestrator emits a `[cycle]` banner per iter for each cycle. The runner
# routes stage-io banners to stderr (captured into runner.out by 2>&1 above).
runner_out="$(cat "$TEST_TEMP_DIR/runner.out" 2>/dev/null || true)"
if grep -q '\[cycle\].*input' <<< "$runner_out"; then
    assert_pass "#833 cycle INPUT banner ([cycle] ... input) present in pipeline output"
else
    assert_fail "#833 cycle INPUT banner present" "no '[cycle] ... input' line in runner.out"
fi
if grep -q '\[cycle\].*output' <<< "$runner_out"; then
    assert_pass "#833 cycle OUTPUT banner ([cycle] ... output) present in pipeline output"
else
    assert_fail "#833 cycle OUTPUT banner present" "no '[cycle] ... output' line in runner.out"
fi
# The cycle banner's stage token is the cycle id, distinct from the leaf ids —
# proving the cycle seq counter uses the cycle stage-id namespace.
if grep -qE 'design_cycle \[cycle\]|outer_cycle \[cycle\]|inner_cycle \[cycle\]' <<< "$runner_out"; then
    assert_pass "#833 cycle banner stage token is a cycle id (distinct namespace)"
else
    assert_fail "#833 cycle banner stage token is a cycle id" "no cycle-id [cycle] banner found"
fi

# ─── #833 regression guard: inner-leaf hierarchical seq labels UNCHANGED ─────
# The cycle banner uses the cycle stage-id namespace, so leaf labels (N.k) must
# not shift. Re-assert the key leaf labels (already pinned above; restated here
# as the explicit no-regression contract the #833 change must preserve).
assert_eq "#833 design leaf label still 3.1.1"          "3.1.1"     "$(_label_for design 1)"
assert_eq "#833 build leaf label still 4.1.1.1.1"       "4.1.1.1.1" "$(_label_for build 1)"
assert_eq "#833 test leaf label still 4.1.1.1.2"        "4.1.1.1.2" "$(_label_for test 1)"

print_test_results
cleanup_test_env
