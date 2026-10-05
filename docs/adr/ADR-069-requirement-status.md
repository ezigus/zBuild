# ADR-069 — Requirement status: needs work (code), needs work (no code), already done

**Status:** Accepted (2026-10-05)
**Issue:** #2304
**Amends:** ADR-036 (the acceptance check: the #1670, #1777, #2234 and #2244 guard rules are superseded), ADR-046 (design-gate C3/C4 rewritten, C6 removed), ADR-021 and ADR-053 (historical notes) — amended in PR B of #2304
**Carries out:** ADR-037's planned removal of the `[change]`/`[guard]` classification (ADR-037, the ADR-031 and ADR-036 rows of its retirement table)
**Related:** ADR-066 (every ADR statement has a test), ADR-067 (prompts speak plainly), ADR-068 (finding answers)

## Context

Design tags every requirement in the acceptance block `[change]` or `[guard]`. A `[change]` requirement's test must fail on the code from before the change and pass after it. A `[guard]` requirement's test must pass on the old code: it says something the code already does.

The guard rules did not pay for themselves. Across 23 issues (1,831 requirements):
- 27% of requirements were `[guard]`, and they caught zero real regressions. A guard is only ever run on the old code, so "the guard failed" always meant a wrong label or a broken test, never a regression.
- They cost about 7 engine fixes (#1670, #1777, #2234, #2244, …) and more than 15 hours of runs.
- The original reason for them (#1670: build writing a test that agrees with its own wrong code) is closed. test-author writes the tests before build, and build cannot edit them.
- Relabelling requirements as `[guard]` is how #2035 dropped its own red step: nothing it changed had to fail first.

ADR-037 already planned to remove the classification. This ADR says what replaces it.

## Decision

1. **Every requirement has one status, written as its tag.** `SPEC-n[code]:` needs work, and the work is code. `SPEC-n[no-code]:` needs work that changes no behaviour: docs, a test, config, or a refactor. `SPEC-n[done]:` is already done: the code already does it. A tag may contain a hyphen. The old tags keep being read during the transition: `[change]` means code, and `[guard]` means done. A requirement with no tag, or with a tag none of these name, has no status (design-gate rejects it).
2. **The design-gate checks every status, and an "already done" requirement names evidence that exists.** The evidence ends the requirement's line, after ` evidence: ` — one or more items separated by spaces, each a repo-relative `file` or `file:N` (no leading `/`, no `..`). The file must exist and `N` must be a line inside it. The evidence is not part of the requirement's text. The design-gate (C3) rejects a requirement with no status (`NO_STATUS`), an unknown tag or the retired `[guard]` (`UNKNOWN_STATUS`), a `[done]` with no evidence (`DONE_NO_EVIDENCE`), and an evidence item that does not point at the repository (`DONE_BAD_EVIDENCE`), and says each in plain words. Design is told the three statuses and the evidence syntax. When the acceptance check says a `[code]` requirement's test already passes on the old code, design is told to rewrite it so its test fails there, or — if the code already does it — to mark it `[done]` with evidence. There is no offer to relabel: `[done]` is a claim the gate checks, not a way to drop the red step (#2035).
3. **A code requirement keeps the existing rule:** its test must fail on the code from before the change and pass after it. `[code]`, the old `[change]`, and an untagged requirement are all checked this way, and only a code requirement must name a test file (design-gate C4).
4. **No-code and done requirements are not run against the old code.** The acceptance check prints `NEGCTL SKIP <id> already_done` or `NEGCTL SKIP <id> no_code` for them, and does not ask them for a tagged assertion (Level 1). With no code requirement at all, nothing is run. The pass reason counts the requirements checked on the old and new code, already done, and needing no code.
5. **Code nobody claims fails the acceptance check.** If the branch (merge-base to HEAD) changes production code and the acceptance block's requirements include no code requirement, the check fails. It names the files, and says what to add: "this change edits code (scripts/x.sh) but no requirement says what that code must now do — add a [code] requirement with a test". Production code is every path except `tests/`, `plugins/<kind>/<id>/tests/`, `docs/` and `*.md` files. An untagged requirement counts as code, because the negative control still checks it as code. The failure class is `unclaimed_code` (recoverable: design can add the requirement next round), and the event is `acceptance.gate.unclaimed_code`. A block that names no requirement ids has no status to read, so this check is silent for it.
6. **test-author writes no test for a done requirement, and build is not asked to make one.** test-author leaves a done requirement out of its prompt; a design whose requirements are all done completes with no model call. A no-code requirement's test must pass after the change and need not fail before. Build's list of requirements leaves out the done ones. The review lenses read each status in plain words, with a done requirement's evidence.
7. **Planned (PR C of #2304).** issue-acceptance judges no-code and done requirements against the issue, the change and the test results. When it is not confident, a person must check.
8. **Planned (PR C of #2304).** No `[guard]` path is left. PR B removed the guard half of the negative control, design-gate C6, the guard reasons, classes and event, and the guard text in the design, test-author, build and review-lens prompts. PR C removes what remains: the parser reading `[guard]` as done, and a lint that refuses `[guard]` in model-facing text.

## Consequences

- A change cannot ship code under "no code" or "already done" labels alone (§5), and "already done" must point at the code that does it (§2).
- A `[guard]` requirement no longer passes the design-gate. A design written before this change is rejected there once, with a plain message saying which status to use, and design rewrites it.
- The fork budget goes down: a done or no-code requirement costs no test run, and a design with no code requirement makes no worktree.

## Implementation Notes (#2304 PR B)

- `scripts/lib/acceptance-negctl.sh`: the guard arm, the baseline-only verdict, the design-gate pre-check and their helpers are gone. Each SPEC's status is read once per check; done and no-code SPECs are skipped before anything runs. `_negctl_guard_log_check` is now `_negctl_spec_log_check` (shared with `acceptance-reachability.sh`).
- `scripts/lib/acceptance-block.sh`: `acceptance_spec_is_guard`, `acceptance_spec_classifier` and `acceptance_spec_is_change` are removed; callers read `acceptance_spec_status`.
- `plugins/tool/design-gate/plugin.sh`: C3 (status, evidence) and C4 (`[code]` only) rewritten; C6 and the `guard_precheck` block removed; the gate no longer sources the negative-control library.
- `plugins/agent/spec-acceptance`: the guard reasons, the `acceptance.gate.guard_regressed` event and the guard classes are removed (also from `scripts/lib/acceptance-disposition.sh`); the pass reason counts each status.

## Implementation Notes (#2304 PR A)

- `scripts/lib/acceptance-block.sh`: one requirement-line pattern, `_ACCEPTANCE_SPEC_RE`, used everywhere a `SPEC-n[tag]:` line is read. `acceptance_spec_status`, `acceptance_spec_evidence`, and `acceptance_spec_text` (now without the evidence) read a requirement through `_acceptance_spec_line`, which sets variables instead of printing, so it costs no extra fork. The old `[change]`/`[guard]` helpers stay until PR B removes them.
- `scripts/lib/acceptance-negctl.sh`: `acceptance_unclaimed_code_check`, with `_acceptance_is_test_path` (the test-path rule from #2300, now shared with the `no_prod_delta` skip) and `_acceptance_is_production_path`.
- `plugins/agent/spec-acceptance/plugin.sh`: the check runs first (Level 0) and is reported in the same pass as the other levels. The manifest declares the event and the failure class; `scripts/lib/acceptance-disposition.sh` maps the class to recoverable.

## Enforced by

- §1 → `tests/unit/requirement-status-test.sh` S1 (a `[no-code]` requirement is listed), S2 (the status of each tag, including `[change]` → code and `[guard]` → done), S3 (evidence is split from the requirement text)
- §5 → `tests/unit/acceptance-unclaimed-code-test.sh` U1–U4 (U4 runs the gate's own entry); `tests/unit/acceptance-disposition-classify-test.sh` (`unclaimed_code` is recoverable)
- §2 → `tests/unit/design-gate-test.sh` G1 (no status), G2 (`[guard]` and an unknown tag rejected; `[change]` and `[no-code]` accepted), G3 (`[done]` with no evidence), G4 (evidence that exists passes; absolute, `..`, missing, out-of-range and non-numeric lines are rejected); `tests/unit/design-gate-feedback-plain-test.sh` D2 (each said in plain words); `tests/unit/design-acceptance-block-test.sh` T6 (the design prompt explains the three statuses and the evidence syntax, and offers no `[guard]`/`[change]`); `tests/unit/design-prior-gate-feedback-test.sh` T1 (the acceptance-failed re-prompt says rewrite or `[done]` with evidence, and has no relabel offer)
- §3 → `tests/unit/acceptance-negctl-status-test.sh` N4 (`[code]`, `[change]` and untagged requirements are still checked on the old and new code); `tests/unit/design-gate-test.sh` G5 (only `[code]`/`[change]` need a test file)
- §4 → `tests/unit/acceptance-negctl-status-test.sh` N1 (`[done]` not run), N2 (`[no-code]` not run), N3 (tag coverage exempts both), N5 (the pass reason counts each status); `tests/unit/acceptance-coverage-test.sh` C7, C9
- §6 → `tests/unit/test-author-test.sh` T1 (a done requirement is left out; a no-code one need not fail before), T2 (all done → no model call); `tests/unit/build-prompt-spec-text-test.sh` B1 (build's list leaves out done); `tests/unit/review-lens-requirements-plain-test.sh` L5 (each status in plain words, with evidence)
- §7 and §8 are planned. Each lands with its test in PR C of #2304, and this section names it then.
