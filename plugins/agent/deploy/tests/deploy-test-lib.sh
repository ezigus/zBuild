#!/usr/bin/env bash
# plugins/agent/deploy/tests/deploy-test-lib.sh — fixtures shared by the deploy
# tests (sourced, not run). Needs TEST_TEMP_DIR, _ZB_ID and ZBUILD_RUN_ID set.
# shellcheck disable=SC2034

# ─── Mocks ───────────────────────────────────────────────────────────────────

emit_event() { return 0; }

apply_scope_redaction() {
    local _in="$1" _out="$2"
    cp "$_in" "$_out"
    return 0
}

# ─── Helper: make a minimal state dir and set v2 dispatch env vars ────────────
# Sets ZBUILD_STAGE_INPUTS (the engine's input index with pr_url and
# gate_aggregator_result) and ZBUILD_ARTIFACT_DIR. Called in THIS shell
# (not a subshell) so the exports reach the calling test.
_make_state() {
    local dir="$1"
    mkdir -p "$dir/artifacts" "$dir/stage-inputs"
    jq -n --arg iss "$_ZB_ID" --arg run "$ZBUILD_RUN_ID" \
        '{issue:$iss, run_id:$run}' > "$dir/state.json"
    jq -n \
        --arg pr  "$dir/artifacts/pr-url.txt" \
        --arg gr  "$dir/artifacts/gate-aggregator-result.json" \
        '{"inputs":{"pr_url":$pr,"gate_aggregator_result":$gr}}' \
        > "$dir/stage-inputs/deploy.json"
    export ZBUILD_STAGE_INPUTS="$dir/stage-inputs/deploy.json"
    export ZBUILD_ARTIFACT_DIR="$dir/artifacts"
}

# ─── Helper: assert all four mandatory v2 keys are present ───────────────────
_v2_keys_ok() {
    local lbl="$1" f="$2"
    local _rc _vd _dp _rs
    # One jq for all four keys (review #2219: this helper forked four times per call).
    IFS=$'\t' read -r _rc _vd _dp _rs < <(jq -r \
        '[(.result_contract // "" | tostring), (.verdict // ""), (.disposition // ""), (.reason // "")] | @tsv' \
        "$f" 2>/dev/null || true) || true
    assert_eq "$lbl result_contract=2" "2" "$_rc"
    if [[ -n "$_vd" ]]; then
        assert_pass "$lbl verdict key present"
    else
        assert_fail "$lbl verdict key must be present" "absent"
    fi
    if [[ -n "$_dp" ]]; then
        assert_pass "$lbl disposition key present"
    else
        assert_fail "$lbl disposition key must be present" "absent"
    fi
    if [[ -n "$_rs" ]]; then
        assert_pass "$lbl reason key present and non-empty"
    else
        assert_fail "$lbl reason key must be present and non-empty" "absent or empty"
    fi
}

# ─── The outside world, faked on PATH ────────────────────────────────────────
# `git` records every call and fails on demand; nothing inside zBuild is faked.
#   FAKE_GIT_TAG_RC / FAKE_GIT_PUSH_RC — exit code for `git tag <name>` / `git push`
#   FAKE_GIT_PUSH_SIGNAL=1 — `git push` sends SIGTERM to the stage's shell first,
#   as an engine stopping the stage mid-release would.
FAKE_BIN="$TEST_TEMP_DIR/fake-bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/git" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
case "${1:-}" in
    tag)  if [[ "${2:-}" == "-d" ]]; then exit 0; fi; exit "${FAKE_GIT_TAG_RC:-0}" ;;
    push) if [[ "${FAKE_GIT_PUSH_SIGNAL:-0}" == "1" ]]; then kill -TERM "$PPID"; exit 143; fi
          exit "${FAKE_GIT_PUSH_RC:-0}" ;;
esac
exit 0
FAKE
printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >> "$FAKE_GIT_LOG"\n' > "$FAKE_BIN/gh"
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/gh"

# _deploy_case <dir> <gate verdict|-> [VAR=value ...] — one deploy run in a
# SUBSHELL (nothing it exports reaches the next case), pr-url and gate result
# seeded; prints the rc. The fake git logs to <dir>/git.log.
_deploy_case() {
    local dir="$1" gate="$2"; shift 2
    (
        _make_state "$dir"
        printf 'https://github.com/test/repo/pull/42\n' > "$dir/artifacts/pr-url.txt"
        [[ "$gate" == "-" ]] || printf '{"verdict":"%s"}\n' "$gate" > "$dir/artifacts/gate-aggregator-result.json"
        export PATH="$FAKE_BIN:$PATH" FAKE_GIT_LOG="$dir/git.log" ZBUILD_DRY_RUN=0
        local kv; for kv in "$@"; do export "${kv?}"; done
        : > "$FAKE_GIT_LOG"
        deploy_agent_run "deploy" "$dir/state.json"
    ) >/dev/null 2>&1
    printf '%s' "$?"
}
_rj() { jq -r "$2 // empty" "$1/artifacts/deploy-result.json" 2>/dev/null || true; }
