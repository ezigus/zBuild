#!/usr/bin/env bash
# core/pipeline/verdict.sh — verdict-driven stage indicator resolver (issue #507).
#
# Resolves a stage's verdict by reading the plugin's manifest-declared
# primary output artifact. Used by runner.sh to choose the glyph + color
# of the per-stage indicator line (was: hardcoded green ✓ for every rc=0
# stage; now reflects the plugin's actual verdict).
#
# Verdict table (PINNED — see ADR-019 / ADR-020 amendment):
#   pass, approve, complete, skip, skipped,
#   healthy, deployed                             → ✓ GREEN
#   request_changes, degraded                     → ⚠ YELLOW
#   fail, error, block, scope_violation,
#   corrupt_diff                                  → ✗ RED
#   missing/malformed on declared-primary         → ⚠ YELLOW + stage.verdict.missing
#   rc != 0 (any cause)                           → ✗ RED  (rc always wins)
#
# #1708: this table is no longer hand-maintained against drift. Every plugin
# manifest with a `primary: true` output declares `config.valid_verdicts`, and
# scripts/lib/lint-verdict-classify.sh fails the build when a declared verdict
# is not classified here. The `*)` → unknown arm below stays as the RUNTIME
# backstop for undeclared/malformed values; the lint means a shipped plugin can
# no longer be the cause.
#
# Public API:
#   runner_read_stage_verdict <state_dir> <manifest_path> <stage> <rc>
#       echoes one of: pass | warn | fail | unknown
#         OR (#550 structural-failure pass-through): error | corrupt_diff | block
#       The structural-failure raw verdicts bypass classification so the
#       cycle blocked predicate can distinguish them from generic "fail".
#       side-effects: may emit stage.verdict.missing event
#
#   verdict_glyph <verdict_class>     → ✓ | ⚠ | ✗
#   verdict_color <verdict_class>     → ANSI escape (or empty if NO_COLOR)
#
# Bash 5+. Sourced library; do not add set -euo pipefail.

[[ -n "${_ZBUILD_VERDICT_LOADED:-}" ]] && return 0
_ZBUILD_VERDICT_LOADED=1

_ZBUILD_VERDICT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_VERDICT_ROOT="$(cd "$_ZBUILD_VERDICT_DIR/../.." && pwd)"

# #1824: the engine's declared contract range. NOT `|| true` — the v2 branch
# below keys off _ZBUILD_CONTRACT_V2, and a silently-missing bound would read
# every result as v1 and skip disposition validation entirely.
# shellcheck source=../contract/version.sh
source "$_ZBUILD_VERDICT_ROOT/core/contract/version.sh"

# Defensive sources so the file is usable in isolation (unit tests).
if ! declare -F eb_emit_event >/dev/null 2>&1; then
    # shellcheck source=../event-bus/event-bus.sh
    source "$_ZBUILD_VERDICT_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
fi
# #1822: the closed disposition set. NOT `|| true` — without it the reader would
# silently stop validating dispositions, which is the unenforced-declaration
# failure ADR-054 exists to end.
if ! declare -F disposition_is_valid >/dev/null 2>&1; then
    # shellcheck source=./disposition.sh
    source "$_ZBUILD_VERDICT_ROOT/core/pipeline/disposition.sh"
fi
# #1823: the fallback classification for a dispatch that left no result. NOT
# `|| true` — without it the reader would silently fall back to nothing at all
# for exactly the dispatches that need explaining.
if ! declare -F dispatch_rc_failure_disposition >/dev/null 2>&1; then
    # shellcheck source=./dispatch-rc.sh
    source "$_ZBUILD_VERDICT_ROOT/core/pipeline/dispatch-rc.sh"
fi
if [[ -z "${GREEN:-}${YELLOW:-}${RED:-}" ]]; then
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$_ZBUILD_VERDICT_ROOT/scripts/lib/helpers.sh" 2>/dev/null || true
fi

