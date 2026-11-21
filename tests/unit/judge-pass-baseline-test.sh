#!/usr/bin/env bash
# tests/unit/judge-pass-baseline-test.sh — a kept pass is refused only on a
# line the change added or removed since the verdict the judge actually gave,
# read whole from the diff since that verdict (#2574 held-pass review;
# ADR-072 §4, amended 2026-11-20).
#
# B1 [change] (H1) a held pass keeps the baseline of the verdict that passed it:
#             round 2 adds break_it and the judge quotes an unchanged line —
#             held; round 3 quotes break_it — taken
# B2 [change] (H2) a removed line, a shortened line and a removed call are
#             changes: each quote is taken, matched whole against the diff's
#             - and + lines; an unchanged line, or a fragment across two lines,
#             is not
# B3 [change] (M1) a dependency outside the repository does not stop the
#             repository's files being stored
# B4 [change] (M2) a file the verdict did not depend on is compared with the
#             repository as it was at the verdict: a line the branch added
#             before it is no change; one removed after it is
# B5 [change] (M3) a verdict whose stored content is gone is judged afresh:
#             the refusal is taken, and judge.held.no_baseline says why
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a kept pass is refused only on a line changed since its verdict (#2574)"
setup_test_env "judge-pass-baseline"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../scripts/lib/judge.sh
source "$REPO_ROOT/scripts/lib/judge.sh"

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R"
( cd "$R" && git init -q -b main && printf 'a1\n' > a.sh && printf 'b1\n' > b.sh && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm base && git checkout -qb work ) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$R"
KF="$TEST_TEMP_DIR/art/x-judged.json"; mkdir -p "${KF%/*}"
# _keep <fp> [carry] — keep REQ-1's pass, depending on a.sh, as a check keeps it
# (judge_keep_baseline_v, then judge_kept_put_all); carry: a held pass.
_keep() {
    local -A p=([REQ-1]="REQ-1: met") f=([REQ-1]="$1") d=([REQ-1]="$R/a.sh"$'\n') c=()
    [[ -n "${2:-}" ]] && c[REQ-1]=1
    judge_keep_baseline_v _JUDGE_KEEP_BASE "$R"
    judge_kept_put_all "$KF" p f d c
}
# _read <fp> — the record, as a check reads it before it judges.
_read() { local -A o=() f=([REQ-1]="$1"); judge_kept_get_all_v o "$KF" f; }
_flip() { judge_pass_flip_ok "$KF" REQ-1 "$R" "$1"; }
_v() { if _flip "$1"; then echo taken; else echo held; fi; }

print_test_section "B1: a held pass keeps the baseline that passed it"
printf 'a1\nkeep_me\n' > "$R/a.sh"
_keep fp1; _read fp2
printf 'a1\nkeep_me\nbreak_it\n' > "$R/a.sh"
assert_eq "[B1] round 2: a quote of an unchanged line is held" "held" "$(_v 'a.sh | keep_me')"
_keep fp2 carry; _read fp3
assert_eq "[B1] round 3: break_it, added since the verdict that passed it, is taken" "taken" "$(_v 'a.sh | break_it')"

print_test_section "B2: removed, shortened and no-longer-made lines"
printf 'load_cfg "$f" || exit 1\nrun_check\nkeep_me\nx=10\n' > "$R/a.sh"
_keep fp4; _read fp5
printf 'load_cfg "$f"\nkeep_me\nx=10\n' > "$R/a.sh"
assert_eq "[B2] the shortened line, as it is now, is taken" "taken" "$(_v 'a.sh | load_cfg "$f"')"
assert_eq "[B2] ...and as it was, is taken" "taken" "$(_v 'a.sh | load_cfg "$f" || exit 1')"
assert_eq "[B2] a call no longer made is taken" "taken" "$(_v 'a.sh | run_check')"
assert_eq "[B2] an unchanged line is held" "held" "$(_v 'a.sh | keep_me')"
assert_eq "[B2] a fragment across two lines is held" "held" "$(_v 'a.sh | me x')"

print_test_section "B3: a dependency outside the repository"
OUT="$TEST_TEMP_DIR/issue.md"; printf 'issue\n' > "$OUT"
printf 'a1\nb3_line\n' > "$R/a.sh"
( declare -A p=([REQ-2]="REQ-2: met") f=([REQ-2]=fpb3) d=([REQ-2]="$R/a.sh"$'\n'"$OUT"$'\n') c=()
  judge_kept_put_all "$KF" p f d c )
_h="$(jq -r --arg k "$R/a.sh" '.["REQ-2"].files[$k]' "$KF")"
assert_eq "[B3] the repository's file is stored, though one dependency is outside" "0" "$(git -C "$R" cat-file -e "$_h" 2>/dev/null; echo $?)"

print_test_section "B4: a file the verdict did not depend on"
printf 'a1\n' > "$R/a.sh"; printf 'b1\ncall_guard\n' > "$R/b.sh"
_keep fp6; _read fp7
assert_eq "[B4] a line the branch added before the verdict is no change" "held" "$(_v 'b.sh | call_guard')"
printf 'b1\n' > "$R/b.sh"
assert_eq "[B4] ...the same line removed after it is" "taken" "$(_v 'b.sh | call_guard')"

print_test_section "B5: a verdict whose stored content is gone"
printf 'a1\nkeep_me\n' > "$R/a.sh"
_keep fp8; _read fp9
_JUDGE_KEPT_FILES[REQ-1]="$R/a.sh"$'\t'"0000000000000000000000000000000000000001"
_JUDGE_KEPT_BASE[REQ-1]=""
: > "$ZBUILD_EVENTS_JSONL"
assert_eq "[B5] judged afresh: the refusal is taken" "taken" "$(_v 'a.sh | keep_me')"
assert_contains "[B5] ...judge.held.no_baseline says why" "$(cat "$ZBUILD_EVENTS_JSONL")" "judge.held.no_baseline"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
