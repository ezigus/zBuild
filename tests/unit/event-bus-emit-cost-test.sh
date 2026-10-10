#!/usr/bin/env bash
# Tests: what one eb_emit_event costs, and what it writes (#1806, ADR-065 §5).
#
# Every stage pays for every event, so the external processes one emit starts
# are counted here with recording shims on PATH: a 6-field event must start one
# jq (the envelope) and the jsonl lock, and nothing else. The timestamp is read
# from the shell's own clock, so it has milliseconds on every host and does not
# depend on ZBUILD_PLATFORM, which a map work unit sets to its TARGET platform
# (ADR-009 §6). The envelope a reader sees is pinned field by field.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "event bus — the cost and shape of one emit (#1806)"
setup_test_env "eb-emit-cost"

# ─── recording shims: each logs its name, then runs the real binary ─────────
SHIMS="$TEST_TEMP_DIR/shims"; mkdir -p "$SHIMS"
EXECS="$TEST_TEMP_DIR/execs.log"
for _cmd in jq date sed mkdir sqlite3 flock cat tr awk head; do
    _real="$(command -v "$_cmd" 2>/dev/null || true)"
    [[ -n "$_real" ]] || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$_cmd" "$EXECS" "$_real" > "$SHIMS/$_cmd"
    chmod +x "$SHIMS/$_cmd"
done

# emit_in <events_dir> <db> <platform> <n> <type> [k=v...]: a fresh shell sources
# the bus, warms it up with one emit (first-call setup is not the per-event
# cost), clears the log, then emits <n> times.
emit_in() {
    local dir="$1" db="$2" platform="$3" n="$4"; shift 4
    mkdir -p "$dir"
    ZBUILD_EVENTS_DIR="$dir" ZBUILD_EVENTS_JSONL="$dir/events.jsonl" ZBUILD_EVENTS_DB="$db" \
    ZBUILD_PLATFORM="$platform" PATH="$SHIMS:$PATH" EXECS="$EXECS" N="$n" \
    bash -c '
        source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh"
        eb_emit_event "stage.complete" "stage=warmup"
        : > "$EXECS"
        for (( i = 0; i < N; i++ )); do eb_emit_event "$@"; done
    ' _ "$@"
}
count() { grep -cx "$1" "$EXECS" 2>/dev/null || true; }

ARGS6=(stage.complete stage=build verdict=pass score=91 reason=ok note=fine extra=x)

# ─── E1: one emit, mirror off ────────────────────────────────────────────────
print_test_section "E1: one 6-field emit starts one jq and nothing per field"
emit_in "$TEST_TEMP_DIR/e1" /dev/null linux 1 "${ARGS6[@]}"
assert_eq "[#1806/E1] one jq per emit (the envelope), not one per field" "1" "$(count jq)"
assert_eq "[#1806/E1] no date process (the shell's clock)" "0" "$(count date)"
assert_eq "[#1806/E1] no sed process" "0" "$(count sed)"
assert_eq "[#1806/E1] no mkdir once the events dir exists" "0" "$(count mkdir)"
_others="$(grep -vx -e jq -e flock "$EXECS" 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';' || true)"
assert_eq "[#1806/E1] nothing else is started (only jq and the lock)" "" "$_others"

# ─── E2: one emit, SQLite mirror on ─────────────────────────────────────────
if command -v sqlite3 >/dev/null 2>&1; then
    print_test_section "E2: the mirror escapes its fields without a process each"
    emit_in "$TEST_TEMP_DIR/e2" "$TEST_TEMP_DIR/e2/events.db" linux 1 "${ARGS6[@]}" "quote=it's"
    assert_eq "[#1806/E2] no sed per mirrored field" "0" "$(count sed)"
    assert_eq "[#1806/E2] one sqlite3 insert" "1" "$(count sqlite3)"
    assert_eq "[#1806/E2] the row's payload keeps the quote" "it's" \
        "$(sqlite3 "$TEST_TEMP_DIR/e2/events.db" "SELECT json_extract(payload,'\$.quote') FROM events ORDER BY id DESC LIMIT 1;" 2>/dev/null)"
else
    assert_pass "[#1806/E2] skipped: no sqlite3 on this host"
fi

