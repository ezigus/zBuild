## build — pass

- changed config/shape-change-paths.txt, core/claim/claim.sh, core/pipeline/runner.sh, docs/adr/ADR-005-claim-coordinator.md, docs/adr/ADR-059-issue-vs-run-keying.md, plugins/claim-coordinator/github-labels/README.md, plugins/claim-coordinator/github-labels/plugin.sh, plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh, tests/integration/teardown-repeat-signal-test.sh (+228 / -29)

- over 3 pass(es), 3 iteration(s)
- answered: lens-security-change finding 1: done — replaced `error "issue ... is already claimed: ${_ZBUILD_CLAIM_HOLDER:-unknown}"` with `error "issue ... is already claimed"` + `printf '%s\n' "${_ZBUILD_CLAIM_HOLDER:-unknown}" >&2` in core/pipeline/runner.sh so backslash sequences in an attacker-controlled holder are never interpreted by echo -e.
- answered: lens-performance-change finding 1: done — removed the `$(cd ...)` subshell from plugins/claim-coordinator/github-labels/plugin.sh; now uses `${_ZBUILD_ROOT}/core/claim/claim.sh` when `$_ZBUILD_ROOT` is set, else `${BASH_SOURCE[0]%/*}/../../../core/claim/claim.sh` when the source path has a directory component.
- answered: lens-performance-change finding 2: done — replaced `$(_ccgl_backend)` with `${ZBUILD_CLAIM_BACKEND:-gh}` in `_ccgl_read_holder` in core/claim/claim.sh to eliminate the subshell.
- answered: lens-red-team-change finding 1: done — added `zbuild_claim_release || true` (with declare -F guard) and `zbuild_issue_lock_release || true` to both the `_runner_enter_worktree` failure path and the `zbuild_run_branch_setup` failure path in core/pipeline/runner.sh.
- answered: lens-red-team-change finding 2: done — sanitized the extracted holder via `printf '%s' "$_raw_holder"` before storing in `_ZBUILD_CLAIM_HOLDER` in `zbuild_claim_acquire` (core/claim/claim.sh), and the holder is printed with `printf '%s\n'` (not `error()`) in runner.sh so backslash sequences are never interpreted.
- answered: lens-correctness-change finding 1: done — added `unset _ZBUILD_CLAIM_ACQUIRED` BEFORE `_ccgl_remove_label` in `zbuild_claim_release` in core/claim/claim.sh; a second call now returns at the guard check (`[[ -z "${_ZBUILD_CLAIM_ACQUIRED:-}" ]] && return 0`).
- answered: lens-scope-change finding 1: done — added `core/claim/claim.sh` to config/shape-change-paths.txt.
- answered: lens-sre-change finding 1: done — removed `$(cd ...)` subshell from plugins/claim-coordinator/github-labels/plugin.sh; replaced with `$_ZBUILD_ROOT`-first, `${BASH_SOURCE[0]%/*}`-fallback pattern that never forks.
- answered: lens-sre-change finding 2: done — added `printf '...' >&2` stderr warning in `zbuild_claim_acquire` on both the `_zbuild_claim_read_labels_into` failure path and the `_zbuild_claim_add_label_direct` failure path in core/claim/claim.sh.
- answered: lens-sre-change finding 3: done — changed `_ccgl_remove_label "$issue" "zbuild:claimed" || true` to `_ccgl_remove_label ... || { printf '...' >&2 || true; }` in `zbuild_claim_release` in core/claim/claim.sh; operators now see a warning when the label cannot be removed.
- answered: lens-sre-change finding 4: done — same fix as correctness-change finding 1; `unset _ZBUILD_CLAIM_ACQUIRED` before `_ccgl_remove_label` makes the second-call guard effective.
- answered: lens-sre-code finding 1: not mine — the DSCLA-9 fixture is in tests/integration/teardown-repeat-signal-test.sh, which is a test file I may not change; the fix belongs to the test-author stage.
- step 1: not needed — plugin.sh zbuild:claimed changes were done in prior iterations; all tests pass.
- step 2: not needed — README.md already describes zbuild:claimed (done in iteration 7).
- step 3: not needed — run-status-render.sh already has holder comment (done in prior iteration).
- step 4: not needed — core/claim/claim.sh was created in a prior iteration; this iteration amended it.
- step 5: not needed — config/event-schema.json already has pipeline.refused.claimed.
- step 7: not needed — the core wiring was done in prior iterations; this iteration fixed early-failure paths and the printf vs error() change.
- step 8: not needed — ADR-005 Enforced by was updated in iteration 7.
- step 9: not needed — ADR-059 §4 Enforced by entry was added in iteration 7.
- step 6: done — config/shape-change-paths.txt | core/claim/claim.sh
