#!/usr/bin/env bash
# tests/live/lens-reads-around-change.sh — LIVE check (#1654): does a real
# review lens catch a defect that is only visible in UNCHANGED code?
#
# Not part of `npm test`: it calls the real model (cost, and the answer varies
# run to run). Run by .github/workflows/lens-live-check.yml (manual + weekly),
# or by hand with a logged-in `claude` CLI:
#     bash tests/live/lens-reads-around-change.sh [attempts] [needed]
#
# The planted defect is #1654's own evidence (run 20260730215925-59799): a new
# helper runs bare `git` — resolving whatever $PWD is — while every unchanged
# neighbour in the same file takes the checkout and anchors its calls with
# `git -C "$root"`, as the file header says. The new helper takes no root and
# the diff's context lines show only a non-git logger, so the diff alone looks
# fine; only reading the rest of the file shows the defect. (A first fixture
# left `local root` unused and a neighbour in the diff context — the pre-#2215
# lens caught that 3/3 from the diff alone, so it proved nothing.)
#
# PASS when at least <needed> of <attempts> correctness-lens runs (default 2
# of 3) name an unchanged neighbour, the file's stated convention/invariant, or
# the other helpers ("every/unlike the other …", "the other three helpers …").
#
# What this does and does not prove: it is a REGRESSION GUARD — lenses keep
# reading around a change. Measured 2026-09-28, the pre-#2215 prompt ("report
# only issues you can point to in the change below") ALSO caught it 3/3, citing
# "the file's documented invariant (lines 3-5)": the model reads the file
# regardless, so this check cannot attribute the reading to #2215's prompt.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ATTEMPTS="${1:-3}"; NEEDED="${2:-2}"

command -v claude >/dev/null 2>&1 || { echo "lens-live-check: SKIP — no claude CLI on PATH" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lens-live.XXXXXX")"
# LENS_LIVE_KEEP=1 keeps the work folder (each attempt's log and lens result).
if [[ "${LENS_LIVE_KEEP:-0}" == "1" ]]; then echo "lens-live-check: work folder $WORK" >&2
else trap 'rm -rf "$WORK"' EXIT; fi

# ── the target repository ────────────────────────────────────────────────────
TGT="$WORK/target"; mkdir -p "$TGT/scripts"
git -C "$TGT" init -q
git -C "$TGT" config user.name live; git -C "$TGT" config user.email live@example.invalid
cat > "$TGT/scripts/sync.sh" <<'EOF'
#!/usr/bin/env bash
# scripts/sync.sh — keep a checkout in step with its remote.
# Callers run from ANY directory: every helper takes the checkout as $1 and
# names it on every git call (`git -C "$root"`). A bare `git` would act on
# whatever $PWD happens to be.

_sync_fetch() {
    local root="$1"
    git -C "$root" fetch -q origin
}

_sync_current_branch() {
    local root="$1"
    git -C "$root" rev-parse --abbrev-ref HEAD
}

_sync_is_clean() {
    local root="$1"
    [[ -z "$(git -C "$root" status --porcelain)" ]]
}

# Log a line to stderr with a timestamp.
_sync_log() {
    local msg="$*"
    local ts
    ts="$(date -u +%H:%M:%S)"
    printf '%s %s\n' "$ts" "$msg" >&2
}
EOF
git -C "$TGT" add -A; git -C "$TGT" commit -q -m "sync helpers"
# The change: looks complete in isolation. It is wrong only against the file's
# convention — every helper takes the checkout and names it on each git call.
cat >> "$TGT/scripts/sync.sh" <<'EOF'

# The remote's default branch (e.g. main).
_sync_default_branch() {
    local ref
    ref="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || return 1
    printf '%s\n' "${ref#origin/}"
}
EOF
git -C "$TGT" add -A; git -C "$TGT" commit -q -m "add _sync_default_branch"

# ── the job folder the engine would hand the lens ────────────────────────────
SD="$WORK/state"; ART="$SD/artifacts"; mkdir -p "$ART" "$SD/stage-inputs"
git -C "$TGT" diff HEAD~1 HEAD > "$ART/diff.patch"
printf 'Add a helper to scripts/sync.sh that returns the remote default branch.\n' > "$SD/intake.md"
printf '+ scripts/sync.sh\n' > "$SD/scope-manifest.md"
jq -n --arg i "$SD/intake.md" --arg s "$SD/scope-manifest.md" --arg p "$ART/diff.patch" \
    '{inputs:{intake_goal:$i, scope_manifest:$s, diff_patch:$p}}' > "$SD/stage-inputs/review-lens.json"
printf '{"schema_version":1,"run_id":"lens-live","issue":0}\n' > "$SD/pipeline-state.json"

export ZBUILD_STATE_DIR="$SD" ZBUILD_ARTIFACT_DIR="$ART" ZBUILD_REPO_ROOT="$TGT"
export ZBUILD_STAGE_INPUTS="$SD/stage-inputs/review-lens.json"
export ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
export ZBUILD_CURRENT_STAGE="review-lens" ZBUILD_REVIEW_LENS_ID="correctness"
export ZBUILD_EVENTS_DIR="$SD/events" ZBUILD_EVENTS_JSONL="$SD/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"   # the router refuses a run with no event log

# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"

hits=0
for (( n = 1; n <= ATTEMPTS; n++ )); do
    export ZBUILD_RUN_ID="lens-live-$$-$n"
    out="$ART/lens-correctness-$n.json"
    ( cd "$TGT" && _review_lens_run_inner correctness "$SD/scope-manifest.md" "$ART/diff.patch" "$out" "$ART" ) \
        > "$WORK/run-$n.log" 2>&1 || true
    # The lens writes one summary path per lens id; keep each attempt's (review #2216).
    [[ -f "$ART/lens-correctness-summary.md" ]] && mv "$ART/lens-correctness-summary.md" "$ART/lens-correctness-summary-$n.md"
    msgs="$(jq -r '.findings[]? | "\(.file):\(.line // "-") \(.message)"' "$out" 2>/dev/null || true)"
    # Must cite UNCHANGED code: a neighbour by name, or the file's own stated
    # convention. A generic "bare git uses the cwd" is visible from the diff
    # alone and does not count.
    if grep -qiE '_sync_fetch|_sync_current_branch|_sync_is_clean|(file|header|documented|stated)[^.]{0,40}(convention|invariant|contract|rule)|(every|all|unlike)( of)? (the )?other|the other (two |three )?helpers|other helpers (all )?(take|pass|use|name)|lines? [1-9]-?[0-9]*\)' <<< "$msgs"; then
        hits=$(( hits + 1 )); verdict="CAUGHT"
    else
        verdict="missed"
    fi
    printf 'attempt %d: %s (lens verdict: %s)\n' "$n" "$verdict" "$(jq -r '.verdict // "no result"' "$out" 2>/dev/null || echo "no result")"
    [[ -n "$msgs" ]] && sed 's/^/    /' <<< "$msgs"
done

printf 'lens-live-check: %d of %d attempts cited the unchanged neighbours (need %d)\n' "$hits" "$ATTEMPTS" "$NEEDED"
(( hits >= NEEDED ))
