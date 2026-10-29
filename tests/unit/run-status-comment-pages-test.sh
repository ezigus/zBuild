#!/usr/bin/env bash
# Tests: the run-status comment shows what each stage reported in full, and a
# run that outgrows one comment continues in the next (ADR-064 §4, §6, amended
# 2026-10-28).
#
# Why: on #1944 (2026-10-28) every stage line was cut at 200 characters
# ("…so a regression where persist skips on timeout would not be caug…"), the
# rest of a stage's summary was never shown, and a run that outgrew 60,000
# bytes dropped its oldest rows. What a stage reported is the record of the
# run; none of it may be lost from the issue.
#
# P1 [change] a stage's whole first summary line is on its row, never cut
# P2 [change] the rest of its summary is under the row, folded (<details>)
# P3 [change] a closed row's frozen summary keeps its newlines and tabs, and a
#             fresh process serves it unchanged
# P4 [change] a run larger than one comment is split into parts, each under
#             the limit; every row is in exactly one part; nothing is omitted
# P5 [change] the newest part carries the run's header (status, open items,
#             current stage) and the first part's marker is unchanged; every
#             earlier part says it holds earlier stages
# P6 [change] a new row changes only the newest part: earlier parts are full,
#             and their text does not change
# P7 [change] each part is its own comment: the first flush POSTs one per
#             part in order, ids kept per part; a later flush PATCHes only a
#             part whose text changed; the finalizer edits the newest part
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-status comment — whole summaries, parts not omissions (ADR-064)"
setup_test_env "rsc-pages"

LIB="$REPO_ROOT/scripts/lib/run-status-comment.sh"
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$LIB"
export ZBUILD_STATUS_NOW=2026-09-17T12:30:00Z

# ev <events> <ts-time> <type> <seq> <stage> [k=v ...] — the event bus's envelope.
ev() {
    local f="$1" t="$2" type="$3" seq="$4" stage="$5"; shift 5
    local data="{}" kv
    for kv in "$@"; do data="$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<< "$data")"; done
    jq -cn --arg ts "2026-09-17T${t}.000Z" --arg type "$type" --arg seq "$seq" --arg stage "$stage" --argjson data "$data" \
        '{ts:$ts, run_id:"r-pg", issue:90000042, type:$type, plugin:"", kind:"", data:$data, schema_version:1}
         + (if $stage != "" then {stage:$stage} else {} end) + (if $seq != "" then {seq:$seq} else {} end)' >> "$f"
}
# stage_row <events> <n> — stage s<n> starts and passes.
stage_row() {
    ev "$1" 10:00:01 plugin.run.start "$2" "s$2" plugin="s$2" kind=tool
    ev "$1" 10:00:02 stage.complete "$2" "s$2" stage="s$2" verdict=pass
}

# ─── P1/P2: the whole first line, the rest folded ───────────────────────────
print_test_section "P1/P2: what a stage reported, in full"
S="$TEST_TEMP_DIR/one"; E="$S/events.jsonl"; mkdir -p "$S/artifacts"; : > "$E"
long600="R-4 is structurally unmet — $(printf 'word %.0s' $(seq 1 120))END-OF-LINE"
printf '## s1 — fail\n\n- %s\n- NOT MET: R-10: lint fails\n- NOT SURE: R-9: §9 or §11\n' "$long600" > "$S/artifacts/s1-summary.md"
ev "$E" 10:00:00 pipeline.start "" "" run_id=r-pg issue=90000042 engine_sha=0000000 engine_branch=main
stage_row "$E" 1
body="$(rsc_render_body "$E" "$S")"
row="$(grep -F -- '**1 s1**' <<< "$body")"
assert_contains "[P1] the whole first line is on the row" "$row" "END-OF-LINE"
assert_eq "[P1] ...not cut" "0" "$(grep -c -F 'END-OF-LINE…' <<< "$row" || true)"
assert_contains "[P2] the rest of the summary is folded under the row" "$body" "<details>"
assert_contains "[P2] ...with each of its lines" "$body" "NOT MET: R-10: lint fails"
assert_contains "[P2] ...all of them" "$body" "NOT SURE: R-9: §9 or §11"

# ─── P3: a frozen summary keeps its shape ───────────────────────────────────
print_test_section "P3: the frozen summary is served whole"
printf '## s1 — fail\n\n- overwritten by a later iteration\n' > "$S/artifacts/s1-summary.md"
fresh="$(bash -c 'source "$1"; rsc_render_body "$2" "$3"' _ "$LIB" "$E" "$S" 2>/dev/null)"
assert_contains "[P3] a fresh process serves the frozen first line" "$fresh" "END-OF-LINE"
assert_contains "[P3] ...and the frozen rest, line by line" "$fresh" "- NOT SURE: R-9: §9 or §11"
assert_eq "[P3] ...not the overwritten summary" "0" "$(grep -c -F 'overwritten by a later iteration' <<< "$fresh" || true)"

# ─── P4/P5: parts, not omissions ────────────────────────────────────────────
print_test_section "P4/P5: a run larger than one comment"
B="$TEST_TEMP_DIR/big"; BE="$B/events.jsonl"; mkdir -p "$B/artifacts"; : > "$BE"
long300="$(printf 'y%.0s' $(seq 1 300))"
ev "$BE" 10:00:00 pipeline.start "" "" run_id=r-pg issue=90000042 engine_sha=0000000 engine_branch=main
for i in $(seq 1 400); do
    printf '## s%s — pass\n\n- %s\n' "$i" "$long300" > "$B/artifacts/s${i}-summary.md"
    stage_row "$BE" "$i"
