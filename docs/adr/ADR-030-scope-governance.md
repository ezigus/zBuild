# ADR-030 — Scope model (read/write split, security floor, governed expansion)

**Status:** Proposed (2026-06-13)
**Related:** ADR-002 (legacy freeze), ADR-004 (redaction chokepoint), ADR-021 (cycle semantics), ADR-026 (review-remediation cycle), ADR-027 (recursive-flow template)
**Issue:** #840

## Context

Dogfood `20260612173055-58001` (A2 compound-quality migration) ran **4h12m and failed**, having produced a *correct* implementation it was structurally forbidden to finish. `build` discovered the exact fix (test files pinning the old stage count `"8"` after the change made it `12`), diagnosed it **six times**, and was blocked every time because those files were outside `plan.files[]`. The scope guard reverted every out-of-scope edit; the `build_test_cycle` had no exit for "structurally blocked" and looped to `max_iterations` — twice — plus ~45 min of identical-prompt router timeouts.

The root flaw: **write-scope is a prediction** made by plan/impact/design *before the implementation exists*, then frozen as inviolable against `build` — the first actor in the pipeline with **ground truth** (it ran the tests, saw which files broke). Freezing a guess against the party holding measured reality guarantees this wall is hit at some nonzero frequency forever. CLAUDE.md already names the symptom: "a missed file causes build-loop failures that can't be fixed within the plan's scope enforcement."

A second, quieter flaw: the scope manifest conflates three distinct boundaries into one frozen list — what the LLM may **read** (a security/redaction concern), what the implementation may **write** (the thing that trapped the run), and how big the diff may get (review blast-radius).

## Decision

Separate read-scope from write-scope, and make write-scope **negotiable through a governed channel** with a guaranteed cycle exit. Three layers, each owning one concern; discipline is about which layer owns what.

### Layer 1 — Security floor (core, hardcoded, NOT template-expressible)

A write-scope deny-list enforced as a **single chokepoint** (`scripts/lib/scope-governance.sh:scope_floor_denied`) that EVERY write-scope grant — from plan, design, build-expansion, or a re-plan escalation — must pass through. ADR-004 "no exceptions" discipline extended from reads to writes.

Floor (always denied, regardless of any policy or class):
- `legacy/*` — frozen upstream (ADR-002); only the migration prune protocol writes here, never build.
- Secrets — `.env`, `*secret*`, `*credential*`, `*.pem`/`*.key`/`*.p12`/`*.pfx`.
- Out-of-repo — absolute paths, `../` escapes.

The floor is **not** in the template. A template cannot widen it; it can only ever be *more permissive within* it. This is the invariant that makes the rest safe to declare in data.

### Layer 2 — Policy (declarative, template, closed enum — NOT logic)

A `scope_policy` block on a cycle, mirroring how `exit_when` declares `{stage,field,op,value}` from a closed vocabulary:

```yaml
build_test_cycle:
  type: cycle
  scope_policy:
    expandable: true
    auto_grant: [collateral_tests, collateral_config, collateral_docs]
    escalate:   structural        # core/, scripts/lib/, plugin source → re-plan
    on_deny:    abandon           # → blocked_on_scope terminal
```

The template **names** behaviors from a closed class set `{collateral_tests, collateral_config, collateral_docs, structural}`; core **defines** what each name means. No predicate, regex, or condition is expressible in YAML — that would be an inner-platform DSL. **Omitted `scope_policy` ⇒ `expandable: false` ⇒ requests denied ⇒ clean abandon.** Opt-in; existing templates are unchanged except a structurally-blocked cycle now *exits cleanly* instead of looping.

`scope_policy` composes under ADR-027 recursive nesting exactly like `exit_when` — an inner and outer cycle each carry their own.

### Layer 3 — Mechanism (code — detectors + resolver + orchestrator)

- **Build always asks.** When a needed fix lies outside write-scope, build emits a structured `scope_expansion_request {files:[{path,category,evidence,reason}]}` alongside its in-scope diff, and does NOT touch the out-of-scope file that iteration (keeps the diff clean and reviewable). This replaces today's silent revert-to-empty-diff.
- **Evidence, not blind trust.** Each requested file carries `evidence` — a literal token (e.g. the old constant `"8 stages"`) that links it to the change. The resolver verifies the token actually appears in the file (`scope_evidence_present`). Build cannot expand scope to an arbitrary file by asserting relevance; it must point at real evidence.
- **Collateral class by path-shape** (`scope_collateral_class`): a pure mapping from path to one closed class. `tests/*`/`*.golden` → `collateral_tests`; `config/*`/`*.json` → `collateral_config`; `docs/*`/`*.md` → `collateral_docs`; everything else → `structural`.
- **Resolver** (`scope_resolve_request`, pure): per-file disposition aggregated conservatively → `{action: grant|escalate|deny, granted[], denied[], reason}`:
  - floor hit → deny (hard).
  - structural + `escalate: structural` → escalate; else deny.
  - collateral class enabled in `auto_grant` AND evidence present → grant; else deny.
  - any file denies → overall deny (build re-requests a cleaner set); else any escalate → escalate; else grant all.
