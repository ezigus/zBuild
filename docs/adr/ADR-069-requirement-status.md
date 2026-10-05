# ADR-069 — Requirement status: needs work (code), needs work (no code), already done

**Status:** Accepted (2026-10-05)
**Issue:** #2304
**Amends:** ADR-036 (the acceptance check), ADR-046 (design-gate C3/C4/C6), ADR-021, ADR-053 — the amendments land with the parts of this decision that change them (PR B and PR C of #2304)
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
2. **Planned (PR B of #2304).** An "already done" requirement names its evidence on its own line, after ` evidence: ` — a `file:line` or an existing test file. The evidence is not part of the requirement's text. *(The parser already reads it; nothing acts on it yet.)*
3. **Planned (PR B of #2304).** A code requirement keeps the existing rule: its test must fail on the code from before the change and pass after it.
4. **Planned (PR B of #2304).** No-code and done requirements are not run against the old code.
5. **Code nobody claims fails the acceptance check.** If the branch (merge-base to HEAD) changes production code and the acceptance block's requirements include no code requirement, the check fails. It names the files, and says what to add: "this change edits code (scripts/x.sh) but no requirement says what that code must now do — add a [code] requirement with a test". Production code is every path except `tests/`, `plugins/<kind>/<id>/tests/`, `docs/` and `*.md` files. An untagged requirement counts as code, because the negative control still checks it as code. The failure class is `unclaimed_code` (recoverable: design can add the requirement next round), and the event is `acceptance.gate.unclaimed_code`. A block that names no requirement ids has no status to read, so this check is silent for it.
6. **Planned (PR C of #2304).** test-author writes no test for a done requirement, and build is not asked to make one.
7. **Planned (PR C of #2304).** issue-acceptance judges no-code and done requirements against the issue, the change and the test results. When it is not confident, a person must check.
8. **Planned (PR B/C of #2304).** No `[guard]` path is left: the parser, the guard half of the negative control, design-gate C6, the guard reasons and event, and the guard text in prompts are removed.

## Consequences

- From this change on, a change cannot ship code under "no code" or "already done" labels alone. Only the backstop (§5) changes what a live run does; the parser change (§1) adds functions nobody in a live run calls yet, and lists `[no-code]` requirements that design does not yet write.
- Until PR B, a `[no-code]` or `[done]` requirement is still checked by the negative control the way an untagged one is.
- Until PR B, an old `[guard]`-only design whose change edits production code fails the backstop. That is intended: it is the #2035 shape.

## Implementation Notes (#2304 PR A)

- `scripts/lib/acceptance-block.sh`: one requirement-line pattern, `_ACCEPTANCE_SPEC_RE`, used everywhere a `SPEC-n[tag]:` line is read. `acceptance_spec_status`, `acceptance_spec_evidence`, and `acceptance_spec_text` (now without the evidence) read a requirement through `_acceptance_spec_line`, which sets variables instead of printing, so it costs no extra fork. The old `[change]`/`[guard]` helpers stay until PR B removes them.
- `scripts/lib/acceptance-negctl.sh`: `acceptance_unclaimed_code_check`, with `_acceptance_is_test_path` (the test-path rule from #2300, now shared with the `no_prod_delta` skip) and `_acceptance_is_production_path`.
- `plugins/agent/spec-acceptance/plugin.sh`: the check runs first (Level 0) and is reported in the same pass as the other levels. The manifest declares the event and the failure class; `scripts/lib/acceptance-disposition.sh` maps the class to recoverable.

## Enforced by

- §1 → `tests/unit/requirement-status-test.sh` S1 (a `[no-code]` requirement is listed), S2 (the status of each tag, including `[change]` → code and `[guard]` → done), S3 (evidence is split from the requirement text)
- §5 → `tests/unit/acceptance-unclaimed-code-test.sh` U1–U4 (U4 runs the gate's own entry); `tests/unit/acceptance-disposition-classify-test.sh` (`unclaimed_code` is recoverable)
- §2, §3, §4, §6, §7, §8 are planned. Each lands with its test in the PR that implements it (PR B and PR C of #2304), and this section names it then.
