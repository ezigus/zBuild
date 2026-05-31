# Deferred-tracker scanned PRs

Auto-maintained by `scripts/deferred-tracker.sh`. Each entry is a merged PR
that the deferred-tracker has scanned — listed whether or not a candidate was
found. Once a PR appears here, it is never re-scanned.

See [ADR-020](../../docs/adr/ADR-020-deferred-tracker.md) for design rationale.

_Last updated: 2026-05-31T18:53:06Z_

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
