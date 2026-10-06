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
resolved via the shared `zbuild_resolve_merge_base` (`scripts/lib/merge-base.sh`) — NOT the per-run
incremental build `diff.patch`. *(Amended by #1655: the candidates were `origin/main → main → HEAD~1`;
the trunk is now resolved rather than assumed, and the `HEAD~1` guess is gone — an unresolvable baseline
returns empty and falls through to the `diff.patch` step of the chain below.)* The incremental diff is
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

## Amendment (2026-09-28): a lens judges with context, and says what is new

**Evidence.** #1845's PR #2213: six lenses, 22 findings, 0 critical/high. They
missed the two real defects — a path the plugin built itself (the issue forbade
it) and 26 assertion tags stripped from a shared test — and raised false ones:
engine-set `ZBUILD_*` values read as attacker input, a test's hand-wiring read
as the production path, unchanged behaviour (`ZBUILD_DRY_RUN` trust) blamed on
the change, and every planned file the change did not touch. Each lens saw only
the diff and was told "report only issues you can point to in the change below"
(#1654).

**Decision.** Still one isolated call per lens (§2); what it is given changes.
1. **What the change was for.** The prompt carries the issue text, the design's
   acceptance contract (SPECs) and the planned scope — optional name-matched
   inputs (`intake_goal`, `design`) resolved by the engine.
2. **Read around the change.** The diff shows what changed; the lens is told to
   read the rest of the file, callers, input producers and comparable code, and
   may cite unchanged code as evidence (#1654).
3. **New or pre-existing.** Each finding carries `introduced`. The aggregator
   counts only introduced findings toward merge readiness and lists the rest
   under `pre_existing`; a finding that does not say is counted.
4. **The repository's rules, as a reviewer.** `review-lens` declares
   `prompt.repo_rules`; a non-writer's rules block reads "a change that breaks
   one is a finding", and the rules file's "Facts reviewers need" section states
   what is trusted (e.g. engine-set `ZBUILD_*`).
5. **Scope lens.** Planned-but-untouched files are not findings (the plan lists
   files that might change); edits beyond what the issue asked for are.
6. **No self-echo.** A lens is no longer shown its own previous review, as no
   judging stage is (ADR-055 amendment, #2212).

#1654's live acceptance (a real lens catching a sibling-function inconsistency,
and the wall-clock before/after) is verified on the next pipeline run, not in
unit tests, which stub the model.

Verification: `plugins/agent/review-lens/tests/review-lens-context-unit-test.sh` (C1–C9).

## Amendment (2026-10-05): the planned scope is design's scope block (#2302)

**Evidence.** On #2035 every lens prompt's "THE PLANNED SCOPE" section read
`+ ./`. It was filled from the `scope_manifest` input, which is the redaction
allow-list, not the plan, so the scope lens had no file list to compare the
change against.

**Decision.** The planned scope given to a lens (item 1 of the 2026-09-28
amendment) is the files listed in the design's ```` ```scope ```` block, read
with `acceptance_list_scope` (`scripts/lib/acceptance-block.sh`), the same list
build is given. The `scope_manifest` input is not shown to a lens. A design
with no scope block gives no planned-scope section.

Verification: `plugins/agent/review-lens/tests/review-lens-context-unit-test.sh`
(C12; C3 now reads the scope block too).

## Amendment (2026-10-05): every lens compares the change with the issue (#2307)

**Evidence.** Every lens prompt carries "THE ISSUE (what was asked for)", but no
charter asked whether the change delivers it: `scope` looks only for over-reach,
`correctness` and `red-team` look at logic and attacks, and `design-conformance`
is not in the default template and compares against the design. No lens flagged
that PR #2298 skipped the loop expansion, the red step and the negative control
its issue asked for.

**Decision.** Every lens compares the change with the issue and names any part
of the issue the change does not deliver, in its own terms, as a finding. The
instruction is written once, in the prompt builder (`_rl_build_lens_prompt`,
`plugins/agent/review-lens/lib/charters.sh`), so it reaches every lens whether
its charter comes from a persona manifest or the built-in fallback; no charter
repeats it.

Verification: `plugins/agent/review-lens/tests/review-lens-context-unit-test.sh`
(C13: for each lens in `config/templates/simple.yaml`'s `review_lenses`, the
prompt the plugin sends carries the instruction).
