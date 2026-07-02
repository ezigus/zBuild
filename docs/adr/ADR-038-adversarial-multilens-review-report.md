# ADR-038 — Adversarial multi-lens review report (evidence-fed, advisory)

**Status:** Accepted (2026-06-19)
**Related** — dispositions below are **PLANNED** (the map lives in ADR-037 §6, executed in I13 / #979); **this PR edits no existing ADR**:
- peer: ADR-037 (objective gates vs. semantic judgment); EPIC #966
- supersede-planned: ADR-022, ADR-026
- amend-planned: ADR-019, ADR-036, ADR-030 (R3 assertion-integrity folded into a review lens)
**Issue:** #967 (EPIC #966, I1)

## Context

ADR-037 routes all semantic judgment to a single advisory stage. This ADR defines that stage.

The trap to avoid is documented by the system it replaces: `cq-cycle` is a 7-lens audit loop and it
catches **nothing** (it writes `"findings":[]`). Adding lenses to a hollow loop produced zero teeth,
because every lens read the *same* diff and asked "is this good?" in a different voice — they correlate
and miss the same blind spots. The adversarial-critique analysis was blunt: "diverse *questions over
identical evidence* is the cq-cycle trap," and a review that doesn't change a decision is inert by
construction.

So the burden on this stage is to be **structurally** different from the single review and from
cq-cycle, not merely "more lenses."

## Decision

Collapse all semantic judgment — the former `review` verdict, `test_assessment`'s LLM grading, the
cq-cycle lens loop, the `impact` adversarial consequence-finding, and ADR-030's assertion-integrity
charter — into ONE `review` stage that runs **after** the objective gates (ADR-037) pass.

### 1. Single pass, parallel lens fan-out

One stage, no remediation cycle. The lenses run concurrently in a single pass; there is no loop that
exists to make the report turn green (that loop — ADR-026 review-remediation — is removed). Findings may
optionally seed ONE bounded build retry, but the report is advisory and is not a convergence predicate.

### 2. Each lens is fed DISTINCT mechanical evidence

This is the structural difference from cq-cycle. A lens receives a *different artifact*, not just a
different prompt over the same diff:

- "wired into the live path?" ← the reachability-ablation result (ADR-037 objective layer)
- "is the risky code tested?" ← the coverage map + `negctl` baseline-fail output
- "did build honor the design?" ← the `design.md` decisions (the #919 surface)
- "is the change complete / consistent?" ← the call graph / changed-symbol closure

A lens whose evidence is unavailable says so in the report rather than guessing.

**Change-bundle basis (#896/#952).** When a lens has no distinct per-lens artifact it falls back to the
shared "change bundle". That bundle is the **full-branch merge-base diff** — `git diff <merge-base> HEAD`
resolved via the shared `zbuild_resolve_merge_base` (`scripts/lib/merge-base.sh`, candidates
`origin/main → main → HEAD~1`) — NOT the per-run incremental build `diff.patch`. The incremental diff is
EMPTY on a resumed/green run or when the work was committed before intake, which silently starved every
lens of evidence (the observed #952 failure where all lenses hit the C6 redaction precondition on empty
input). `review`, `review-lens` and `review-report` all resolve this ONE basis through
`zbuild_change_bundle`, so the operator banner, the `review` verdict, and the advisory lenses judge the
same change set. Fallback chain (fail-soft, never crashes): merge-base diff → build `diff.patch` →
"(no change bundle available)" sentinel.

### 3. Output is a report, never a gate

The stage emits a structured **merge-readiness report** (findings + severities + rationale), aggregated
and de-duped (file + category + proximity). It **never hard-blocks merge and never coerces a verdict**
(no `approve`/`request_changes`/`block` mutation). Per ADR-037's invariant, no semantic lens hard-blocks
merge. Escalation to a human PR is decided by ADR-037's `merge_policy` from the report's top-severity
findings / lens disagreement — the report is the *input* to that policy, not a gate itself.

### 4. Lenses are the rehomed cq + persona content

The lenses are the existing cq audit lenses (security / logic / integration / completeness /
error-handling / performance / edge-case) and the persona plugins (architecture-enforcer, red-team,
developer-sim, …), plus design-decision-honoring and assertion-integrity (folded from ADR-030 R3). The
inert cq-cycle / cq-audit-plan / cq-backtrack orchestration is retired (ADR-037 §6 / I13); the lens
*content* is preserved.

## Consequences

- The single point of semantic failure (one fallible review verdict that could be smuggled past or could
  coerce) is replaced by diverse, evidence-fed judgment whose output informs — but does not forge — the
  merge decision.
- Because each lens consumes mechanically-derived evidence, the "wired-in?" and "tested?" questions are
  backed by the objective layer's deterministic results, not by an LLM re-reading the diff — closing the
  gap that made cq-cycle inert.
- `test_assessment` as an LLM grader is no longer needed (build/test convergence uses objective
  suite-green per ADR-037); the review-remediation cycle (ADR-026) is removed.

## Implementation Notes (EPIC #966)

Delivered by the Group-2 sub-issues of EPIC #966:

- **#972** — the review stage: single pass, parallel lens fan-out, emits the merge-readiness report;
  no merge coupling, no coercion.
- **#973** — evidence plumbing: feed each lens its distinct mechanical evidence (reachability result,
  coverage map, `negctl` baseline-fail output, `design.md` decisions per #919, call graph).
- **#974** — rehome the cq audit + persona lenses into the fan-out; aggregate + dedup the report.

Escalation wiring to `merge_policy` lands with #975; the retirement of `test_assessment` / cq-* / the
review-remediation cycle lands with #976 / #979 per ADR-037 §6.

## Limitations / future work

- "More lenses" only helps if the evidence is genuinely diverse (§2); adding a lens that reads only the
  diff re-creates the cq-cycle trap. New lenses must declare their evidence input.
- The report changes a decision only via `merge_policy` (ADR-037) and the human; if a template runs
  `merge_policy: auto`, the report is purely informational — acceptable, but it then catches nothing on
  its own (by design, the objective gates are the floor).
- Per-lens model/tier selection and cost bounds are out of scope here (router config, ADR-017).

## Amendment (Issue OUT — merge-readiness report surfaced to the operator)

The aggregated merge-readiness report is now surfaced to the operator as
human-readable PROSE, not just written to disk. After `review-aggregator` writes
`review-report.json` + `review-report.md` (rendered by `render_review_report_md`),
it prints the already-rendered `.md` to `fd ${ZBUILD_STAGE_IO_FD:-2}`, gated on
the stage's own `io:` destinations (`template_stage_io_dests`): a file-only
install stays silent; a stdout install shows the full readiness header, summary,
and per-lens / de-duped findings. Because the lens members are file-only
(ADR-015 / ADR-039), this aggregator prose — together with the per-member
one-liners — is the operator's human-readable review surface; the raw lens and
report JSON remain in artifacts. Guarded by `tests/unit/review-aggregator-test.sh`
(io-gated print, both directions) and `tests/integration/review-lenses-output-test.sh`.
