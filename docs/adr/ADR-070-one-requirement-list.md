# ADR-070 — One fixed list of requirements per issue

**Status:** Accepted (2026-10-05)
**Issue:** #2306
**Amends:** ADR-046 (design-gate gains C7), ADR-069 §2 (a requirement line may also carry ` covers: `)
**Related:** ADR-055 (inter-stage data contract), ADR-040 §5 (spec-coverage judges against the issue), ADR-066 (every ADR statement has a test), ADR-067 (prompts speak plainly)

## Context

Every stage read the issue's prose and decided for itself what it asked for. On #2035 the issue said "SPEC-2" and "SPEC-3", meaning assertion labels inside a test file. Design, spec-coverage and issue-acceptance read them as design's own SPEC numbers and matched on names instead of content. Three readers of the same prose produced three different requirement lists, and nothing mechanical could say whether the design covered the issue.

Identifiers taken from prose are not deterministic. The engine has to number the requirements itself, once, and every later stage has to read that one list.

## Decision

1. **Intake writes one numbered list.** For an issue run, intake writes `artifacts/requirements.json`: `{"schema_version":1,"source":"checkboxes"|"title","requirements":[{"id":"R-1","text":"…"},…]}`. The source is every checkbox line of the issue body (`- [ ]` or `- [x]`, any bullet, any indent, under any heading), outside code fences, numbered R-1, R-2, … in order by code. The words are kept as written (control characters removed, ends trimmed); an identifier in them, such as `SPEC-2`, is text, never an id. An issue with no checkbox has one requirement, R-1: its title and the body's first paragraph, with `"source":"title"`. Comments are not read for the list.
2. **The list is a declared output, and only an issue has one.** intake's manifest declares the output `requirements` (`${artifact_dir}/requirements.json`, `required: false`), and design, design-gate, spec-coverage and issue-acceptance declare it as an input (`required: false`), so it reaches them through the engine's input index (ADR-055 §1). A goal run writes no list, and intake removes a list an earlier run left in the artifact directory.
3. **Design maps every requirement; a script checks it.** Design is shown the list and ends each SPEC line with ` covers: ` and the ids it covers, before any ` evidence: ` (`SPEC-1[code]: <behaviour> covers: R-1 R-3`). The parser (`scripts/lib/acceptance-block.sh`) keeps the covers part out of the requirement's text and its evidence, in either order, and `acceptance_spec_covers` returns the ids. The design-gate (C7, no model) fails a design when any R in the list is covered by no SPEC, whatever the SPEC's status — an already-done requirement is covered by a `[done]` SPEC — and names each uncovered R with its words (`REQUIREMENT_NOT_COVERED`). With no list, the check is skipped.
4. **The judges judge the list.** spec-coverage and issue-acceptance are shown the list (each `- R-n: <text>`) beside the issue text, judge every R by its words, and name a gap by its id and words. The issue text stays as context for what a requirement means. With no list, they read the requirements from the issue as before.

## Consequences

- Requirement ids are the same for every stage of a run and are never read from prose, so "SPEC-2" in an issue can no longer be mistaken for design's SPEC-2.
- A design that drops a requirement fails before build, by script, and the message names the requirement — spec-coverage no longer has to be the first to notice.
- An issue with no checkboxes becomes one broad requirement; writing the acceptance list as checkboxes is how an issue author gets each item checked on its own.

## Implementation Notes

- `plugins/agent/intake/lib/requirements.sh`: `_intake_requirements_json` (one jq program) and `_intake_write_requirements`; `plugin.sh` calls it after a successful fetch.
- `scripts/lib/acceptance-block.sh`: `_acceptance_spec_line` sets `_ACC_SPEC_COVERS`; `acceptance_spec_covers`; `acceptance_requirements_list` renders the list for prompts.
- `plugins/tool/design-gate/plugin.sh`: C7 collects the covers ids while reading each SPEC's status (no extra fork per SPEC).

## Enforced by

- §1 → `tests/unit/requirements-list-test.sh` Q1 (sequential ids from checkboxes, ticked and nested ones included, fenced ones left out, words kept; the title fallback)
- §2 → `tests/unit/requirements-list-test.sh` Q1 (the manifests declare the output and the four inputs; a goal run leaves no list)
- §3 → `tests/unit/requirements-list-test.sh` Q2 (covers split from the text and evidence, either order), Q3 (an uncovered R fails, named with its words; all covered — one by `[done]` — passes; no list skips), Q4 (the design prompt shows the list and the covers syntax)
- §4 → `tests/unit/requirements-list-test.sh` Q5 (spec-coverage prompt), Q6 (issue-acceptance prompt)
