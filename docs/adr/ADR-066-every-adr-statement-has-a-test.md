# ADR-066 — Every ADR statement has a test, and every issue rests on an ADR

**Status:** Accepted (2026-10-03)
**Issue:** #2268
**Related:** ADR-054 (stage contract; its §5 was the untested statement that prompted this), ADR-047 (stage-agnostic mechanics)

## Context

#1844 run 37066147994 passed every gate with a stage the engine never reads as v2. ADR-054 §5 says the result file is the stage's primary output; nothing enforced it (`core/plugin-registry/manifest-validation.sh` checks only the `result_contract` number). The run's own tests were written from the run's own reading of the issue, so they shared its misreading. The only thing that could have caught it was a repository test for the ADR statement, and there was none.

Before this ADR, ADRs were prose. Some statements had tests, most did not, and nothing said which. ADRs also drifted apart: a later decision could change a rule without amending the ADR that stated it (the 2026-10-03 audit found ADR-054 §5 and ADR-047 §3 disagreeing about where a v2 result lives).

## Decision

1. **Every normative ADR statement has a test.** A statement is normative when the code must obey it (must / never / always / "is"). A rule that lives only in an ADR's prose is a missing test. A test that only reads the ADR's text, or only checks that a function exists, does not count.
2. **Every live ADR has an `## Enforced by` section** naming, per statement (§), the test or lint that enforces it. A new or changed statement ships with its test in the same change.
3. **ADRs do not contradict each other.** When a decision changes a rule another ADR states, the change amends that ADR in the same PR.
4. **Every issue rests on an ADR.** It cites the ADR and § it implements. If no ADR covers the change, the issue first creates one or amends an existing one.
5. **The ADRs that predate this decision** are listed in `config/adr-enforcement-baseline.txt` until their sections are written. The list only shrinks; a new ADR is never added to it.

## Consequences

- `npm run lint` fails on a live ADR without its section, on a section naming a file that does not exist, and on a baseline entry that is no longer needed.
- Filling the 65 baselined ADRs is tracked from #2268, highest-risk statements first.
- Superseded, Deprecated, Withdrawn and Rejected ADRs need no section.

## Implementation Notes (#2268)

- `scripts/lib/lint-adr-enforced-by.sh`: reads each ADR's `**Status:**` line; Superseded, Deprecated, Withdrawn and Rejected ADRs are skipped. A live ADR's `## Enforced by` section runs to the next `##` heading, and every backticked `tests/`, `scripts/`, `core/` or `plugins/` path in it must exist (a `:line` suffix is allowed).
- `config/adr-enforcement-baseline.txt`: the 65 live ADRs that predate this decision. It only shrinks.
- `.github/ISSUE_TEMPLATE/change.yml`: the issue form; "ADR §" is required.
- The 2026-10-03 audit behind this decision is in `docs/audits/adr-2026-10-03/`: for every ADR, its statements, each one's enforcing test or UNTESTED, its risk, and the conflicts between ADRs.

## Enforced by

- §2, §5 → `scripts/lib/lint-adr-enforced-by.sh` (in `npm run lint`), tested by `tests/unit/lint-adr-enforced-by-test.sh` A1–A7
- §4 → the issue form's required "ADR §" field, `.github/ISSUE_TEMPLATE/change.yml`, tested by `tests/unit/lint-adr-enforced-by-test.sh` A8
- §1, §3 → applied in review; the per-ADR sections listed under §2 carry each statement's test
