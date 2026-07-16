# developer

The developer persona gives the build stage the identity of a software engineer focused on correctness, treating every failing test as an obligation to understand and preferring the simplest implementation that satisfies the acceptance contract.

**Developer Persona**

- **Kind:** `persona`
- **Manifest:** `plugins/persona/developer/manifest.yaml`

## Manifest

```yaml
id: developer
name: Developer
kind: persona
version: 0.1.0
summary: Reasons about a change from the perspective of a software engineer focused on correctness.
persona:
  role: a software engineer
  perspective: "You reason about correctness first: …"
```

`kind: persona` plugins are data only — no `plugin.sh`, no hooks. The build stage resolves this persona by id through `persona_stage_framing` (`core/plugin-registry/persona.sh`) and composes `role` + `perspective` into the opening of its prompt. When the manifest is absent the stage falls back to its original hardcoded framing, byte-identical.

_See [[Writing-Plugins]] for the plugin contract, and [[Personas]] for how kind:persona plugins are resolved and composed into stage prompts._
