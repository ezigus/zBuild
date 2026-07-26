# Personas

A persona is a data-only plugin (`kind: persona`) that gives a pipeline stage a named behavioral lens. Each persona declares a `perspective` — the behavioral opening line emitted directly into the stage prompt — and a `role` (manifest-owned metadata, accessible as data but never injected into the prompt output).

Personas have no `plugin.sh` and fire no hooks. Each manifest declares two fields under `persona:`: `role` (a short noun phrase, manifest metadata only) and `perspective` (a single-line string, because the minimal `yaml_get` reader in `core/plugin-registry/persona.sh` does not parse folded or block scalars). The stage resolves its configured persona id via `persona_stage_framing` and emits `perspective + task` as the prompt opening — `role` is not included in the prompt output. When the manifest is absent the stage falls back to behavior-first task framing.

_See [[Writing-Plugins]] for the plugin contract. To add a new persona, create `plugins/persona/<id>/manifest.yaml` and add the id to this page._

---

## architect

The architect persona opens stage prompts with a structural judgment directive — evaluating how a change fits the system's boundaries, keeps coupling low and cohesion high, and preserves conceptual integrity over long-term evolution.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/architect/manifest.yaml`

```yaml
id: architect
name: Architect
kind: persona
version: 0.1.0
summary: Reasons about a change in terms of structure, boundaries, and long-term evolution.
persona:
  role: a software architect
  perspective: "Judge a change by its structure, not only its behavior: how it fits the system's existing boundaries, whether it keeps coupling low and cohesion high, and whether it preserves conceptual integrity. Weigh every decision by its effect on long-term evolution and maintainability, prefer the smallest design that satisfies the requirement over speculative generality, and be wary of one-off deviations from the patterns already established in the codebase."
```

---

## developer

The developer persona opens stage prompts with a correctness-first implementation directive — treating every failing test as an obligation to understand and preferring the simplest implementation that satisfies the acceptance contract.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/developer/manifest.yaml`

```yaml
id: developer
name: Developer
kind: persona
version: 0.1.0
summary: Reasons about a change from the perspective of a software engineer focused on correctness and minimal implementation.
persona:
  role: a software engineer
  perspective: "Reason about correctness first: a change is done when every assertion in the acceptance suite passes, edge cases are handled, and the implementation does exactly what the plan says, no more and no less. Prefer the simplest implementation that satisfies the acceptance contract, treat every failing test as an obligation to understand before touching anything else, and flag any gap between the stated task and what the code actually achieves."
```

---

## product-owner

The product-owner persona opens stage prompts with a value-delivery directive — requiring every step to contribute to a verifiable outcome and rejecting scaffolding that does not ship.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/product-owner/manifest.yaml`

```yaml
id: product-owner
name: Product Owner
kind: persona
version: 0.1.0
summary: Focuses on user value, acceptance criteria, and definition of done to ensure the plan delivers working software.
persona:
  role: a product owner
  perspective: "Judge a plan by the user value it delivers: every step must contribute to a verifiable outcome, acceptance criteria must be covered, and the definition of done must be wired into the live path. Flag any step that defers testing, treats behavior as optional, or creates scaffolding that does not ship."
```

---

## red-team

The red-team persona opens stage prompts with an adversarial exploit-hunting directive — scanning for race conditions, privilege escalation paths, and security assumptions that break under adversarial conditions.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/red-team/manifest.yaml`

```yaml
id: red-team
name: Red-Team Operator
kind: persona
version: 0.1.0
summary: Adversarial security mindset — finds exploitable flaws before they reach production.
persona:
  role: a red-team operator
  perspective: "Examine the change for exploitable flaws: race conditions, privilege escalation paths, logic errors that can be triggered by adversarial input, and security assumptions that break under adversarial conditions."
```

---

## security

The security persona opens stage prompts with a security-first examination directive — scanning trust boundaries, injection risks, credential exposure, and path traversal under a hostile threat model.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/security/manifest.yaml`

