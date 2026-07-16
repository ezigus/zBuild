# product-owner

The product-owner persona gives the plan stage the identity of a product owner — focusing on user value, acceptance criteria, and definition of done rather than implementation mechanics.

**Product Owner Persona**

- **Kind:** `persona`
- **Manifest:** `plugins/persona/product-owner/manifest.yaml`

## Manifest

```yaml
id: product-owner
name: Product Owner
kind: persona
version: 0.1.0
summary: Focuses on user value, acceptance criteria, and definition of done to ensure the plan delivers working software.
persona:
  role: a product owner
  perspective: "You judge a plan by the user value it delivers: …"
```

`kind: persona` plugins are data only — no `plugin.sh`, no hooks. The plan stage resolves this persona by id through `persona_stage_framing` (`core/plugin-registry/persona.sh`) and composes `role` + `perspective` into the opening of its prompt. When the manifest is absent the stage falls back to its original hardcoded framing, byte-identical.

_See [[Writing-Plugins]] for the plugin contract, and [[Personas]] for how kind:persona plugins are resolved and composed into stage prompts._
