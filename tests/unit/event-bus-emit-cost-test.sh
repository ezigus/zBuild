#!/usr/bin/env bash
# Tests: what one eb_emit_event costs, and what it writes (#1806, ADR-065 §5).
#
# Every stage pays for every event, so the external processes one emit starts
# are counted here with recording shims on PATH: a 6-field event must start the
# jsonl lock and nothing else — the shell writes a plain-ASCII line itself, and
# only a value with other bytes goes to jq (E6 pins the line against jq's). The timestamp is read
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
    ZBUILD_EVENTS_DIR="$dir" ZBUILD_EVENTS_JSONL="$dir/events.jsonl" \
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

# ─── E1: one emit ────────────────────────────────────────────────────────────
print_test_section "E1: one 6-field emit starts the lock and nothing else"
emit_in "$TEST_TEMP_DIR/e1" /dev/null linux 1 "${ARGS6[@]}"
assert_eq "[ADR-065/E1] no jq for a plain-ASCII emit (the shell writes the line)" "0" "$(count jq)"
assert_eq "[#1806/E1] no date process (the shell's clock)" "0" "$(count date)"
assert_eq "[#1806/E1] no sed process" "0" "$(count sed)"
assert_eq "[#1806/E1] no mkdir once the events dir exists" "0" "$(count mkdir)"
_others="$(grep -vx -e flock "$EXECS" 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';' || true)"
assert_eq "[ADR-065/E1] nothing else is started (only the lock)" "" "$_others"

# ─── E2: there is no SQLite copy (ADR-065 §5, 2026-10-24) ───────────────────
# events.jsonl is the only read path; the events.db mirror had no reader and
# cost a lock and a sqlite3 on every event. A caller that still names a db path
# gets the jsonl only.
print_test_section "E2: an emit writes events.jsonl only, whatever ZBUILD_EVENTS_DB says"
emit_in "$TEST_TEMP_DIR/e2" "$TEST_TEMP_DIR/e2/events.db" linux 1 "${ARGS6[@]}" "quote=it's"
assert_eq "[E2] no sqlite3" "0" "$(count sqlite3)"
assert_eq "[E2] one lock (the jsonl's)" "1" "$(count flock)"
assert_eq "[E2] no events.db is created" "absent" "$([[ -e "$TEST_TEMP_DIR/e2/events.db" ]] && echo present || echo absent)"
assert_eq "[E2] the event is in events.jsonl, its quote intact" "it's" \
    "$(jq -r 'select(.data.stage == "build") | .data.quote' "$TEST_TEMP_DIR/e2/events.jsonl" 2>/dev/null | tail -1)"

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
ZBUILD_EVENTS_DIR="$_d" ZBUILD_EVENTS_JSONL="$_d/events.jsonl" \
ZBUILD_RUN_ID="r-1806" ZBUILD_ISSUE=90000042 ZBUILD_CURRENT_STAGE=build \
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
    '{"issue":90000042,"kind":"agent","plugin":"build","run_id":"r-1806","schema_version":1,"seq":"6.1.2","stage":"build","type":"stage.complete","unit":"build.web"}' \
    "$(jq -cS 'del(.ts, .data)' <<< "$_first")"
assert_eq "[#1806/E4] data: last duplicate wins, values verbatim, ANSI stripped, every value a string" \
    '{"ansi":"red","empty":"","eq":"a=b","kind":"agent","nl":"a\nb","plugin":"build","quote":"say \"hi\"","verdict":"pass"}' \
    "$(jq -cS '.data' <<< "$_first")"
# A value (or key) that looks like a jq option is still data.
ZBUILD_EVENTS_DIR="$_d" ZBUILD_EVENTS_JSONL="$_d/opts.jsonl" \
bash -c 'source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh"; eb_emit_event stage.complete "a=-n" "b=--args" "-x=1" "_n=5" "ts=x"'
assert_eq "[#1806/E4] option-like keys and values are data" \
    '{"-x":"1","_n":"5","a":"-n","b":"--args","ts":"x"}' "$(jq -cS '.data' "$_d/opts.jsonl" 2>/dev/null)"
assert_eq "[#1806/E4] an event with no fields has data {}" "{}" "$(sed -n 2p "$_d/events.jsonl" | jq -c '.data')"

