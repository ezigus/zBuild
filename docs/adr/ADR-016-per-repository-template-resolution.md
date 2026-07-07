# ADR-016: Per-Repository Template Resolution

**Status:** Proposed (2026-06-02)
**Date:** 2026-06-02
**Depends on:** ADR-013 amendment (PR #657 — taxonomy-only scope clarification)
**Implements (forthcoming):** #653 (resolver), #654 (events), #655 (CLI flag), #656 (docs + dogfood). Umbrella: #447.

## Context

Today, zBuild loads its pipeline template from a fixed location:
`config/templates/<id>.yaml`. The only operator surface is the `--template
<id>` CLI flag, which selects between shipped ids (`standard`,
`security-audit`, etc.). There is no supported way for an operator to
customize the pipeline shape (stage list, cycle membership, per-stage
roles, io destinations, gate policy) for one repository without forking
the zBuild source tree.

The legacy import shipped a single hardcoded stage sequence; ADR-013 moved
that sequence into `config/templates/standard.yaml` as data, and ADR-021
v2 (#585) made cycles a first-class template construct. The remaining gap
is per-repository overrides: a repo that wants `[intake, build, test,
review]` (no design / compound_quality / deploy / validate / monitor) has
to either ship a new shipped template upstream or carry a local patch.

Three forces drive this ADR now:

1. **#447 (review-stage feedback loop)** needs to dogfood a non-standard
   pipeline shape on the zBuild repo itself without touching `config/`.
2. **ADR-021 v2 cycles** (`type: cycle` inline + `stage_definitions:`)
   are a structural realization of the template, not a textual overlay,
   so any override mechanism must compose with the v2 expansion.
3. **ADR-006 resume contract** requires that resume read exactly the
   template that the original run started under — not whatever happens
   to be on disk at resume time. Per-repo overrides multiply the ways an
   operator could accidentally edit the template mid-run.

This ADR fixes the resolution mechanism, the event surface, and the
resume invariant. It does not ship code.

## Decision factors

| Factor                       | Weight    | Notes |
|------------------------------|-----------|-------|
| Resume safety                | Mandatory | A mid-run edit to the override file must not silently change behavior on resume. |
| Backwards compatibility      | Mandatory | Repos with no `.zbuild/templates/` see byte-identical behavior. |
| Composability with ADR-021   | Mandatory | Overrides apply BEFORE cycle expansion; canonical-id validation (ADR-013) runs AFTER. |
| Composability with ADR-020   | Mandatory | Contract validator runs against the fully resolved template, never a partial. |
| `$HOME` / path leak posture  | Mandatory | Events forwarded to GitHub comments MUST NOT carry absolute paths. |
| Operator simplicity          | Important | One file per override, one CLI flag for arbitrary paths. No new env-var surface. |
| Forward compatibility        | Important | Diff event must not hardcode the canonical stage list — future shipped templates are first-class. |

## Decision

The runner gains a per-repository template resolution layer with six
decision locks:

1. **Search path order.** The resolver tries
   `.zbuild/templates/<id>.yaml` (repo-local override) first, then falls
   back to `config/templates/<id>.yaml` (shipped). Full replace: there is
   no field-level merge with the shipped file. The override's `extends:`
   (lock 2) is the only mechanism for composition.

2. **`extends:` is REQUIRED in every per-repo override.** A per-repo
   template file MUST declare `extends: <shipped-template-id>` at top
   level. `extends:` resolves only to shipped template ids — never to a
   file path, never to another override, never to a URL. Depth is
   **exactly 1**: multi-hop chains (override → override → shipped) are
   out of scope and refused at load time. (Q1) `extends_chain` in the
   resolved event is always a single-element array, leaving room for a
   future multi-hop design without re-shaping the event. (Q6) When
   `extends:` does not resolve, the resolver hard-fails at template-load
   time with a structured error — parity with ADR-013's canonical-stage
   validation (`core/pipeline/template.sh:64`).

3. **No hardcoded canonical omission.** The diff between override and
   base is computed against the **resolved base template** that
   `extends:` points to, NOT against ADR-013's canonical list. This
   keeps the diff event forward-compatible with future shipped
   templates (e.g., a hypothetical `issue-creation` template) and
   avoids re-emitting "missing canonical stage X" noise that ADR-013's
   subtractive-composition rule already permits. (F3) The diff is
   computed against the **post-cycle-expansion flat stage list** per
   ADR-021 v2's `_TPL_STAGES[]` semantics — not against raw `type:
   cycle` entries — so a base template that declares a `build_test`
   cycle and an override that inlines `build, test` linearly produces
   the diff the operator expects (cycle removed, two linear stages
   added is rendered as "cycle membership change", not as a stage
   addition).

4. **`pipeline.template.resolved` event.** Emitted exactly once per
   pipeline run, emitted unconditionally after the snapshot step,
   regardless of whether the canonical-ID validation (step 7) or
   contract validation (step 8) succeed. Validation failures cause the
   runner to abort *after* the events fire — operators retain
   diagnostic signal. Payload:

   ```
   pipeline.template.resolved
     template_id       (string)            — the id requested by --template, or "standard" default
     source            (enum)              — local | shipped | cli
     path              (string)            — repo-relative (e.g. ".zbuild/templates/foo.yaml")
                                              or, when source=cli, the basename of the supplied file
     extends_chain     (array<string>)     — single-element array, e.g. ["standard"]; [] for shipped-only
     resolved_stages   (array<string>)     — flat _TPL_STAGES[] in canonical order, post-cycle-expansion
   ```

   (Q5) This event ALWAYS fires, including for shipped-only runs
   (`source=shipped`, `extends_chain=[]`). The diff event (lock 5) is
   the conditional one. (C2) The `path` field is repo-relative for
   `source∈{local,shipped}`, basename-only for `source=cli`. The
   absolute path NEVER appears in this event — it would leak `$HOME`
   into GitHub comments when the event is forwarded.

5. **`pipeline.template.diff_from_base` event.** Emitted ONLY when
   `source∈{local,cli}` AND the resolved template differs from its
   `extends:` base. Informational, non-blocking: the runner does not
   gate on this event. Payload:

   ```
   pipeline.template.diff_from_base
     base_template_id            (string)            — the shipped id from extends:
     stages_in_base_not_in_override  (array<string>) — removed canonical ids
     stages_added                (array<string>)     — added canonical ids (must still be ADR-013 members)
   ```

   (Q2) The diff event is scoped to **stage-level add/remove only**.
   Attribute-level modification detection (per-stage `io.destinations`,
   `roles`, etc.) is deferred to a future ADR if it's ever needed.

   The diff event fires **even when downstream validation
   (ADR-013 canonical-id check, ADR-020 contract validator) ultimately
   fails** later in the resolver pipeline (see step order). The
   informational signal is preserved regardless of whether the run
   proceeds — operators dogfooding an override want to see the diff
   even when their override has a typo.

6. **CLI flag `--template <path-to-file>`** for arbitrary-path
   overrides. When the argument contains a `/` or ends with `.yaml`, it
   is treated as a file path (`source=cli`); otherwise it is treated as
   a shipped/local id (current behavior). The same resolver rules apply
   to a CLI file: `extends:` is REQUIRED, depth is 1, and the file is
   snapshotted at run start (see Resume contract below). (Q3) There is
   NO env-var surface for templates. `--template` is the sole non-
   default entrypoint. (Q4) Exact argv-parsing details (positional vs
   `=` form, conflict with `-t`, etc.) are an implementation detail of
   #655 and not pinned here.

### Resolver step order

The resolver runs these steps **in this exact order**. The order is
load-bearing: every step's input is a downstream step's invariant.

```
1.  locate         — apply lock 1 search order; for CLI, take the supplied path verbatim
2.  load           — parse YAML (current AWK-based parser in core/pipeline/template.sh)
3.  validate       — check that `extends:` is present (lock 2) when source ∈ {local, cli};
                     refuse multi-hop (extends-target's extends is non-null) at this step
4.  load_base      — load the shipped base referenced by extends: (single hop, lock 2)
5.  overlay        — full-replace overlay of override onto base (lock 1 semantics);
                     stage_definitions: from override REPLACE the base entry for that stage id,
                     NOT field-level merge — to avoid silent half-merges of cycle members
6.  flatten_cycles — apply ADR-021 v2 cycle expansion to produce _TPL_STAGES[] flat list
7.  validate_ids   — ADR-013 canonical-id + canonical-order check against _TPL_STAGES[];
                     CAPTURE the result, do NOT abort yet
8.  validate_adr020— ADR-020 contract validator runs against the fully resolved template;
                     CAPTURE the result, do NOT abort yet
9.  snapshot       — write state/artifacts/template.resolved.yaml (resume invariant; see below)
10. emit_resolved  — emit pipeline.template.resolved (lock 4) unconditionally
11. emit_diff      — if source ∈ {local, cli}, emit pipeline.template.diff_from_base (lock 5)
                     unconditionally on the captured resolved shape
12. honor_validation — if either captured validation result (step 7 or 8) failed,
                     the runner aborts here with the original validation error.
                     Otherwise, dispatch proceeds.
```

Validation results from steps 7 and 8 are captured but do NOT
short-circuit until step 12. Events 10 (resolved) and 11 (diff, when
applicable) fire unconditionally on the captured resolved shape, then
step 12 honors any validation failures and aborts. This ordering is
load-bearing: an operator with a broken override still wants to see
the structural diff in their dogfood log before the abort. Steps 10
and 11 only depend on having a resolved (post-overlay, post-flatten)
shape AND a base for comparison; both are produced regardless of
validation success.

(B2) Pinning this order resolves the open question of where ADR-020
validation slots relative to cycle flattening. Validation runs AFTER
flattening because ADR-020 walks `_TPL_STAGES[]`, which is the
post-flatten contract. The snapshot is written before the validation
abort (step 12) so that the resolved shape is available to the
emitted events — but because the runner aborts at step 12 on
validation failure, no stage dispatch ever consults a snapshot of a
broken template. A snapshot of a failed-validation template is a
diagnostic artifact, not an invitation to resume.

### Resume contract (B1 — BLOCKING)

The fully resolved template — post-extends, post-overlay, post-cycle-
flatten — is **snapshotted at run start** to
`state/artifacts/template.resolved.yaml` (canonical path; the exact
filename is fixed by this ADR for the resume invariant). The snapshot
is written by step 9 of the resolver via `atomic_write`.

Resume reads the **snapshot**, not the override file on disk:

- A mid-run edit to `.zbuild/templates/<id>.yaml` after the original
  start MUST NOT change pipeline behavior on resume. The snapshot is
  the source of truth.
- (C3) When `--template` is passed on resume:
  - If the supplied template's `template_id` DISAGREES with the
    snapshot's `template_id`, the resolver refuses with a clear error
    (`pipeline.resume.template_mismatch`). Resume aborts.
  - If the supplied template AGREES on `template_id` but differs in
    content, the resolver **warns** (`pipeline.resume.template_drift`)
    and proceeds using the snapshot. The flag is logged for forensics
    but does not change behavior.
  - The simplest case (resume with no `--template` flag) reads the
    snapshot silently.

**Follow-up obligation.** Persisting `template.resolved.yaml` requires
adding it to the persisted-state table in ADR-006. This ADR does NOT
write the ADR-006 amendment text. The impl PR (#653) is responsible for
landing the ADR-006 amendment in the same PR that ships the resolver,
so the snapshot path is documented in both ADRs simultaneously.

### Backward compatibility (F2)

When neither `.zbuild/templates/<id>.yaml` nor a CLI file path is
supplied:

- The resolver's first stat-miss on `.zbuild/templates/<id>.yaml` is
  **silent in operator chatter**: no warn line, no info line. The repo
  without an override is the overwhelming default case and must not be
  polluted by resolver chatter. The `pipeline.template.resolved` event
  still fires as normal (per lock 4's "ALWAYS fires" requirement), with
  `source: shipped` and `extends_chain: []`.
- The resolver falls through to `config/templates/<id>.yaml` (shipped),
  emits `pipeline.template.resolved source=shipped extends_chain=[]`,
  and does NOT emit the diff event.

This makes the override mechanism additively-deployable: zero behavior
change for any existing run. An operator who wants to see whether their
repo has an override can grep `events.jsonl` for `source=local`.

### Safety-critical stage removal (C4 — deferred to impl)

#447 §5 raised the question of whether the engine should hardcode a
list of "safety-critical" stages that cannot be omitted by an override
(e.g., refuse a template that removes `review`). **This ADR explicitly
defers that decision.** Concretely:

- There is **no engine-side hardcoded safety-critical list** in this
  ADR or in the impl PRs (#653–#656).
- The diff event (lock 5) is informational only. The runner does not
  inspect `stages_in_base_not_in_override` and does not gate dispatch on
  its contents.
- If a future safety-critical gate is needed, it lands in a **separate
  ADR** with its own decision factors and operator escape hatch. It
  does not silently grow inside the resolver.

This kills the dangling-decision risk #447 surfaced: the current
behavior is "operator owns what they ship", and any departure from that
requires a fresh, named ADR.

### Interaction with other ADRs (F1)

- **ADR-001 scope-violation scanner** — no interaction. The scanner
  reads scope manifests, not templates.
- **ADR-004 redaction chokepoint** — no interaction. Templates are
  pipeline structure; the redaction chokepoint sits on the
  prompt/response path.

Briefly stated here so future readers don't search for absent coupling.

## Consequences

**Good:**

- Repos can customize pipeline shape without forking the zBuild source.
  The zBuild repo itself can dogfood `[intake, build, test, review]` on
  #447 without touching `config/`.
- One canonical override file per repo (`.zbuild/templates/<id>.yaml`)
  + one CLI flag (`--template <path>`) covers the persistent and
  one-shot cases. No env-var surface to drift.
- `pipeline.template.resolved` gives operators a durable record of
  exactly what shape ran. Combined with the snapshot (B1), the
  resume contract is tight: the on-disk file can be edited mid-run
  without silent behavior change.
- Diff event is forward-compatible: it diffs against whatever the
  override extends, so new shipped templates work without revising the
  diff schema.
- Repo-relative path in the event payload (C2) means
  `pipeline.template.resolved` is safe to forward verbatim to GitHub
  comments without `$HOME` leak.

**Bad:**

- One more file to look for when debugging a "why did the pipeline run
  that shape?" question. Mitigated by the `pipeline.template.resolved`
  event always firing and naming the source.
- The snapshot doubles template bytes on disk (~10-20 KiB per run).
  Negligible compared to the existing `state/artifacts/` footprint.
- `extends: REQUIRED` (lock 2) means override templates cannot be
  written ab-initio — they must always declare a base. This is
  intentional friction: an override without a base is effectively a
  fork, and forking should require touching `config/`.

**Open follow-ups (filed as separate issues post-merge):**

- **ADR-006 amendment** — add `template.resolved.yaml` to the
  persisted-state table. (Owned by impl PR #653.)
- **Resolver dogfooding on #447** — once #653 ships, the zBuild repo's
  own `.zbuild/templates/standard.yaml` carries the override that #447
  needs.
- **Impl tests (#653–#656 must cover):**
  - Resume-after-edit regression (locks B1).
  - Per-repo override that replaces a cycle member — `stage_definitions:`
    replace semantics vs would-be-merge.
  - `--template <absolute-path>` + resume after the path is deleted
    (snapshot survives, override is gone).
  - Backward-compat silence: no `info` line, no event, when neither
    override nor CLI flag is present.
  - Diff event payload shape when the override touches a cycle
    (post-cycle-expansion comparison, F3).

## Alternatives considered

- **Field-level merge with shipped template** (lock 1 alternative). A
  repo override could merge field-by-field with the shipped file
  (e.g., add an `io:` block to one stage without re-declaring the
  whole stage). Rejected: silent half-merges on cycle members
  (ADR-021 v2's `stage_definitions:`) are too easy to misread. Full
  replace + `extends:` keeps the resolved shape obvious.

- **Env-var template selection** (`ZBUILD_TEMPLATE_FILE`). Rejected
  (Q3): `--template` is sufficient, and a second non-default entrypoint
  multiplies the "why did this shape run?" surface area for no benefit.

- **No snapshot — read override file on resume.** Rejected (B1): a
  mid-run edit to the override file silently changes pipeline behavior
  on resume, breaking ADR-006's resume invariant. The snapshot is the
  only way to make resume durable without locking the file.

- **Multi-hop extends chains.** Rejected (C1): the operator value
  (composability) is small relative to the implementation surface
  (cycle detection in extends chains, depth limits, error messages for
  partial resolution). Single-hop covers the dogfood-on-shipped case
  and the one-shot CLI-file case. Multi-hop can land in a future ADR
  if a real use case emerges; `extends_chain` is shaped as an array
  (Q1) so the event schema is forward-compatible.

- **Engine-side safety-critical stage list.** Rejected for now (C4) and
  deferred to a future ADR. The current operator contract is "you own
  what you ship"; departing from that requires its own design.

## References

- [ADR-006](ADR-006-resume-contract.md) — resume contract; pending
  amendment to add `template.resolved.yaml` to the persisted-state
  table (owned by impl PR #653, NOT this ADR).
- [ADR-013](ADR-013-canonical-stage-list.md) + 2026-05-31 amendment —
  canonical stage list and `test_assessment` insertion; canonical-id
  validation runs at resolver step 7 against the flat post-cycle
  `_TPL_STAGES[]`.
- [ADR-013 amendment (PR #657)](ADR-013-canonical-stage-list.md) —
  taxonomy-only scope clarification, prerequisite for this ADR.
- [ADR-015](ADR-015-stage-io-capture.md) — precedent for shipping in
  Proposed status with a phased impl set.
- [ADR-019](ADR-019-review-fail-closed-on-test-failure.md) — review
  fail-closed gate; not coupled to the resolver but cited because the
  override mechanism is what lets #447 dogfood the gate on this repo.
- [ADR-020](ADR-020-inter-stage-data-contract.md) — pre-flight
  contract validator; runs at resolver step 8 against the fully
  resolved template.
- [ADR-021](ADR-021-pipeline-cycle-semantics.md) v2 (#585) — cycle
  declaration syntax v2 (`type: cycle` + `stage_definitions:`); the
  resolver's flatten step (resolver step 6) reuses ADR-021's expansion.
- `core/pipeline/template.sh` — current loader. The resolver layer
  sits in front of `load_template`.
- `core/pipeline/runner.sh:563` — current `template_file` derivation
  (`$_ZBUILD_ROOT/config/templates/${template}.yaml`); the resolver
  replaces this single line with a search-order helper.
- `config/templates/standard.yaml:3` — `extends: null` placeholder is
  the shipped-template marker that lock 2's "extends REQUIRED" rule
  exempts (shipped templates may have `extends: null`; overrides may
  not).
- Issue #447 — review-stage feedback loop umbrella (the use case
  driving this ADR).
- Issues #653 (resolver), #654 (events), #655 (CLI flag), #656 (docs +
  dogfood) — sequenced impl PRs.

## Implementation Notes (Proposed — 2026-06-02)

This ADR ships in **Proposed** status. No code, no test, no event-
schema changes in this PR. The status flips to **Accepted** when #653
(the resolver + snapshot + first event) lands.

The impl sequence is:

- **#653 (resolver v1)** — search-order helper in
  `core/pipeline/template.sh` (or sibling module), `extends:` load,
  single-hop refuse, full-replace overlay, ADR-021 v2 flatten,
  snapshot write to `state/artifacts/template.resolved.yaml`, ADR-006
  amendment text in the same PR. ADR-016 flips to Accepted on this
  merge.
- **#654 (events)** — `pipeline.template.resolved` and
  `pipeline.template.diff_from_base` registered in
  `config/event-schema.json::known_types`; diff computation against
  post-cycle-expansion flat list; repo-relative path normalization.
- **#655 (CLI flag)** — `--template <path>` extension in
  `core/pipeline/runner.sh`'s argv parser; resume-disagreement
  refuse-vs-warn paths.
- **#656 (docs + dogfood)** — `docs/per-repo-templates.md` operator
  guide; `.zbuild/templates/standard.yaml` shipped in this repo for
  the #447 dogfood; integration tests covering the five cases
  enumerated under "Impl tests" in Consequences.

This PR (closing #652) lands only the ADR text.

## Amendment 2026-06-05 (#705 / ADR-027) — Override semantics under the recursive flow shape

ADR-027 (Wave 17-A) replaces the parallel `stages:` + `stage_definitions:` template shape with a single recursive `flow:` plus per-stage top-level sections keyed by stage ID. This amendment updates the per-repository override semantics in §"Decision" lock 1 and the resolver step order (§"Resolver step order" step 5) to match the new shape. The six decision locks, the resume contract (B1), the diff event shape (lock 5, modulo the underlying flat-flow comparison), and the backward-compat silence rule (F2) are **otherwise unchanged**.

### `extends:` resolution under ADR-027

The lock 2 contract (`extends: REQUIRED` in every per-repo override, depth exactly 1, resolves only to shipped template IDs) is preserved verbatim. What changes is how the override's content is composed onto the base now that the base is in the ADR-027 flat-per-stage shape.

The resolver loads the base template per ADR-027 §"Loader contract" (reserved metadata extraction, stage section enumeration, cycle recursion). The override is parsed under the same rules. Then, for each **top-level key** in the override:

1. **Reserved metadata key** (a key in ADR-027's reserved set: `{id, name, extends, defaults, flow, _comment}`). The override's value REPLACES the base's value for that key wholesale. The override's `flow:` fully replaces the base's `flow:` when present.
2. **Stage section key** (any other top-level key — the stage ID). REPLACE the base's matching top-level section with the override's section. There is no field-level merge inside the stage section. A stage section present only in the override is ADDED to the merged template. A stage section present only in the base is KEPT.

This preserves lock 1's full-replace contract ("there is no field-level merge with the shipped file") at the new granularity unit: in the pre-ADR-027 shape that unit was an entry in `stages:` or an entry in `stage_definitions:`; under ADR-027 it is a top-level stage section keyed by ID. The motivating reason is the same as the original lock 1 alternative analysis: silent half-merges of cycle-member attrs are too easy to misread, and full-replace + `extends:` keeps the resolved shape obvious.

### `flow:` replacement at every depth

Under ADR-027, `flow:` exists at the top level AND inside each cycle stage's section. Override semantics apply at every depth:

- The **top-level `flow:`** is fully replaced by the override's top-level `flow:` when present (per the reserved-metadata rule above).
- A **cycle stage's inner `flow:`** is replaced as part of replacing the whole cycle stage section. When an override defines a top-level section for a cycle stage ID that exists in the base (e.g., `build_test_cycle:`), the override's entire section — including its `type:`, `flow:`, `exit_when:`, optional `abort_when:`, `max_iterations:`, `on_max:`, and `feedback:` — replaces the base's same-id section wholesale. There is no field-level merge inside a cycle stage section either.

This means an operator who wants to change a cycle's member list, exit predicate, or iteration cap restates the entire cycle section in the override. The override file is verbose but unambiguous; the resolved shape is what the file literally says.

### Resolver step order (revised step 5)

The resolver step order in §"Resolver step order" is unchanged in sequence and intent; only step 5's wording is revised to match the new shape. Step 5 now reads:

> **5. overlay** — full-replace overlay of override onto base per the ADR-027 shape: for each top-level key in the override, REPLACE the base's matching top-level key (reserved metadata OR stage section keyed by stage ID); keys present only in the override are ADDED; keys present only in the base are KEPT. No field-level merge inside stage sections or cycle stage sections — to avoid silent half-merges of cycle members.

Step 6 (`flatten_cycles`) still applies, but the flattening is now ADR-027's recursive `flow:` walk (per ADR-027 §"Loader contract" rules 4–6) rather than ADR-021 v2's `type: cycle` inline expansion. The output of step 6 is the same in shape: a flat `_TPL_STAGES[]` array used by step 7 (ADR-013 canonical-ID validation, per the ADR-013 amendment of the same date) and step 8 (ADR-020 contract validation). Steps 9–12 (snapshot, emit_resolved, emit_diff, honor_validation) are unchanged.

### Diff event under the new shape

Lock 5's `pipeline.template.diff_from_base` event continues to compute its `stages_in_base_not_in_override` and `stages_added` arrays against the **post-flatten flat stage list** (F3 in the original Decision). The flatten step's output shape is unchanged (a flat array of leaf stage IDs in canonical order), so the diff event payload is unchanged. What changes is the underlying mechanism: the resolver flattens via ADR-027's recursive `flow:` walk rather than ADR-021 v2's `type: cycle` inline expansion. The diff is still scoped to stage-level add/remove only (Q2); attribute-level modification detection remains deferred.

### Resume contract unchanged

The snapshot at `state/artifacts/template.resolved.yaml` (B1) still captures the fully resolved template post-extends, post-overlay, post-flatten. Under ADR-027 the snapshot is written in the new flat-per-stage shape. Resume reads the snapshot as before; the C3 cases (`--template` on resume with `template_id` agree/disagree) are unchanged.

### Back-compat shim window

ADR-027 §"Migration story" ships a one-release back-compat shim that accepts pre-ADR-027 templates (`stages:` + `stage_definitions:` + inline cycles) and rewrites them internally to the new shape before the runner sees them. During this shim window:

- A per-repo override file may be authored in EITHER shape. The shim normalizes both before overlay.
- An override and its base may be in DIFFERENT shapes (e.g., a pre-ADR-027 override extending a migrated shipped base). The shim normalizes both to the new shape, then the overlay rules above apply.
- The `template.format.deprecated` event fires per file in the old shape, surfacing in operator dashboards so any per-repo template still using the old shape is visible before the shim removal.

After the shim window closes (one tagged release after Wave 17-C lands), per-repo overrides MUST be in the ADR-027 shape; the pre-ADR-027 shape is a load-time error.

References: ADR-027 §"Decision" and §"Loader contract" (Wave 17-A), Wave 17-B (#703, template loader + validator + back-compat shim), Wave 17-C (#704, `config/templates/standard.yaml` migration + golden updates), ADR-021 v2 (cycle execution model — unchanged; only the declaration shape moves to ADR-027), ADR-013 amendment of the same date (recursive taxonomy validation at every leaf occurrence).

## Amendment 2026-07-07 (#1270) — hermetic test pattern: per-repo overlay in a TEMP repo (the #1268 `ZBUILD_TEMPLATES_DIR` seam reverted)

`#1268` had added a global `ZBUILD_TEMPLATES_DIR` env var to `resolve_template_file`
that redirected the SHIPPED-template read root. `#1270` **reverts** it: the resolver
is byte-for-byte the pre-#1268 version — the shipped read root is once again the
hardcoded `$_TEMPLATE_RESOLVER_ROOT/config/templates/` (for both the shipped path
and the `extends:` base), with no env override. `--template <id>` remains the sole
template selector; per-repo `.zbuild/templates/<id>.yaml` still wins over the
shipped dir.

The seam existed only for test-hermeticity, and that need is met by the EXISTING
generic per-repo overlay mechanism this ADR defines — no engine change required.
The hermetic test pattern (now the standard for subprocess-invoking tests):

- Create a throwaway temp repo (`setup_git_temp_repo`, or any temp dir).
- Install the fixture as a per-repo overlay: `install_template_overlay <repo> <id>`
  copies `tests/fixtures/templates/<id>.yaml` → `<repo>/.zbuild/templates/<id>.yaml`
  (the fixture carries `extends: <shipped-base>`, usually `simple`).
- Run the engine with **CWD = that repo** — `runner.sh` passes `$PWD` as the
  resolver's `repo_root`, so the overlay resolves from the temp repo and the
  tracked `config/templates/` is never touched (reaped by the master trap).
- When the runner (or a nested runner) rsyncs the repo then `git checkout HEAD --
  . && git clean -fdq` (e.g. the test stage's staging copy), the overlay must be
  COMMITTED into the repo's HEAD so it survives the clean — use
  `install_template_overlay_committed`.

A static guard (`tests/unit/templates-dir-hermeticity-test.sh`) enforces that no
test writes a fixture into the REAL repo's `config/templates/` OR `.zbuild/templates/`.