# ─── verdict_classify <raw_verdict> → pass|warn|fail|unknown ──────────────────
# Maps a raw verdict string (from a plugin's primary-output JSON) into one of
# four indicator classes per the verdict table above.
verdict_classify() {
    local raw="${1:-}"
    case "$raw" in
        pass|approve)
            echo "pass" ;;
        # complete is impact's "no gaps" terminal success verdict (declared in
        # plugins/agent/impact/manifest.yaml as a valid_verdict). skip is gates'
        # "not-applicable this run" verdict (shape-floor, lint-gate, coverage-gate,
        # mutation-gate, secret-scan) — declining to apply is not a failure. Both map
        # to pass (✓ GREEN). Without this both fall through to *) → unknown, emitting
        # spurious pipeline.indicator.unknown_verdict events on every dispatch.
        complete|skip)
            echo "pass" ;;
        # #1708: terminal SUCCESS states of the deploy/validate stages.
        #   skipped  — deploy declined to act because the gate was not pass. The
        #              stage did its job (fail-closed); it is not a failure. Note
        #              this is a DISTINCT string from the gates' `skip`.
        #   healthy  — validate's health-check passed.
        #   deployed — deploy / deploy-release completed the release.
        # These stages are not in simple.yaml's flow today, so no run has ever
        # surfaced them — the drift was already on disk waiting for the template
        # to grow. Declared in their manifests' valid_verdicts and pinned by
        # scripts/lib/lint-verdict-classify.sh.
        skipped|healthy|deployed)
            echo "pass" ;;
        # #775: `incomplete` is impact's "cycle has not converged yet" verdict
        # (analogous to review's `request_changes`) — iterating, not done.
        # Maps to warn, not fail. Without this, every impact-incomplete fired
        # a `pipeline.indicator.unknown_verdict` event 1× per iter.
        # #1208: `did_not_finish` is build's mid-flight verdict (router_timeout /
        # error). Non-terminal (iterating, not done, not a structural fail) → warn.
        # It is deliberately NOT in the structural-failure pass-through set
        # (error/corrupt_diff/block) so _cycle_detect_blocked never halts on it —
        # a timeout iterates, it does not block the cycle.
        # #1708: `degraded` is monitor's "service is up but below threshold"
        # verdict — deliberately warn, not fail. monitor normalises anything that
        # is not `pass` to `degraded` (plugins/agent/monitor/plugin.sh:143), so
        # classifying it fail would make an unparseable model response
        # indistinguishable from a genuine outage and would halt a cycle on an
        # infrastructure hiccup — the #1702 failure mode. The stage still returns
        # rc=1 on degraded, and rc always wins, so a real halt is unaffected;
        # this classification governs the INDICATOR only.
        request_changes|incomplete|degraded)
            echo "warn" ;;
        # #2034 spec-correspondence: does the assertion test what its SPEC SAYS?
        # `corresponds` is the clean answer. `partial` and `uncheckable` are
        # findings, not failures — `partial` names a coverage gap (the assertion
        # tests the right property, narrower than the sentence promises) and
        # `uncheckable` is a finding against the REQUIREMENT. Both warn.
        #
        # `mismatch` is the one genuine disagreement, and it is `fail`. That
        # split is measured, not chosen: with a three-word vocabulary the judge
        # had nowhere to put narrow-but-correct coverage and called it mismatch,
        # putting false mismatches at 6/15 on merged pairs. With `partial` split
        # out it is 0/15, with no true positive lost. The stage is advisory
        # (ADR-040 §5) so none of these gate today; the classification is what a
        # promotion would bind to.
        # #1683 spec-coverage: does the design cover what the ISSUE asked for?
        # `uncovered` is the one blocking word — a requirement with no SPEC.
        # `unreadable` warns rather than fails: intake writes a placeholder when
        # the issue fetch fails (#1804), and failing closed there would break
        # every offline run for something that is not design's fault.
        covered)
            echo "pass" ;;
        uncovered)
            echo "fail" ;;
        unreadable)
            echo "warn" ;;
        corresponds)
            echo "pass" ;;
        partial|uncheckable)
            echo "warn" ;;
        mismatch)
            echo "fail" ;;
        fail|error|block|scope_violation|corrupt_diff)
            echo "fail" ;;
        # #1219 (ADR-045): a gate-aggregator route verdict (route_design, or any
        # future route_<target>) is a NON-pass, non-convergent outcome — classify
        # it as fail so the indicator/glyph is ✗ (not an unknown_verdict warn).
        # The cycle predicates read the RAW channel, so this is purely cosmetic;
        # route_<target> stays distinct from plain `fail` in the raw verdict.
        route_*)
            echo "fail" ;;
        ""|null)
            echo "unknown" ;;
        *)
            echo "unknown" ;;
    esac
}

# ─── verdict_glyph <class> ─────────────────────────────────────────────────────
verdict_glyph() {
    case "${1:-}" in
        pass)  echo "✓" ;;
        warn)  echo "⚠" ;;
        fail)  echo "✗" ;;
        *)     echo "⚠" ;;
    esac
}

# ─── verdict_color <class> ─────────────────────────────────────────────────────
verdict_color() {
    case "${1:-}" in
        pass)  printf '%s' "${GREEN:-}" ;;
        warn)  printf '%s' "${YELLOW:-}" ;;
        fail)  printf '%s' "${RED:-}" ;;
        *)     printf '%s' "${YELLOW:-}" ;;
    esac
}