- **Orchestrator resolves between iterations** and **guarantees an exit**:
  - **grant** → widen write-scope for the cycle (synthetic `prior_scope_grant` feedback so the next build iter sees it), continue.
  - **escalate** → bounded re-plan on the delta (v1: surface + abandon with reason; full re-plan mini-cycle is a follow-up).
  - **deny** (default / floor / class disabled) → terminate `terminated_reason=blocked_on_scope`, naming the files. **Never a loop.**

### Review assertion-integrity

Letting build expand into test files opens one hazard: a build could pass a red test by *weakening its assertions*. So `review` gains a charter — when the diff contains scope-expanded test edits, verify no assertion was weakened or deleted to go green. This is the lightweight precursor to the behavioral/TDD deliverable (ADR-031, #843), which makes test-first the contract.

## Consequences

- **The catastrophic loop is removed.** A structurally-blocked cycle exits in one iteration (`blocked_on_scope`) instead of grinding to `max_iterations`. This holds even with expansion disabled — the default is *cleaner failure*, not new permission.
- **Scope authority moves toward ground truth.** Plan/impact/design still produce a *proposed* write-scope (improved separately by #841/#842); build can correct it within governed bounds. Prevention (better upfront scope) and recovery (governed expansion) are complementary — neither alone suffices.
- **Security is strictly preserved.** Read-scope and the floor are unchanged in spirit and unweakened by the declarative layer; the floor is the one chokepoint every grant crosses.
- **Stage-agnostic.** The request/resolve mechanism is not build-specific — any agent-loop stage that mutates files under scope (future: cq-cycle, cq-backtrack) inherits it.

## Implementation Notes

Delivered in tested increments under #840:
- **R1 (this ADR + `scripts/lib/scope-governance.sh` + unit tests):** the pure floor/detector/resolver core. No runtime-behavior change — nothing consumes it yet, so existing pipelines are untouched.
- **R2:** template `scope_policy` parsing (`core/pipeline/template.sh`, both awk passes, `_TPL_CYCLE_SCOPE_*`), orchestrator resolver + `blocked_on_scope` terminal, build `scope_expansion_request` emission + grant merge, `standard.yaml` opt-in.
- **R3:** review assertion-integrity charter.

## Amendment v1 (2026-06-14, #870) — build-created collateral, terminal abandon, anchored classification

Dogfood `20260614104212-56566` (#862) looped on a *correct* change: the build legitimately created a new `tests/golden/*.golden`, but it never reached the (working) auto-grant machinery — the build only emitted a `scope_expansion_request` for files named in *test feedback* (an edited old-value file), never for a file it *created* this iteration. With no request, the resolver returned `none`, the cycle had no terminal signal, and it ground to `max_iterations`. Three corrections, all completing the existing #840 contract:

- **(a) Build-created collateral is auto-grantable (amends Layer 3).** The Layer-3 evidence rule (`scope_evidence_present`: a literal token already in the file) only fits a file the build is *editing*. A file the build *creates* (a regenerated golden, a new fixture/config the change produces) has no pre-existing token. Such a request carries `created: true`; the resolver grants it on **floor-pass + collateral class + class-enabled**, with the file's existence on disk as the basis (no token required). The floor and structural checks still run first, so `created` can never grant a floored or source-tree path. Build emits these via `_build_created_collateral_request` on the `scope_violation` verdict path (previously a silent fail-close).
- **(b) `blocked_on_scope` is terminal — visited exactly once.** When the resolver denies, the cycle abandons with `terminated_reason=blocked_on_scope` and is NOT re-entered by `max_iterations`; an enclosing cycle treats it as completed-abandoned, never as a re-iteration trigger. Looping on `blocked_on_scope` is a defect. (The R2 wiring already made rc=7 terminal; the #862 loop came from *no request being emitted*, not from rc=7 mishandling — fixed by (a).)
- **(c) Collateral classification is directory-anchored (security).** `scope_collateral_class` previously matched `*.json`/`*.golden`/`*.md` *anywhere*, so `core/router/models.json` self-classified as `collateral_config` and was auto-grantable. Collateral now requires the matching directory prefix (`config/*`, `tests/*`, `docs/*`); `core/`, `scripts/`, `plugins/` are `structural` regardless of extension. The security floor is unchanged.
