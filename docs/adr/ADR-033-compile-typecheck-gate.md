# ADR-033 — Two-layer absence-collateral catching: compile/typecheck gate for typed targets

**Status:** Proposed — design only, implementation deferred (2026-06-13)
**Related:** ADR-032 (per-repo prompt overrides), ADR-030 (scope governance), ADR-013 (canonical stage list), ADR-012 (test tiering)
**Issue:** #856 (OV-3); follows #854 (OV-1) and #855 (OV-2)

## Context

The #755 dogfood exposed **absence-collateral (Class-2)**: a change grows a closed set (e.g. adds a pipeline stage) and an *exhaustive enumeration* of that set breaks by **omission** — with no stale token to grep, because the breakage is the *missing* line. OV-1/OV-2 (ADR-032) address this at the **prompt layer**: a generic "find enumerations of a growing set" charter plus per-repo overlays that name the concrete enumeration patterns (for zBuild: mock-plugin rosters / stage counts).

But the prompt layer is a *heuristic* — it asks an LLM to find the enumerations by pattern. For **compiled / statically-typed targets** there is a far more reliable, deterministic catcher: the **type-checker itself**. `tsc --noEmit`, `kotlinc -Werror`, `swift build`, `go vet`, `cargo check` surface an omitted enum case, a non-exhaustive `when`/`switch`, or a missing protocol conformance in seconds, with exact `file:line` — no heuristic, no missed site. This generalizes across web (TypeScript), Android (Kotlin), and iOS (Swift) — exactly zBuild's target set.

This ADR records the **two-layer model** so the prompt-layer fix (OV-1/OV-2) and the eventual compiler-layer fix are coherent and non-overlapping. **No code lands in this issue** — implementation belongs after a typed target is actually being built.

## Decision (design intent — to be implemented later)

Adopt a **two-layer model** for catching absence-collateral, with the layer chosen by what the target language supports:

1. **Prompt layer (shipped, OV-1/OV-2).** Generic enumerated-set charter + per-repo overlay. The only available catcher for **untyped/interpreted** targets (bash, Python, Ruby) where there is no compiler to enumerate exhaustiveness. zBuild self-hosting (bash) lives here.

2. **Compiler/typecheck layer (deferred, this ADR).** For **typed** targets, a pluggable gate runs the target's type-checker and treats *new* errors as a hard fail, feeding exact `file:line` back into `build_test_cycle`. Target-agnostic contract: the engine knows "run the configured typecheck command; parse errors to `file:line`; fail on new errors." The **command** is per-repo config/override (same generic-engine + per-repo-specifics split as ADR-032) — e.g.:
   - TypeScript: `tsc --noEmit`
   - Kotlin/Android: `kotlinc -Werror` (or the Gradle `compileDebugKotlin` task)
   - Swift/iOS: `swift build` / `xcodebuild`
   - Go: `go vet ./...`; Rust: `cargo check`
   For an **untyped** target (bash self-hosting), the gate is a **no-op** (or shellcheck-only) — which is precisely *why* bash repos must rely on the OV-1/OV-2 prompt-layer overlay, and typed targets get the stronger compiler guarantee.

### Where it wires

Likely `cq-preflight` (already runs shellcheck / bash-compat and a coverage floor — ADR-013 compound_quality) gains a "typecheck" pre-flight check driven by the per-repo command, OR a distinct gate stage is added. To be decided in the implementation design; both keep the engine target-agnostic (command comes from per-repo config).

## Consequences

**Positive.** Typed targets get a *deterministic* absence-collateral catcher that the prompt heuristic can only approximate. The two layers compose: prompt-layer overlay for discovery/scope + compiler gate for verification. The generic-engine + per-repo-command split mirrors ADR-032, so no target vocabulary enters the engine.

**Negative / deferred.** Not implemented here — premature without a real typed target to validate against. Running a full type-check per cycle iteration has a latency cost (mitigable by incremental/targeted checks). The per-repo command is operator-trusted (it runs in the build environment) — it must inherit the same execution-isolation posture as other build commands.

**Why deferred, not done now.** zBuild currently self-hosts on bash, where this gate is a no-op; there is nothing to exercise it. Building it now would be speculative. This ADR fixes the design so OV-1/OV-2 and the future gate stay coherent.

## Implementation Notes (deferred — #856)

No code in this issue (per its acceptance criteria). When a typed target is onboarded:
- Add a per-repo typecheck command to repo config (or a `.zbuild/` overlay), defaulting to none (no-op) so bash/untyped repos are unaffected.
- Implement the gate (in `cq-preflight` or a new stage): run the command, parse `file:line` diagnostics, fail `build_test_cycle` on *new* errors, feed locations back as structured feedback.
- Behavioral tests per supported language (a fixture project with an omitted enum case → gate fails with the exact location; a clean project → gate passes).
- File a follow-up implementation issue at that time; this ADR is the design anchor.