done
OUT="$TEST_TEMP_DIR/parts"; mkdir -p "$OUT"
n="$(rsc_render_pages "$BE" "$B" "$OUT")"
if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 2 ]]; then assert_pass "[P4] the run is split into parts ($n)"
else assert_fail "[P4] the run is split into parts" "got '$n'"; fi
_over=""; _all=""
for k in $(seq 1 "${n:-0}"); do
    b="$(LC_ALL=C wc -c < "$OUT/part-$k.md" | tr -d ' ')"
    (( b < 60000 )) || _over+=" part-$k=$b"
    _all+="$(cat "$OUT/part-$k.md")"$'\n'
done
assert_eq "[P4] every part is under 60,000 bytes" "" "$_over"
assert_eq "[P4] every row is in exactly one part" "400" "$(grep -c -E '· \*\*[0-9]+ s[0-9]+\*\*' <<< "$_all")"
assert_eq "[P4] ...each once" "" "$(grep -oE '\*\*[0-9]+ s[0-9]+\*\*' <<< "$_all" | sort | uniq -d | head -1)"
assert_eq "[P4] nothing is omitted" "0" "$(grep -c 'omitted' <<< "$_all" || true)"
assert_contains "[P5] the newest part has the run's header" "$(cat "$OUT/part-$n.md")" '· **running**'
assert_contains "[P5] ...and the newest row" "$(cat "$OUT/part-$n.md")" '**400 s400**'
assert_contains "[P5] the oldest row is in the first part" "$(cat "$OUT/part-1.md")" '**1 s1**'
assert_eq "[P5] the first part keeps the run's marker" '<!-- zbuild-run-status run_id=r-pg -->' "$(sed -n 1p "$OUT/part-1.md")"
assert_eq "[P5] a later part's marker names its part" "<!-- zbuild-run-status run_id=r-pg part=$n -->" "$(sed -n 1p "$OUT/part-$n.md")"
assert_eq "[P5] an earlier part carries no status" "0" "$(grep -c -F '**running**' "$OUT/part-1.md" || true)"
assert_contains "[P5] ...and says it holds earlier stages" "$(sed -n 2p "$OUT/part-1.md")" "earlier stages"
assert_contains "[P5] rsc_render_body is the newest part" "$(rsc_render_body "$BE" "$B")" '**400 s400**'

# ─── P6: a new row changes only the newest part ─────────────────────────────
print_test_section "P6: earlier parts do not change"
cp "$OUT/part-1.md" "$TEST_TEMP_DIR/part-1.before"
printf '## s401 — pass\n\n- new\n' > "$B/artifacts/s401-summary.md"
stage_row "$BE" 401
OUT2="$TEST_TEMP_DIR/parts2"; mkdir -p "$OUT2"
n2="$(rsc_render_pages "$BE" "$B" "$OUT2")"
assert_eq "[P6] the first part is unchanged by a new row" "$(cat "$TEST_TEMP_DIR/part-1.before")" "$(cat "$OUT2/part-1.md")"
assert_contains "[P6] the new row is in the newest part" "$(cat "$OUT2/part-$n2.md")" '**401 s401**'

# ─── P7: one comment per part ───────────────────────────────────────────────
print_test_section "P7: each part is its own comment"
GH_LOG="$TEST_TEMP_DIR/gh.log"; : > "$GH_LOG"; GH_ID="$TEST_TEMP_DIR/gh.id"; printf '500' > "$GH_ID"
GH_LIST="$TEST_TEMP_DIR/gh.list"; printf '[]' > "$GH_LIST"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$*" in
  *--paginate*) cat "$GH_LIST"; exit 0 ;;
  *"-X PATCH"*) echo '{}'; exit 0 ;;
  *issues/*/comments*) i="\$(( \$(cat "$GH_ID") + 1 ))"; printf '%s' "\$i" > "$GH_ID"; echo "\$i"; exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5
F="$TEST_TEMP_DIR/flush"; cp -R "$B" "$F"; rm -f "$F"/status-comment*.json
rsc_flush "$F/events.jsonl" "$F" testuser/testrepo 90000042 r-pg
_posts="$(grep -c -E '^api repos/testuser/testrepo/issues/90000042/comments -F' "$GH_LOG" || true)"
assert_eq "[P7] one POST per part" "$n2" "$_posts"
assert_eq "[P7] the first part's id is kept where it always was" "501" "$(rsc_id_load "$F")"
assert_eq "[P7] the newest part's id is kept too" "50$n2" "$(rsc_id_load "$F" "$n2")"
: > "$GH_LOG"
printf '## s402 — pass\n\n- newer\n' > "$F/artifacts/s402-summary.md"
stage_row "$F/events.jsonl" 402
rsc_flush "$F/events.jsonl" "$F" testuser/testrepo 90000042 r-pg
assert_eq "[P7] a later flush POSTs nothing" "0" "$(grep -c -E 'issues/90000042/comments -F' "$GH_LOG" || true)"
assert_eq "[P7] ...and PATCHes only the newest part" "api repos/testuser/testrepo/issues/comments/50$n2" \
    "$(grep -F -- '-X PATCH' "$GH_LOG" | awk '{print $1, $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
jq -n --arg a "$(cat "$OUT2/part-1.md")" --arg b "$(cat "$OUT2/part-$n2.md")" \
    '[{id: 501, body: $a}, {id: 777, body: $b}]' > "$GH_LIST"
: > "$GH_LOG"
rsc_finalize_issue "$TEST_TEMP_DIR/fin" testuser/testrepo 90000042 failure
assert_contains "[P7] the finalizer edits the newest part" "$(grep -F -- '-X PATCH' "$GH_LOG")" "issues/comments/777"

print_test_results
exit $((FAIL > 0))
