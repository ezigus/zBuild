#!/usr/bin/env bash
# tests/unit/attempt-archive-cost-test.sh — what one dispatch's attempt record
# starts (ADR-065 §5, round 5).
#
# Every run hook is fingerprinted before and after, and its outputs archived.
# That cost 254 programs in a mocked full run: a cksum of every declared output
# twice (absent ones too), an awk per output to look up its earlier sum, a jq per
# output to build one object, a date, three reads of the manifest, and the
# before fingerprint taken in a `$( )` copy of the whole engine shell.
#
# The stage below declares three outputs: o1 is absent before the run and
# written by it; o2 exists and is rewritten with the same bytes; o3 exists and
# is changed.
#
# C1 [change] the dispatch's record starts awk once (the manifest), cksum four
#             times (o2 and o3, before and after), cp three times, mkdir and
#             jq once each — nothing else
# C2 [change] …and runs none of it in a `$( )` copy of the engine shell
# C3 [guard]  the record still says o1 changed, o2 unchanged, o3 changed, with
#             a UTC generated_at, and stage.outputs.unchanged names o2
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/fork-census.sh
source "$REPO_ROOT/scripts/lib/fork-census.sh"

print_test_header "attempt record: what one dispatch starts (ADR-065 §5)"
setup_test_env "attempt-archive-cost"

PDIR="$TEST_TEMP_DIR/plugins/tool/cs"; STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"
mkdir -p "$PDIR" "$ART" "$TEST_TEMP_DIR/ev"
cat > "$PDIR/manifest.yaml" <<'EOF'
id: cs
name: cs
kind: tool
version: 0.0.1
hooks:
  run: cs_run
requires:
  core:
    - redaction
provides:
  result_contract: 3
outputs:
  - id: o1
    path: ${artifact_dir}/o1.json
    type: json
    required: true
    primary: true
  - id: o2
    path: ${artifact_dir}/o2.md
    type: markdown
    required: false
    summary: true
  - id: o3
    path: ${artifact_dir}/o3.log
    type: text
    required: false
EOF
cat > "$PDIR/plugin.sh" <<'EOF'
cs_run() {
    local a="${ZBUILD_ARTIFACT_DIR}"
    printf '{"result_contract":3,"outcome":"pass","reason":"x"}\n' > "$a/o1.json"
    printf 'same\n' > "$a/o2.md"
    printf 'new\n' > "$a/o3.log"
}
EOF
printf '{"schema_version":1,"stage_statuses":{}}\n' > "$STATE/pipeline-state.json"
printf 'same\n' > "$ART/o2.md"
printf 'old\n' > "$ART/o3.log"

DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<EOF
set -uo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/plugin-registry/registry.sh"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/ev/events.jsonl"
export ZBUILD_STATE_DIR="$STATE" ZBUILD_ARTIFACT_DIR="$ART" ZBUILD_CYCLE_ITER=1
plugin_hook_call "$PDIR" run cs "$STATE/pipeline-state.json" >/dev/null 2>&1
EOF

TRACE="$TEST_TEMP_DIR/run.trace"; SITES="$TEST_TEMP_DIR/run.sites"
fork_census_traced "$TRACE" bash "$DRIVER" >/dev/null 2>&1
fork_census_count "$TRACE" "$SITES" >/dev/null

print_test_section "C1: the programs"
_progs="$(awk -F'\t' 'index($2, "attempt-archive.sh:") == 1 { for (i = 0; i < $1; i++) print $3 }' "$SITES" | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "[C1] awk once, cksum ×4, cp ×3, jq and mkdir once" \
    "awk cksum cksum cksum cksum cp cp cp jq mkdir" "$_progs"

print_test_section "C2: no copy of the shell"
# A `$( )` around a function copies the whole engine shell, and that copy runs
# the function's lines. A forked program traces one line at most. So a process
# other than the driver's own shell that ran more than one line of
# attempt-archive.sh is a copy of the shell.
_root="$(awk '/^\++@/ { p = $0; sub(/@ .*$/, "", p); sub(/^.*#/, "", p); print p; exit }' "$TRACE")"
_copies="$(awk -v root="$_root" '/^\++@/ { p = $0; sub(/@ .*$/, "", p); pid = p; sub(/^.*#/, "", pid)
                                           if (p ~ /attempt-archive\.sh:/) n[pid]++ }
                 END { c = 0; for (k in n) if (n[k] > 1 && k != root) c++; print c }' "$TRACE")"
assert_eq "[C2] no copy of the engine shell runs the record's code" "0" "$_copies"

print_test_section "C3: what the record says"
REC="$ART/attempts/cs/iter-1-attempt-1/attempt.json"
assert_eq "[C3] o1 changed, o2 unchanged, o3 changed" "changed unchanged changed" \
    "$(jq -r '[.outputs["o1.json"], .outputs["o2.md"], .outputs["o3.log"]] | join(" ")' "$REC" 2>/dev/null)"
assert_eq "[C3] …progress, three files" "true 3" "$(jq -r '"\(.progress) \(.files)"' "$REC" 2>/dev/null)"
if [[ "$(jq -r '.generated_at' "$REC" 2>/dev/null)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    assert_pass "[C3] generated_at is a UTC timestamp"
else
    assert_fail "[C3] generated_at is a UTC timestamp" "$(jq -c . "$REC" 2>/dev/null)"
fi
assert_eq "[C3] stage.outputs.unchanged names o2" "o2.md" \
    "$(jq -r 'select(.type=="stage.outputs.unchanged") | .data.outputs' "$TEST_TEMP_DIR/ev/events.jsonl" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
