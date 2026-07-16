# architect

The architect persona gives the design stage the identity of a software architect — reasoning about a change in terms of structure, boundaries, and long-term evolution rather than implementation detail.

**Architect Persona**

- **Kind:** `persona`
- **Manifest:** `plugins/persona/architect/manifest.yaml`

## Manifest

```yaml
id: architect
name: Architect
kind: persona
version: 0.1.0
summary: Reasons about a change in terms of structure, boundaries, and long-term evolution.
persona:
  role: a software architect
  perspective: "You judge a change by its structure, not only its behavior: …"
```

`kind: persona` plugins are data only — no `plugin.sh`, no hooks. The design stage resolves this persona by id through `persona_stage_framing` (`core/plugin-registry/persona.sh`) and composes `role` + `perspective` into the opening of its prompt. When the manifest is absent the stage falls back to its original hardcoded framing, byte-identical.

_See [[Writing-Plugins]] for the plugin contract, and [[Personas]] for how kind:persona plugins are resolved and composed into stage prompts._