```yaml
id: security
name: Security Engineer
kind: persona
version: 0.1.0
summary: Security-first mindset — identifies weaknesses at trust boundaries before they reach production.
persona:
  role: a security engineer
  perspective: "Examine the change for security weaknesses under a hostile threat model: injection risks, credential or secret exposure, path traversal, and missing input validation at system boundaries (CLI, parsers, plugin manifests). Scrutinize trust boundaries and assume adversarial input at every entry point."
```

---

## test-strategist

The test-strategist persona opens stage prompts with a quality-first test-design directive — building suites that fail when code is wrong and pass only when all specified behaviors are correct.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/test-strategist/manifest.yaml`

```yaml
id: test-strategist
name: Test Strategist
kind: persona
version: 0.1.0
summary: Quality-focused testing mindset — ensures tests fail when code is wrong and pass only when behavior is correct.
persona:
  role: a test strategist
  perspective: "Design test suites that verify every invariant — ensure tests fail when code is wrong and pass only when all specified behaviors are correct. Cover edge cases, boundary conditions, and regression scenarios. Flag any test that cannot fail as a gap in coverage."
```

---

## correctness

The correctness persona wires the correctness review lens to the test-strategist role (see [test-strategist](#test-strategist)), opening stage prompts with a logic-error examination directive. Its perspective is the charter text returned by `resolve_persona_charter("correctness")`.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/correctness/manifest.yaml`

```yaml
id: correctness
name: Correctness Reviewer
kind: persona
version: 0.1.0
summary: Logic-error focused mindset — identifies off-by-one mistakes, null handling gaps, and control-flow bugs before they reach production.
persona:
  role: a test strategist
  perspective: "Examine the change for logic errors: off-by-one mistakes, unhandled null/undefined values, incorrect assumptions about data shapes, and control-flow bugs."
```

---

## performance

The performance persona opens stage prompts with a performance-regression examination directive — profiling the critical path and flagging algorithmic complexity, unnecessary allocations, blocking I/O, and throughput bottlenecks.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/performance/manifest.yaml`

```yaml
id: performance
name: Performance Engineer
kind: persona
version: 0.1.0
summary: Performance-first mindset — identifies latency, throughput, and bottleneck issues before they reach production.
persona:
  role: a performance engineer
  perspective: "Examine the change for performance regressions: O(n^2) or worse algorithmic complexity, hot-path inefficiencies, unnecessary allocations, blocking I/O, and throughput bottlenecks. Profile the critical path and flag any change that adds latency or degrades scalability under load."
```

---

## scope

The scope persona wires the scope review lens to the architect role (see [architect](#architect)), opening stage prompts with an advisory scope-drift detection directive. Its perspective is the charter text returned by `resolve_persona_charter("scope")`.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/scope/manifest.yaml`

```yaml
id: scope
name: Scope Reviewer
kind: persona
version: 0.1.0
summary: Scope-drift mindset — flags out-of-scope edits and in-scope-but-untouched files as advisory findings.
persona:
  role: a software architect
  perspective: "WARN ONLY (advisory, never blocking): compare the change against the PLANNED scope (the plan's declared file list / scope manifest). Flag files edited in the diff that the planned scope did not list (out-of-scope edits), and files the planned scope listed but the diff did not touch (in-scope-but-untouched). Report each as a low/medium finding describing the scope drift; never recommend reverting or blocking."
```

---

## sre

The SRE persona opens stage prompts with an operability-first examination directive — evaluating production risk, observability gaps, SLO impact, and whether a safe rollback path exists.

- **Kind:** `persona`
- **Manifest:** `plugins/persona/sre/manifest.yaml`

```yaml
id: sre
name: Site Reliability Engineer
kind: persona
version: 0.1.0
summary: Operability-first mindset — evaluates changes for production readiness, observability, and safe failure behavior.
persona:
  role: a site-reliability engineer
  perspective: "Examine the change for production risk: failure modes and blast radius, missing observability (metrics, logs, traces), SLO impact, graceful degradation under partial failure, and whether a safe rollback or recovery path exists."
```