# ─── _verdict_primary_output_path <manifest> ──────────────────────────────────
# Returns the path: value of the FIRST outputs[] entry marked `primary: true`.
# Empty string if none. Mirrors the awk in contracts.sh but scoped to the
# primary-flagged row.
_verdict_primary_output_path() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 0
    awk '
        BEGIN { in_out=0; cur_path=""; cur_primary=""; emitted=0 }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]*-[[:space:]]*id:/ {
            # New entry — if previous one was primary, emit and exit.
            # #550: set emitted=1 BEFORE exit so the END block does not
            # double-print (awk runs END even after exit).
            if (cur_primary == "true" && cur_path != "") {
                print cur_path; emitted=1; exit
            }
            cur_path=""; cur_primary=""
            next
        }
        in_out && /^[[:space:]]+path:/ {
            line=$0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_path=line; next
        }
        in_out && /^[[:space:]]+primary:/ {
            line=$0
            sub(/^[[:space:]]+primary:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_primary=line; next
        }
        END {
            if (!emitted && cur_primary == "true" && cur_path != "") print cur_path
        }
    ' "$manifest" 2>/dev/null
}

# ─── _verdict_resolve_path <raw_path> <state_dir> ─────────────────────────────
# Expands the canonical templating vars (manifest_graph_canonical_vars, ADR-055
# §2) and anchors relative paths under state_dir. THE engine's single
# interpolation helper — stage-checkpoint.sh (#1879) and input-resolve.sh (#1826)
# both delegate here rather than adding a sixth copy.
#
# #1826 added ${stage_io_dir}, ${run_id} and ${cycle_feedback_dir}. The first had
# NO resolver anywhere in the tree despite being canonical since ADR-015 v1; the
# other two come from the environment, so an unset ZBUILD_* leaves the reference
# expanding to empty — the same fail-soft the three dir vars already have.
_verdict_resolve_path() {
    local raw="$1" state_dir="$2"
    local artifact_dir="${state_dir}/artifacts"
    local p="$raw"
    p="${p//\$\{state_dir\}/$state_dir}"
    p="${p//\$\{artifact_dir\}/$artifact_dir}"
    p="${p//\$\{artifacts_dir\}/$artifact_dir}"
    p="${p//\$\{stage_io_dir\}/$artifact_dir/stage-io}"
    p="${p//\$\{cycle_feedback_dir\}/${ZBUILD_CYCLE_FEEDBACK_DIR:-}}"
    # run_id is interpolated into a path: strip anything but the sanitized set
    # the runner itself guarantees, so a hostile value cannot traverse.
    local _rid="${ZBUILD_RUN_ID:-}"; _rid="${_rid//[^A-Za-z0-9._-]/_}"
    p="${p//\$\{run_id\}/$_rid}"
    if [[ "$p" != /* ]]; then
        p="$state_dir/$p"
    fi
    printf '%s' "$p"
}

# ─── _verdict_read_stage_sidecar <state_dir> <stage> ─────────────────────────
# ADR-047 §3: the canonical verdict-channel for a stage whose PRIMARY output is
# non-JSON (e.g. design.md → presence==pass) is a sidecar
# `${artifact_dir}/<stage>-verdict.json` — the stage PUSHES its normalized verdict
# there because it cannot ride the primary artifact. Generic over the runtime
# stage id (NOT any stage name): it reproduces the former design-only
# `design-verdict.json` read (#1261 router-timeout did_not_finish) for design, and
# is a no-op for non-JSON stages that write no sidecar (intake.md, pr-url.txt,
# scope-manifest.md → presence==pass). Returns the sidecar's .verdict (empty when
# absent/malformed). The producing plugin clears it at run start, so a present
# sidecar always reflects THIS run.
_verdict_read_stage_sidecar() {
    local state_dir="$1" stage="$2"
    # Defense-in-depth: the stage id is interpolated into a filesystem path.
    # Stage ids are template-controlled, but a value with '/' or '..' must never
    # traverse out of the artifacts dir — reject anything but a plain stage id
    # (mirrors the stage-shape guard in runner.sh / prompt-overrides.sh).
    [[ "$stage" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 0
    local sc; sc="$(_verdict_resolve_path "\${artifact_dir}/${stage}-verdict.json" "$state_dir")"
    [[ -s "$sc" ]] || return 0
    jq empty "$sc" >/dev/null 2>&1 || return 0
    jq -r '.verdict // empty' "$sc" 2>/dev/null || true
}

# ─── _verdict_read_result <state_dir> <manifest> <stage> <rc> <out_prefix> ───
# ADR-054 (#1821): resolve a stage's result ONCE and publish it on named vars,
# so the three public readers stop each re-resolving and re-parsing the same
# artifact (cycle_dispatch_stage calls all three per member).
#
# Publishes:
#   <prefix>_state    ok | no_manifest | no_primary | absent | malformed | nonjson
#   <prefix>_contract 1 (today's shape, the default when .result_contract is absent)
#                     | 2 (the ADR-054 result contract)
#
# NB: the version key is `result_contract`, NOT `schema_version`. `schema_version`
# is already taken and means the ARTIFACT's own schema, independently per artifact
# type — build-summary.json is at 4 (#602, pinned by build-test.sh). Reusing it
# would read every build summary as a v2 result and fail it for a missing
# `disposition`; that false positive was caught by the local-vs-CI parity golden.
#   <prefix>_verdict  raw verdict string ("" when the artifact carries none)
#   <prefix>_disp     .disposition — v2 only. PARSED AND EXPOSED, NOT BRANCHED ON;
#                     the vocabulary and the engine's response table are #1822.
#   <prefix>_reason   .reason ("" when absent)
#   <prefix>_viol     "" | contract_violation:<detail>
#   <prefix>_path     resolved primary path ("" when unresolvable)
#
# Version-scoped strictness (#1821 decision): a MALFORMED primary on a clean
# exit is a contract violation under BOTH versions — a stage that exits 0 and
# writes unparseable JSON is wrong regardless of which contract it speaks. A v2
# result MISSING a mandatory field is likewise a violation.
#
# An ABSENT artifact stays lenient (warn) for now, deliberately: the version
# lives INSIDE the file, so a file that does not exist cannot declare itself v2.
# Making absence strict needs the manifest to declare which contract the plugin
# speaks — that is #1824's negotiation, turned on per plugin by its F issue.
# Until then absence keeps today's semantics rather than guessing.
#
# The remaining leniency (no_manifest / no_primary / nonjson defaults) is removed
# wholesale by #1850, which is NOT version-gated and therefore does not disappear
# on its own as plugins migrate.
#
# Takes rc but never consults it: rc semantics belong to the callers. That is
# what lets runner_read_stage_reason surface a reason on a FAILED dispatch.
_verdict_read_result() {
    local state_dir="$1" manifest="$2" stage="$3" _rc="$4" p="$5"
    printf -v "${p}_state" '%s' "ok"
    printf -v "${p}_contract" '%s' "1"
    printf -v "${p}_verdict" '%s' ""
    printf -v "${p}_disp" '%s' ""
    printf -v "${p}_reason" '%s' ""
    printf -v "${p}_viol" '%s' ""
    printf -v "${p}_path" '%s' ""
    printf -v "${p}_present" '%s' "0"

    if [[ -z "$manifest" || ! -f "$manifest" ]]; then
        printf -v "${p}_state" '%s' "no_manifest"; return 0
    fi

    local prim_path; prim_path="$(_verdict_primary_output_path "$manifest")"
    if [[ -z "$prim_path" ]]; then
        printf -v "${p}_state" '%s' "no_primary"; return 0
    fi

    local resolved; resolved="$(_verdict_resolve_path "$prim_path" "$state_dir")"
    printf -v "${p}_path" '%s' "$resolved"

    case "$resolved" in
        *.json) ;;
        # A non-JSON primary stays `nonjson` whether or not it exists: its
        # verdict rides the sidecar channel, which the caller consults FIRST
        # (present-or-absent), exactly as before this refactor.
        *)  printf -v "${p}_state" '%s' "nonjson"
            [[ -s "$resolved" ]] && printf -v "${p}_present" '%s' "1"
            return 0 ;;
    esac

    if [[ ! -s "$resolved" ]]; then
        printf -v "${p}_state" '%s' "absent"; return 0
    fi
    if ! jq empty "$resolved" >/dev/null 2>&1; then
        printf -v "${p}_state" '%s' "malformed"
        printf -v "${p}_viol" '%s' "contract_violation:malformed_json"
        return 0
    fi

    local _sv; _sv="$(jq -r '.result_contract // 1' "$resolved" 2>/dev/null || echo 1)"
    [[ "$_sv" =~ ^[0-9]+$ ]] || _sv=1
    printf -v "${p}_contract" '%s' "$_sv"
    # NOTE: do NOT try to publish the version on a global from here. Every
    # public reader is invoked as `x="$(runner_read_stage_...)"`, and a `$()` is
    # a SUBSHELL — an assignment inside it never reaches the parent. A gate
    # reading such a global would silently always see the default and never
    # fire: green, and inert. That is exactly what #1823 shipped for one commit
    # before review caught it. The dispatch boundary uses
    # `_verdict_probe_contract` instead, whose answer comes back on stdout.
    printf -v "${p}_verdict" '%s' "$(jq -r '.verdict // empty' "$resolved" 2>/dev/null || true)"
    printf -v "${p}_reason" '%s' "$(jq -r '.reason // empty' "$resolved" 2>/dev/null || true)"

    if [[ "$_sv" -ge "$_ZBUILD_CONTRACT_V2" ]]; then
        local _decl_disp; _decl_disp="$(jq -r '.disposition // empty' "$resolved" 2>/dev/null || true)"
        printf -v "${p}_disp" '%s' "$_decl_disp"
        # Every mandatory field must be present AND non-empty. `reason` counts:
        # a result that cannot explain itself to an operator is incomplete.
        local _f _missing=""
        for _f in verdict disposition reason; do
            if ! jq -e --arg f "$_f" 'has($f) and (.[$f] | type == "string") and (.[$f] | length > 0)' \
                    "$resolved" >/dev/null 2>&1; then
                _missing="$_f"; break
            fi
        done
        if [[ -n "$_missing" ]]; then
            printf -v "${p}_viol" '%s' "contract_violation:missing_field:${_missing}"
        elif ! disposition_is_valid "$_decl_disp"; then
            # #1822: `disposition` is a CLOSED set (ADR-054 §6). A word outside
            # it is a STRUCTURAL failure — the engine never invents a default,
            # because a default is exactly how "unrecognized is never a failure"
            # grows back. The offending word rides the reason channel so an
            # operator sees what the stage actually said, and <prefix>_disp keeps
            # that same word rather than a substituted member.
            printf -v "${p}_viol" '%s' "contract_violation:unknown_disposition:${_decl_disp}"
        fi
    fi
    return 0
}

# ─── runner_read_stage_verdict <state_dir> <manifest> <stage> <rc> ───────────
# Returns the verdict class. Side-effect: emits stage.verdict.missing when a
# manifest declares a primary output but the artifact is missing/malformed.
runner_read_stage_verdict() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"

    # rc always wins.
    if [[ "$rc" -ne 0 ]]; then
        echo "fail"; return 0
    fi

    local _r_state _r_contract _r_verdict _r_disp _r_reason _r_viol _r_path _r_present
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _r

    # ADR-054 (#1821): a contract violation is a STRUCTURAL failure, not a warn.
    # It returns raw `error` — already in the #550 pass-through set, so
    # _cycle_detect_blocked halts on it with no predicate or template change —
    # and carries its detail on the .reason channel.
    if [[ -n "$_r_viol" ]]; then
        eb_emit_event "stage.verdict.contract_violation" \
            "stage=$stage" "reason=$_r_viol" "result_contract=$_r_contract" \
            "path=$_r_path" 2>/dev/null || true
        echo "error"; return 0
    fi

    case "$_r_state" in
        # No manifest at all → contract-bypass path; caller decides indicator.
        no_manifest) echo "unknown"; return 0 ;;
        # No primary declared — fall back to pass for rc=0 (rc-fallback path).
        no_primary)  echo "pass";    return 0 ;;
        # ADR-047 §3: the mechanic names no stage. A stage PUSHES its verdict to
        # the canonical channel — the primary artifact's `.verdict` when the
        # primary is JSON, else the `<stage>-verdict.json` sidecar for a non-JSON
        # primary (#1261 design did_not_finish). No per-name branches.
        nonjson)
            local _dv; _dv="$(_verdict_read_stage_sidecar "$state_dir" "$stage")"
            if [[ -n "$_dv" ]]; then verdict_classify "$_dv"; return 0; fi
            if [[ "$_r_present" != "1" ]]; then
                eb_emit_event "stage.verdict.missing" \
                    "stage=$stage" "reason=artifact_absent" "path=$_r_path" 2>/dev/null || true
                echo "warn"; return 0
            fi
            echo "pass"; return 0 ;;
        # JSON primary absent. v1 keeps the lenient warn (the sidecar is NOT a
        # channel for a JSON primary); under v2 this is a violation, raised above.
        absent)
            eb_emit_event "stage.verdict.missing" \
                "stage=$stage" "reason=artifact_absent" "path=$_r_path" 2>/dev/null || true
            echo "warn"; return 0 ;;
    esac

    # A JSON artifact with no .verdict (e.g. plan.json) is a clean pass when
    # well-formed. Under v2 an empty verdict was already caught as a violation.
    local raw_verdict="$_r_verdict"
    [[ -z "$raw_verdict" || "$raw_verdict" == "null" ]] && raw_verdict="pass"

    local cls
    cls="$(verdict_classify "$raw_verdict")"
    # #550: preserve structural-failure raw verdicts so the cycle blocked
    # predicate (_cycle_detect_blocked) can distinguish them from generic
    # "fail" (which means "test ran and failed — keep iterating").
    # error/corrupt_diff/block all mean "stage could not complete its work"
    # and the cycle must abort early. Without this pass-through, verdict_classify
    # collapses all three to "fail" and _cycle_detect_blocked never fires.
    case "$raw_verdict" in
        error|corrupt_diff|block)
            echo "$raw_verdict"; return 0 ;;
    esac
    if [[ "$cls" == "unknown" ]]; then
        eb_emit_event "pipeline.indicator.unknown_verdict" \
            "stage=$stage" "raw_verdict=$raw_verdict" "path=$_r_path" 2>/dev/null || true
        # Unknown verdict on a declared primary → warn (informational drift).
        echo "warn"; return 0
    fi
    echo "$cls"
}

# ─── runner_read_stage_reason <state_dir> <manifest> <stage> <rc> ───────────
# ADR-029 G2 (#810): when a stage produced verdict=error, return the .reason
# string from its primary output JSON. Used by the cycle orchestrator's
# G2 fast-abandon: a reason of `router_timeout` / `router_oom_kill` from
# `_router_rc_classify` is the signal that this dispatch was infra-failed
# (not a recoverable model error).
#
# Side-effects: NONE here. No events emitted; the classified verdict reader
# already covered diagnostic events for this dispatch pass.
runner_read_stage_reason() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"
    # ADR-054 (#1821): the `rc != 0 → echo ""` early return is GONE. It discarded
    # the reason for exactly the dispatches that needed explaining — a plugin
    # that returns non-zero after writing a result (plan's `return 1`) left the
    # engine holding only an integer. Read whenever a result exists; a dispatch
    # that died before writing one still yields empty, which is the honest answer
    # and is what #1823's fallback classification keys on.
    local _n_state _n_contract _n_verdict _n_disp _n_reason _n_viol _n_path _n_present
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _n
    # A contract violation explains itself on this channel too, so an operator
    # reading the reason sees why the stage was failed rather than a blank.
    if [[ -n "$_n_viol" ]]; then printf '%s' "$_n_viol"; return 0; fi
    printf '%s' "$_n_reason"
}

# ─── runner_read_stage_verdict_raw <state_dir> <manifest> <stage> <rc> ───────
# Wave 19-A (#717): returns the RAW verdict string from the plugin's primary
# output JSON (e.g. "approve", "request_changes", "block", "pass"), without
# collapsing approve→pass / request_changes→warn.
#
# Why a sibling of runner_read_stage_verdict: the original function returns
# the CLASSIFIED verdict (pass|warn|fail|unknown + structural-failure
# pass-through) which is correct for the operator-facing indicator glyph,
# but the cycle orchestrator's exit_when/abort_when/until predicates compare
# against the RAW value declared in the template (e.g. `value: approve`).
# Without the raw read, exit_when on review.verdict==approve never matches
# because the dispatch blob stores "pass" not "approve" — the dogfood
# 20260605055348-2232 symptom: review approved, but pipeline ran to
# max_iterations instead of converging via exit_when.
#
# Side-effects: NONE here (no events). Callers are expected to ALSO call
# runner_read_stage_verdict in the same dispatch pass (which is what
# cycle_dispatch_stage at runner.sh:~1115 does today: populates
# _CYCLE_DISPATCH_VERDICT via the classified call AND
# _CYCLE_DISPATCH_VERDICT_RAW via this raw call). That ordering ensures
# diagnostic events (stage.verdict.missing, pipeline.indicator.unknown_verdict)
# fire exactly once for the artifact — emitting them here too would double-
# count.
runner_read_stage_verdict_raw() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"

    # rc != 0 → no verdict semantics; mirror the classified path's "fail"
    # so cycle predicates evaluating `verdict == fail` still match.
    if [[ "$rc" -ne 0 ]]; then
        echo "fail"; return 0
    fi

    local _w_state _w_contract _w_verdict _w_disp _w_reason _w_viol _w_path _w_present
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _w

    # A contract violation surfaces as raw `error` here too, so the cycle's raw
    # channel and the classified channel agree. Side-effect-free: the classified
    # reader already emitted the event for this dispatch pass.
    if [[ -n "$_w_viol" ]]; then echo "error"; return 0; fi

    case "$_w_state" in
        no_manifest) echo "";     return 0 ;;
        # No primary declared — rc-fallback semantics: pass.
        no_primary)  echo "pass"; return 0 ;;
        # ADR-047 §3: canonical verdict channel (same as the classified reader).
        # The cycle orchestrator reads THIS raw channel for its reason-aware
        # exhaustion halt, so a non-JSON primary's sidecar verdict (design
        # did_not_finish, #1261) must surface here rather than collapsing to "pass".
        nonjson)
            local _dv; _dv="$(_verdict_read_stage_sidecar "$state_dir" "$stage")"
            if [[ -n "$_dv" ]]; then printf '%s' "$_dv"; return 0; fi
            [[ "$_w_present" == "1" ]] || { echo ""; return 0; }
            echo "pass"; return 0 ;;
        absent)      echo "";     return 0 ;;
    esac

    local raw_verdict="$_w_verdict"
    [[ -z "$raw_verdict" || "$raw_verdict" == "null" ]] && raw_verdict="pass"
    printf '%s' "$raw_verdict"
}

# ─── runner_read_stage_contract <state_dir> <manifest> <stage> <rc> ─────────
# #1823: which version of the RESULT CONTRACT this stage's result speaks — `1`
# for today's shape (and for no result at all), `2`+ for ADR-054's.
#
# The rc narrowing is gated on this. A v1 plugin has no field in which to say
# what its exit code says: `plan`'s rc=10 IS its only way to report
# `scope_too_large`, and `design`/`validate`/`monitor` all `return 2` for a
# missing state_file per ADR-001. Narrowing those to 1 today would delete the
# meaning of every unmigrated plugin in one step, so v1 keeps passing its rc
# through exactly as before and only a v2 stage — which declares a `disposition`
# and therefore has somewhere else to say it — is held to rc ∈ {0,1}.
#
# This is the same versioned coexistence #1822 used for the vocabulary: the
# closed set is consulted at `result_contract >= 2` and nowhere else. #1850
# drops the v1 reader and the gate together, at which point the narrowing is
# unconditional and the guard's enumerated inventory goes to zero.
# ─── _verdict_probe_contract <state_dir> <manifest> ─────────────────────────
# #1823: the CHEAP contract-version probe the dispatch boundary uses, and the
# answer comes back on STDOUT — never on a global. Every public reader is called
# as `x="$(runner_read_stage_...)"`, and a `$()` is a subshell whose assignments
# do not reach the parent, so a global would have made the narrowing gate read
# its default forever.
#
# One manifest scan plus one jq, versus `_verdict_read_result`'s six-ish jq
# invocations. The full read is what pushed `runner-release-exit-paths` SPEC-5
# over its 6-second external timeout on ubuntu when this ran as a fifth pass per
# dispatch; the boundary needs one number, so it pays for one number.
#
# Prints `1` for anything unreadable — no manifest, no declared primary, a
# non-JSON primary, an absent or unparseable file. "I cannot tell" must read as
# v1: v1 is the version that changes nothing.
_verdict_probe_contract() {
    local state_dir="$1" manifest="$2"
    [[ -n "$manifest" && -f "$manifest" ]] || { printf '1'; return 0; }
    local prim; prim="$(_verdict_primary_output_path "$manifest")"
    [[ -n "$prim" ]] || { printf '1'; return 0; }
    local resolved; resolved="$(_verdict_resolve_path "$prim" "$state_dir")"
    case "$resolved" in *.json) ;; *) printf '1'; return 0 ;; esac
    [[ -s "$resolved" ]] || { printf '1'; return 0; }
    local sv; sv="$(jq -r '.result_contract // 1' "$resolved" 2>/dev/null)" || sv=1
    [[ "$sv" =~ ^[0-9]+$ ]] || sv=1
    printf '%s' "$sv"
}

runner_read_stage_contract() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"
    local _c_state _c_contract _c_verdict _c_disp _c_reason _c_viol _c_path _c_present
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _c
    printf '%s' "${_c_contract:-1}"
}

# ─── runner_read_stage_fault <state_dir> <manifest> <stage> <rc> ─────────────
# The fault class a stage declared, or empty (#1987).
#
# Deliberately much thinner than runner_read_stage_disposition below: there is
# no legacy-rc translation and no fallback. `fault` is a v2-only declared field
# — a stage that did not declare one has not made a claim, and inventing one
# from an exit code is exactly the re-interpretation ADR-054 §6 exists to stop.
#
# An unrecognised word is returned as-is rather than silently dropped; the
# caller validates against the closed set and reports the disagreement.
runner_read_stage_fault() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"
    local _f_state _f_contract _f_verdict _f_disp _f_reason _f_viol _f_path _f_present
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _f
    [[ -n "$_f_path" && -s "$_f_path" ]] || return 0
    local _f_fault
    _f_fault="$(jq -r '.fault // empty' "$_f_path" 2>/dev/null || true)"
    [[ "$_f_fault" == "null" ]] && _f_fault=""
    printf '%s' "$_f_fault"
}

# ─── runner_read_stage_disposition <state_dir> <manifest> <stage> <rc> ───────
# ADR-054 §6 (#1821 exposed the field; #1822 gave it a vocabulary). Resolves the
# disposition for one dispatch. Four outcomes, in precedence order:
#
#   0. The result VIOLATED the contract — a word off the closed set, or any
#      missing mandatory field → `broken`. A stage that wrote an invalid result
#      is defective, and the two channels must not disagree: were this to return
#      the declared word, a caller reading only this channel would be told
#      "throttled, retry" about a result the engine has already rejected as
#      structurally invalid, and would retry it forever. That is precisely the
#      infinite-retry regression #1822's guard names. Nothing is lost — the
#      offending word survives verbatim on the reason channel as
#      `contract_violation:unknown_disposition:<word>`. This is not the invented
#      default the issue forbids: the engine is not guessing a plausible value in
#      order to carry on, it is concluding a defect and halting.
#   1. The stage DECLARED a valid one (v2 result) → that word, verbatim.
#   2. The dispatch DIED and left no readable result → the engine CLASSIFIES it
#      from what it observed (#1823, ADR-054 §4): a rate limit seen on either
#      router path → `throttled`; death by signal or a timeout → `interrupted`;
#      anything else → `broken`. This is the only place the engine is permitted
#      to infer, and it infers a disposition, not a verdict. Before #1823 every
#      one of these was flatly `broken`, which halted a run that had merely been
#      interrupted — the exact failure ADR-054 §6 says `interrupted`/`throttled`
#      exist to prevent. Absent any observation it is still `broken`: a stage
#      that explained nothing cannot be distinguished from a defective one, and
#      guessing "probably transient" is how a real defect retries forever.
#      Nothing is written back to the stage's artifact directory; the conclusion
#      lives on this return value and on the dispatch event.
#
#      The observation arrives as an argument rather than being re-derived here
#      because only the dispatch boundary can take it: `dispatch_rc_observation`
#      needs the raw wait status, and the boundary is where that status exists.
#      This reader does still see a raw rc — the narrowing happens at
#      `cycle_dispatch_stage`'s return, AFTER this pass — which is what lets the
#      legacy-rc branch below read the number. Passing the observation in keeps
#      the two independent: the reader never has to know whether the rc it was
#      handed has been narrowed yet.
#   3. Otherwise → empty. A v1 result declares no disposition, so the response
#      table is not consulted and today's verdict-driven control flow is
#      untouched. That is the versioned coexistence ADR-054 §5 requires, and it
#      is also what keeps ADR-021's unrelated `.disposition` vocabulary
#      (terminal|recoverable|advisory|none) inert — those artifacts are v1.
#
# Note the ordering against rc: a stage that wrote a result and THEN returned
# non-zero keeps its declared word (`plan`'s hand-rolled `return 1` is exactly
# this shape). rc never overwrites a declaration; it only fills the silence.
runner_read_stage_disposition() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"
    local observation="${5-}" rate_limited="${6:-0}"
    local _d_state _d_contract _d_verdict _d_disp _d_reason _d_viol _d_path _d_present
    _verdict_read_result "$state_dir" "$manifest" "$stage" "$rc" _d

    if [[ -n "$_d_viol" ]]; then
        printf '%s' "broken"; return 0
    fi
    # #1809 (ADR-058 C9): file-backed markers set by lifecycle.sh after dispatch.
    # Checked between _d_viol and _d_disp so a stage that declared disposition=complete
    # but violated the write boundary or the artifact contract still resolves to broken.
    # File-backed (not a shell global) because the map: arm runs a generated standalone
    # script in a separate process — a global assigned there never reaches this reader.
    if [[ -f "${state_dir}/runtime/write-boundary-violated" ]] || \
       [[ -f "${state_dir}/runtime/artifact-contract-violated" ]]; then
        printf '%s' "broken"; return 0
    fi
    if [[ -n "$_d_disp" ]]; then
        printf '%s' "$_d_disp"; return 0
    fi
    if [[ "$rc" -ne 0 ]] && ! _verdict_result_was_readable "$_d_state" "$_d_present"; then
        # A legacy rc that ADR-054 §6 has an exact word for outranks the
        # observation-based fallback. Review finding: without this a v1 stage
        # exiting 9 (llm_unavailable) or 10 (scope_too_large) with no result
        # resolved to `broken` — technically a halt either way, but it reports
        # "this is our own defect" for a service outage or an oversized scope,
        # which is what an operator reads to decide whether to act. `unavailable`
        # and `broken` differ in exactly that, not in the stopping (#1822).
        #
        # This is the mapping's whole point and it was previously computed and
        # never consulted. It is a v1-boundary read: a v2 stage declares its own
        # disposition and returned above, and #1850 deletes this with the rest.
        # Precedence: DIRECT EVIDENCE about this dispatch beats a translation of
        # a number. A 429 envelope was actually seen on the wire; a legacy rc is
        # a coexistence-era reading of an integer that will not exist after
        # #1850. It also gives the better answer where the two disagree — rc=9
        # fires after N consecutive CLI failures, and when those failures WERE
        # rate limits, `throttled` (wait, then retry) is right and `unavailable`
        # (halt for an operator) strands a run that only needed to wait.
        if [[ "$rate_limited" == "1" ]]; then
            printf '%s' "$(dispatch_rc_failure_disposition "$observation" 1)"; return 0
        fi
        # `$rc` is the RAW status here: the dispatch boundary narrows at its own
        # return, after this reader, precisely so the number is still legible.
        local _d_legacy
        _d_legacy="$(dispatch_rc_legacy_disposition "$rc" 2>/dev/null || true)"
        if [[ -n "$_d_legacy" ]]; then
            printf '%s' "$_d_legacy"; return 0
        fi
        printf '%s' "$(dispatch_rc_failure_disposition "$observation" "$rate_limited")"; return 0
    fi
    printf '%s' ""
}

# ─── _verdict_result_was_readable <state> <present> ─────────────────────────
# Did this dispatch leave a result the engine could actually read? `ok` means a
# JSON primary parsed; `nonjson` with a file on disk means the stage's declared
# primary exists on the sidecar channel. Everything else — no manifest, no
# declared primary, absent, unparseable — means the stage left the engine
# holding nothing, which is #1822's `broken`.
_verdict_result_was_readable() {
    local state="$1" present="$2"
    case "$state" in
        ok)      return 0 ;;
        nonjson) [[ "$present" == "1" ]] ;;
        *)       return 1 ;;
    esac
}
