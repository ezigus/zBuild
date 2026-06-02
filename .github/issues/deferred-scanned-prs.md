# Deferred-tracker scanned PRs

Auto-maintained by `scripts/deferred-tracker.sh`. Each entry is a merged PR
that the deferred-tracker has scanned — listed whether or not a candidate was
found. Once a PR appears here, it is never re-scanned.

See [ADR-020](../../docs/adr/ADR-020-deferred-tracker.md) for design rationale.

_Last updated: 2026-06-02T19:45:50Z_

| PR | Title | Scanned |
|---|---|---|
| #539 | feat(#531): implement deferred-tracker workflow (ADR-020) | 2026-05-31 |
| #537 | feat(runner): pipeline.end terminal banner with status + duration (#525) | 2026-05-31 |
| #536 | fix(build): classify git apply --check rc=128 as corrupt_format / tool_state (#529) | 2026-05-31 |
| #535 | fix(runner): cycle non-converged rc preserved as pipeline status=failed; review fall-through hardened (#527) | 2026-05-31 |
| #534 | feat(cycle): early-abort on verdict=error/corrupt_diff (reason=blocked, rc=5) (#528) | 2026-05-31 |
| #533 | feat(cycle): operator WARN banner for HIGH-severity cycle events (#526) | 2026-05-31 |
| #532 | docs(ADR-020): propose deferred-work tracker workflow | 2026-05-31 |
| #522 | docs(adr): cross-reference cleanup + missed-amendment audit fixups | 2026-05-31 |
| #521 | feat(cycle): wire concrete build/test cycle + manifest cycle_feedback source (F2) (#511) | 2026-05-31 |
| #520 | feat(pipeline): ADR-021 outer-cycle orchestrator framework (F1) (#512) | 2026-05-31 |
| #519 | feat(build): corrupt-patch guard with git apply --check before LOOP_COMPLETE (#509) | 2026-05-31 |
| #518 | feat(banner): split prose+JSON in plan/review renderers (#510) | 2026-05-31 |
| #517 | feat(runner): verdict-driven stage indicator; primary-output manifest field (#507) | 2026-05-31 |
| #516 | feat(runner): stage-start + stage-end timestamps with duration (#508) | 2026-05-31 |
| #515 | feat(review): numstat summary in operator banner; LLM still sees full diff (#506) | 2026-05-31 |
| #514 | feat(router): dedupe static prompt + suppress diff in loop banner (#505) | 2026-05-31 |
| #513 | fix: redaction false-positive on N/M counters (#504) | 2026-05-31 |
| #503 | feat(#499): single-BLUE palette + LIGHT_BLUE ═ I/O dividers | 2026-05-31 |
| #502 | feat(#498): build emits changed-files numstat banner (kind=computed) | 2026-05-31 |
| #501 | feat(#497): test plugin emits stage-io banner with parsed summary | 2026-05-31 |
| #500 | feat(#496): inter-stage data contract + pre-flight validator (ADR-020) | 2026-05-31 |
| #495 | [manifest-sync] Drift reconciliation | 2026-05-31 |
| #494 | feat(#492): stage-io visual hierarchy + timestamps (ADR-015 §v5) | 2026-05-31 |
| #493 | fix(#491): stage-io ordering contract (ADR-015 amendment + #481 fix) | 2026-05-31 |
| #490 | feat(#482): emit stage_io banner per build loop iteration (Pattern 2) | 2026-05-31 |
| #489 | fix(#481): split stage-io banner into begin/end phases (Pattern 1) | 2026-05-31 |
| #488 | feat(#485): review fail-closed on unknown/failed tests + enable test stage | 2026-05-31 |
| #487 | feat(#484): intake creates feature branch from issue (fail-closed) | 2026-05-31 |
| #486 | fix(#483): plugins tag route_to_model capture with metadata.artifact (ADR-018) | 2026-05-31 |
| #480 | [manifest-sync] Drift reconciliation | 2026-05-31 |
| #554 | fix(runner): add || true to eb_emit_event in stage dispatch loop to prevent pipeline.abort (#547) | 2026-05-31 |
| #553 | fix(test): write test-results.json verdict=error on diff_apply_failed to trigger cycle blocked predicate (#550) | 2026-05-31 |
| #552 | fix(test): reset temp worktree to HEAD before diff apply to prevent diff_apply_failed (#548) | 2026-05-31 |
| #551 | fix(build): NUL detection false positive - use grep -P instead of bash $'\x00' empty string (#549) | 2026-05-31 |
| #546 | feat(#541): one-shot historical deferred-work backfill | 2026-05-31 |
| #545 | feat(#540): extract gha_is_already_scanned + gha_append_scanned_log | 2026-05-31 |
| #544 | fix(build): diff capture trailing-newline + bidirectional apply-check + hunk-count validation (#530) | 2026-05-31 |
| #543 | feat(banner): drop stage-io: prefix + blank-line spacing between stages (#523) | 2026-05-31 |
| #538 | feat(cycle): operator-visible banners for cycle.start/iter/complete (#524) | 2026-05-31 |
| #599 | feat(cleanup): handle zb-applycheck-* stashes + tmpdirs + --restore-stash flag (#594) | 2026-06-01 |
| #598 | feat(#596): deferred output formatting — spacing, longer excerpts, visible scores | 2026-06-01 |
| #597 | feat(install): copy code to $ZBUILD_HOME instead of symlinking (#595) | 2026-06-01 |
| #593 | fix(test): pattern bank for known runners + honest fail-safe (no fabricated counts) (#584) | 2026-06-01 |
| #592 | feat(template): inline cycles as stage entries — v2 hard-break + migration script (#585) | 2026-06-01 |
| #591 | feat(#589): zbuild deferred/manifest CLI subcommands + structured --help | 2026-06-01 |
| #590 | fix(build): remove duplicate [computed] post-loop banner — event-only discrepancy signal (#587) | 2026-06-01 |
| #588 | fix(test-harness): open fd 3 in run-tests.sh + relax stage-io guard with warn+event fallback (#586) | 2026-06-01 |
| #582 | feat(cycle): 3-stage build_test_cycle [build,test,test_assessment] + until on assessment + feedback rewire (#568) | 2026-06-01 |
| #581 | feat(build): prompt v2 framing — ORIGINAL TASK / INSTRUCTIONS / ITERATION FEEDBACK (#571) | 2026-06-01 |
| #580 | feat(review): consume test_assessment.verdict (preferred) in fail-closed coercion (#569) | 2026-06-01 |
| #579 | feat(#562): manifest-sync orphan annotation (READ-ONLY) — sub-4 of #555 | 2026-06-01 |
| #578 | feat(#561): deferred-backfill similarity-based annotation (sub-3 of #555) | 2026-06-01 |
| #577 | feat(cleanup): zbuild cleanup --force for branches + state dirs (#570) | 2026-06-01 |
| #576 | feat(test_assessment): new Pattern 1 stage modeled after plan — LLM interprets test results (#567) | 2026-06-01 |
| #575 | fix(banner): export ZBUILD_CURRENT_STAGE in cycle dispatch so [llm] banner emits (#566) | 2026-06-01 |
| #574 | docs(adr): amendments + new ADR-022 for test_assessment stage (#572) | 2026-06-01 |
| #573 | feat(#560): deferred-tracker dup annotation + update-in-place (sub-2 of #555) | 2026-06-01 |
| #565 | feat(#559): LLM tiebreaker for borderline Jaccard scores (fail-open) — sub-6 of #555 | 2026-06-01 |
| #564 | feat(#558): gha_compute_similarity Jaccard helper + ADR-020 v2 (sub-1 of #555) | 2026-06-01 |
| #644 | chore: drop unit step continue-on-error (#635 fixed) | 2026-06-02 |
| #643 | fix(#628): RETURN traps for tmpdir self-cleanup + remove false-positive pattern | 2026-06-02 |
| #642 | fix(#635): broaden T45 skip guard to cover Linux CI | 2026-06-02 |
| #641 | fix(#627): test_assessment fail-CLOSED on missing/malformed input | 2026-06-02 |
| #640 | fix(#626): defensive jq writer in _test_write_result | 2026-06-02 |
| #638 | chore: drop integration step continue-on-error (96/96 passing) | 2026-06-02 |
| #637 | fix(#632, #633): unset CI + bypass closed-issue gate in intake-branch tests | 2026-06-02 |
| #636 | fix(#631): T6 use sha256 content hash instead of mtime | 2026-06-02 |
| #634 | fix(#625): test plugin positional args + empty diff.patch guard | 2026-06-02 |
| #630 | fix(#629): CI pipefail + temporarily mark integration continue-on-error | 2026-06-02 |
| #624 | fix(#623): I1 plugin setup missing test_assessment + update I1b count 5→6 | 2026-06-02 |
| #622 | fix(#619): runner abort-trap test deterministic failure + output noise cleanup | 2026-06-02 |
| #620 | fix(runner): export ZBUILD_STATE_DIR so #617 branch-state injection fires (#618) | 2026-06-02 |
| #617 | feat(intake,route): branch-cumulative context in iter prompts (#614) | 2026-06-02 |
| #616 | fix(sigint): propagate rc=130 through router → build → runner (#612) | 2026-06-02 |
| #615 | fix(build,router): loop_complete clarity + empty-diff safety net (#613) | 2026-06-02 |
| #611 | feat(build): pipeline commits per cycle iter using COMMIT_SUMMARY marker (#608) | 2026-06-02 |
| #610 | fix(redaction): allowlist on initial pass + idempotent markers (#606) | 2026-06-02 |
| #609 | fix(test): silence git clean + checkout in test plugin prep (#607) | 2026-06-02 |
| #605 | fix(build): strip the stash dance — LLM edits in place, capture git diff HEAD directly (#602) | 2026-06-02 |
| #604 | feat(test): ZBUILD_TEST_QUIET=1 suppresses per-assertion echoes (#600) | 2026-06-02 |
| #603 | fix(portability): replace grep -P with portable equivalents in 3 tests (#601) | 2026-06-02 |
| #556 | [manifest-sync] Drift reconciliation | 2026-06-02 |
| #658 | docs(adr-016): Per-Repository Template Resolution (Proposed) | 2026-06-02 |
| #657 | docs(adr-013): taxonomy-only scope clarification (ADR-016 prerequisite) | 2026-06-02 |
| #651 | fix(#646): stage-output framing — discrepancy warn inside banner + blank line between stages | 2026-06-02 |
| #650 | fix(#647): defense-in-depth fd 3 / ZBUILD_STAGE_IO_FD isolation in router | 2026-06-02 |
| #648 | [manifest-sync] Drift reconciliation | 2026-06-02 |