# ─── E3: timestamps ──────────────────────────────────────────────────────────
# Both platform values on the same host: a map unit exports its target
# platform, and the clock must not care. Five events, so a run of `.000` would
# mean the milliseconds are not real (chance of five real zeros: 1e-15).
print_test_section "E3: every timestamp is UTC with real milliseconds, whatever ZBUILD_PLATFORM says"
for _plat in linux macos; do
    _d="$TEST_TEMP_DIR/e3-$_plat"
    _before="$(date -u +%s)"
    emit_in "$_d" /dev/null "$_plat" 5 stage.complete stage=t
    _after="$(date -u +%s)"
    _bad="$(jq -r 'select(.data.stage=="t") | .ts | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$") | not)' "$_d/events.jsonl")"
    assert_eq "[#1806/E3] ZBUILD_PLATFORM=$_plat: every ts is YYYY-MM-DDTHH:MM:SS.mmmZ" "" "$_bad"
    _ms="$(jq -r 'select(.data.stage=="t") | .ts[20:23]' "$_d/events.jsonl" | sort -u | tr '\n' ' ')"
    if [[ "$_ms" != "000 " ]]; then
        assert_pass "[#1806/E3] ZBUILD_PLATFORM=$_plat: milliseconds are real ($_ms)"
    else
        assert_fail "[#1806/E3] ZBUILD_PLATFORM=$_plat: milliseconds are real" "all five ended .000Z"
    fi
    _secs="$(jq -r 'select(.data.stage=="t") | .ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' "$_d/events.jsonl" | tail -1)"
    if [[ "$_secs" -ge "$_before" && "$_secs" -le "$_after" ]]; then
        assert_pass "[#1806/E3] ZBUILD_PLATFORM=$_plat: the ts is now, in UTC"
    else
        assert_fail "[#1806/E3] ZBUILD_PLATFORM=$_plat: the ts is now, in UTC" "ts=$_secs not in [$_before,$_after]"
    fi
done

# ─── E4: the envelope is unchanged ───────────────────────────────────────────
print_test_section "E4: the envelope a reader sees is unchanged"
_d="$TEST_TEMP_DIR/e4"; mkdir -p "$_d"
ZBUILD_EVENTS_DIR="$_d" ZBUILD_EVENTS_JSONL="$_d/events.jsonl" ZBUILD_EVENTS_DB=/dev/null \
ZBUILD_RUN_ID="r-1806" ZBUILD_ISSUE=1806 ZBUILD_CURRENT_STAGE=build \
ZBUILD_STAGE_IO_SEQ_LABEL=6.1.2 ZBUILD_UNIT=build.web \
bash -c '
    source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh"
    eb_emit_event "stage.complete" "verdict=fail" "verdict=pass" "quote=say \"hi\"" \
        "nl=a
b" $'"'"'ansi=\e[31mred\e[0m'"'"' "eq=a=b" "empty=" "plugin=build" "kind=agent"
    eb_emit_event "pipeline.start"
'
_first="$(sed -n 1p "$_d/events.jsonl")"
assert_eq "[#1806/E4] envelope keys, in order, and their types" \
    'ts:string,run_id:string,issue:number,type:string,plugin:string,kind:string,data:object,schema_version:number,stage:string,seq:string,unit:string' \
    "$(jq -r '[to_entries[] | "\(.key):\(.value|type)"] | join(",")' <<< "$_first")"
assert_eq "[#1806/E4] envelope values" \
    '{"issue":1806,"kind":"agent","plugin":"build","run_id":"r-1806","schema_version":1,"seq":"6.1.2","stage":"build","type":"stage.complete","unit":"build.web"}' \
    "$(jq -cS 'del(.ts, .data)' <<< "$_first")"
assert_eq "[#1806/E4] data: last duplicate wins, values verbatim, ANSI stripped, every value a string" \
    '{"ansi":"red","empty":"","eq":"a=b","kind":"agent","nl":"a\nb","plugin":"build","quote":"say \"hi\"","verdict":"pass"}' \
    "$(jq -cS '.data' <<< "$_first")"
# A value (or key) that looks like a jq option is still data.
ZBUILD_EVENTS_DIR="$_d" ZBUILD_EVENTS_JSONL="$_d/opts.jsonl" ZBUILD_EVENTS_DB=/dev/null \
bash -c 'source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh"; eb_emit_event stage.complete "a=-n" "b=--args" "-x=1" "_n=5" "ts=x"'
assert_eq "[#1806/E4] option-like keys and values are data" \
    '{"-x":"1","_n":"5","a":"-n","b":"--args","ts":"x"}' "$(jq -cS '.data' "$_d/opts.jsonl" 2>/dev/null)"
assert_eq "[#1806/E4] an event with no fields has data {}" "{}" "$(sed -n 2p "$_d/events.jsonl" | jq -c '.data')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
