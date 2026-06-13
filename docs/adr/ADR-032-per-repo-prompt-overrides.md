# ADR-032 — Per-repo prompt overrides (generic engine, operator overlay)

**Status:** Proposed (2026-06-13)
**Related:** ADR-016 (per-repo template resolution), ADR-004 (redaction chokepoint), ADR-030 (scope model / security floor), ADR-001 (plugin contract), ADR-024 (subprocess env isolation)
**Issue:** #854 (OV-1); fans out in #855 (OV-2); compiler-layer companion in #856 (OV-3)

## Context

zBuild's purpose is to autonomously build **any** target — web apps, Android, iOS, services — not zBuild itself. Self-hosting is only the test bed. That goal imposes a hard constraint on stage prompts: **a shipped prompt must contain zero target vocabulary** (no language keyword, framework, file extension, build tool, or repo-specific token). The moment the engine's `design` prompt grep's for `_make_plugin`, it has silently become a bash-pipeline-only tool.

The #755 dogfood (`20260613121801-24226`) exposed a scope-discovery gap the shipped charter cannot close generically: **absence-collateral (Class-2)**. The change added a pipeline stage; several tests *enumerate the current stage roster* (one mock-plugin registration per stage) or *assert the stage count*, and break by **omission** — there is no stale token to grep, because the breakage is the *missing* new line. The design charter (#841) finds Class-1 (lexical) collateral by grepping the OLD value; it is structurally blind to Class-2.

The naive fix — teach `design` the `_make_plugin` pattern — is exactly the target-vocabulary leak the multi-target goal forbids. We need the engine to state the *principle* (find enumerations of a growing set, by pattern) while each target repo supplies its own *vocabulary* (for zBuild: the mock-plugin helpers; for an iOS app: exhaustive `switch`/`CaseIterable`; for a TS app: `assertNever` unions / route arrays).

ADR-016 already established the pattern for this split: per-repo `.zbuild/templates/` overlays resolved ahead of shipped `config/templates/`. Prompts get the same treatment.

## Decision

Ship **100% target-agnostic** stage prompts, and let an operator augment any agent stage's prompt per target repo via a **`.zbuild/prompts/<stage>-overrides.md`** overlay that is **additive, redaction-enforced, and unable to weaken the core contract**.