# ─── E5: a failing jq does not fail the caller ───────────────────────────────
# eb_emit_event is called bare under `set -e` across the engine: an emit that
# cannot be built is dropped, never fatal (#1153's rule; ADR-057 gate 3's hazard).
print_test_section "E5: an emit whose jq fails returns 0 and the caller carries on"
_d="$TEST_TEMP_DIR/e5"; mkdir -p "$_d" "$TEST_TEMP_DIR/badjq"
printf '#!/bin/sh\nexit 5\n' > "$TEST_TEMP_DIR/badjq/jq"; chmod +x "$TEST_TEMP_DIR/badjq/jq"
# A non-ASCII value is what still goes to jq.
cat > "$_d/driver.sh" <<DRIVER
set -euo pipefail
source "$REPO_ROOT/core/event-bus/event-bus.sh"
eb_emit_event stage.complete stage=café
echo "carried-on rc=\$?"
DRIVER
_e5="$(ZBUILD_EVENTS_DIR="$_d" ZBUILD_EVENTS_JSONL="$_d/events.jsonl" \
    PATH="$TEST_TEMP_DIR/badjq:$PATH" bash "$_d/driver.sh" 2>/dev/null || true)"
assert_eq "[#1806/E5] the caller under set -e carries on after a failed emit" "carried-on rc=0" "$_e5"
assert_eq "[#1806/E5] nothing half-built is appended" "0" "$(if [[ -f "$_d/events.jsonl" ]]; then grep -c . "$_d/events.jsonl" || true; else echo 0; fi)"

# ─── E6: the line the shell writes is the line jq wrote ─────────────────────
# Byte for byte, for the values that need escaping: quotes, backslashes, every
# control character jq spells out, a duplicate key, option-like words, and the
# optional envelope fields. A value with bytes above ASCII goes to jq itself,
# and must come out the same.
print_test_section "E6: the shell-built line is byte-identical to jq's"
_d="$TEST_TEMP_DIR/e6"; mkdir -p "$_d"
_ref() {   # the envelope program eb_emit_event used before (#1806), on the same input
    local ts="$1" type="$2"; shift 2
    local -a pairs=(); local -i n=0; local a
    for a in "$@"; do pairs+=(--arg "_k$n" "${a%%=*}" --arg "_v$n" "${a#*=}"); n+=1; done
    jq -cn --arg ts "$ts" --arg run_id 'r"6' --argjson issue 90000007 --arg type "$type" \
        --arg plugin "p" --arg kind "k" --arg stage "build" --arg seq "6.1" --arg unit "" \
        --argjson _n "$n" "${pairs[@]}" \
        '$ARGS.named as $a
         | ([range(0; $_n) | {($a["_k\(.)"]): $a["_v\(.)"]}] | add // {}) as $data
         | ({ts: $ts, run_id: $run_id, issue: $issue, type: $type, plugin: $plugin, kind: $kind, data: $data, schema_version: 1}
            + (if $stage != "" then {stage: $stage} else {} end)
            + (if $seq != "" then {seq: $seq} else {} end)
            + (if $unit != "" then {unit: $unit} else {} end))'
}
_E6_ARGS=('q=say "hi"' 'bs=a\b\\c' $'nl=a\nb\tc\rd' $'ctl=\x01\x02\x08\x0c\x1f\x7f' \
    "dup=1" "x=-n" "dup=2" "noeq" "empty=" "slash=a/b" "plugin=p" "kind=k")
for _case in ascii utf8; do
    _a=("${_E6_ARGS[@]}"); [[ "$_case" == utf8 ]] && _a+=("u=café ✓" $'bad=a\xffb')
    rm -f "$_d/events.jsonl"
    ZBUILD_EVENTS_DIR="$_d" ZBUILD_EVENTS_JSONL="$_d/events.jsonl" \
    ZBUILD_RUN_ID='r"6' ZBUILD_ISSUE=90000007 ZBUILD_PLUGIN=p ZBUILD_PLUGIN_KIND=k \
    ZBUILD_CURRENT_STAGE=build ZBUILD_STAGE_IO_SEQ_LABEL=6.1 \
    bash -c 'source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh"; eb_emit_event "$@"' _ stage.complete "${_a[@]}"
    _got="$(cat "$_d/events.jsonl")"
    _ts="$(jq -r .ts <<< "$_got" 2>/dev/null)"
    assert_eq "[ADR-065/E6] $_case: the line is jq's, byte for byte" "$(_ref "$_ts" stage.complete "${_a[@]}")" "$_got"
done
rm -f "$_d/events.jsonl"
# The leading zeros are the case under test; the lint reads them as octal.
_ISSUE_0PAD=0090000007  # lint-test-identity:allow
ZBUILD_EVENTS_DIR="$_d" ZBUILD_EVENTS_JSONL="$_d/events.jsonl" ZBUILD_ISSUE="$_ISSUE_0PAD" \
bash -c 'source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh"; eb_emit_event pipeline.start'
# Read as text: jq itself would accept the invalid number 0090000007.
_line="$(cat "$_d/events.jsonl" 2>/dev/null)"
assert_eq "[ADR-065/E6] an issue written 0090000007 is the number 90000007, and no fields is data {}" '"issue":90000007,|"data":{},' \
    "$( [[ "$_line" == *'"issue":90000007,'* ]] && printf '"issue":90000007,'; printf '|'; [[ "$_line" == *'"data":{},'* ]] && printf '"data":{},')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