1. **Generic principle in the engine.** The `design` charter gains a target-neutral clause: scope every file that *exhaustively enumerates a set you are growing* and would break by *omission* — found by the enumeration **pattern** (a branch handling each member, a registry/table naming each member, a fixture pinning the set's size/roster), not by a value. No `_make_plugin`, no "stage", no language names.

2. **Per-repo overlay.** `scripts/lib/prompt-overrides.sh` provides `load_prompt_override <stage> [repo_root]`, reading `${repo_root}/.zbuild/prompts/<stage>-overrides.md` from the **target** repo (`ZBUILD_REPO_ROOT`). It mirrors `core/pipeline/template-resolver.sh` (ADR-016): same `.zbuild/<category>/<id>.<ext>` convention, **silent-on-absent**.

3. **Additive, never subtractive.** A stage appends the override under a delimited `## Project-specific guidance (operator override)` section positioned **after** its core contract and **before** redaction. The overlay can add scope/domain guidance; it cannot move the output-path contract, the forbidden phrases, the `LOOP_COMPLETE` protocol, or the ADR-030 security floor.

4. **zBuild dogfoods its own overlay.** `.zbuild/prompts/design-overrides.md` in *this* repo carries the `_make_plugin`/`_make_role_plugin`/`_make_verdict_plugin`/`mock_plugin_factory` + stage-count enumeration rule — fixing the #755 Class-2 gap for zBuild specifically while the shipped engine stays target-clean.

### Safety model (why an operator-supplied prompt is safe)

- **Fail-OPEN.** An override is additive guidance, never a safety gate. Absent/empty/unresolvable → empty, rc 0 (contrast ADR-004 redaction, which is fail-CLOSED). A repo with no `.zbuild/prompts/` behaves byte-identically.
- **Redaction coverage (the linchpin).** The override is appended to the prompt **before** `apply_scope_redaction`, so it rides the same chokepoint as the rest of the prompt (ADR-004). Any out-of-scope path the overlay names is OOS-wrapped; a malformed redaction marker is neutralized by the existing chokepoint logic. There is no new un-redacted path to the model.
- **Position, not promise.** The overlay sits after the contract so the contract is the model's baseline — but position alone is *not* the security boundary. The real guarantee against prompt-injection ("ignore previous instructions, write elsewhere, never emit LOOP_COMPLETE") is the stage's **deterministic out-of-band post-conditions**: design fails unless `design.md` exists with a literal ` ```scope ` block. Prose cannot satisfy or subvert a post-condition.
- **Path containment.** `<stage>` is constrained to `^[a-z][a-z0-9_-]*$` (no path components); `scope_floor_denied` rejects absolute/`../`/`legacy/`/secret paths; and a `realpath` prefix check rejects a `design-overrides.md` symlinked out of `.zbuild/prompts/` (the one containment hole string checks miss).
- **Size cap.** Overrides are truncated with a visible marker at `ZBUILD_PROMPT_OVERRIDE_MAX_BYTES` (default 32 KiB) to bound prompt/token cost.

## Consequences

**Positive.** Engine prompts stay target-agnostic, preserving the multi-target goal. Operators tailor any stage to their stack without forking zBuild. The mechanism reuses ADR-016's resolution shape and ADR-004's chokepoint — no new safety surface. zBuild's Class-2 gap is closed via its own overlay, dogfooding the feature.

**Negative / trade-offs.** An overlay wired into a stage that doesn't yet honor the loader (pre-OV-2) is silently ignored — the operator guide must list which stages honor overrides per release. An oversized or contradictory overlay can waste iterations (mitigated by size cap + post-conditions, not prevented). The repo-root-resolution triplet is now duplicated a fourth time; a `zbuild_target_repo_root()` extraction is deferred (flagged in #854, not in scope).

**Rejected alternatives.** (a) Hardcode `_make_plugin` into the engine charter — breaks the multi-target invariant. (b) A config-driven list of grep patterns in `config/` — still ships target vocabulary in the engine and is less expressive than prose. (c) Make overrides able to replace (not just augment) the contract — abandons the safety model; the contract must be non-negotiable.

## Implementation Notes (OV-1, #854)

- `scripts/lib/prompt-overrides.sh` — `load_prompt_override <stage> [repo_root]`; sources `scope-governance.sh` for `scope_floor_denied`; canonical-stage regex + realpath containment + size cap; fail-open rc 0.
- `plugins/agent/design/plugin.sh` — sources the loader; adds the generic enumerated-set clause to the charter; appends `load_prompt_override design` under the delimiter between the contract heredoc and `apply_scope_redaction`.
- `.zbuild/prompts/design-overrides.md` — zBuild's own ABS-1 (stage/plugin roster) + ABS-2 (config/golden) rule.
- Tests: `tests/unit/prompt-overrides-load-test.sh` (present/absent/empty/traversal/absolute/symlink-out/root-resolution/size-cap), `tests/unit/design-prompt-override-section-test.sh` (generic principle present, section after-contract, no-noise-when-absent), `tests/integration/design-prompt-override-pipeline-test.sh` (override survives REAL redaction, ordering, contract intact, absent-clean, symlink-safe). All `set -uo pipefail` only.
- **OV-2 (#855)** wires the same loader into `build`/`impact`/`review`/`test_assessment` (identical to design: append after the contract heredoc/`printf`, before `apply_scope_redaction`) and `plan`. `intake` is excluded — it builds no LLM prompt (it parses the issue deterministically into the scope manifest), so there is no override surface. **`plan` needs special handling**: it assembles its prompt in a shell variable *after* the goal is redacted, so the override is redacted in its **own** `apply_scope_redaction` pass and spliced into the prompt **after** `_plan_instructions` — preserving both invariants (redaction-covered AND after-contract). Each stage reads `${repo_root}/.zbuild/prompts/<stage>-overrides.md`. Per-stage behavioral tests: `tests/unit/{build,review,plan,impact,test-assessment}-prompt-override-test.sh` (override present→after-contract+survives-redaction; absent→no delimiter noise).
- **OV-3 (#856)** is the companion compiler/typecheck gate for statically-typed targets, where the type-checker is the deterministic absence-collateral catcher.
