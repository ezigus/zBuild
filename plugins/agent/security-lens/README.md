# Security Lens

One of the 7 compound-audit personas. Detects security-relevant issues in changed code: command injection, credential/secret exposure, auth/authz bypass, OWASP top 10.

## Status

**Phase 0 POC.** Proves the end-to-end migration loop (manifest → registry → redaction → event bus → typed output). The actual LLM call is stubbed; real routing lands when `core/router/` is implemented.

## Legacy origin

Prompt lifted verbatim from `legacy/scripts/lib/compound-audit.sh:48-53`. Trigger keywords from `:367`. **Do not edit the prompt without an ADR** — that prompt discipline is the agent magic that keeps cross-lens findings from multiplying false positives.

## Inputs

| Arg | Type | Description |
|---|---|---|
| `$1` | file | Raw input (typically a git diff or file list) |
| `$2` | file | Scope manifest (chokepoint refuses to run without it) |
| `$3` | file | Output path for `findings.json` |
| `$4` | dir (opt) | Artifact dir for intermediate redacted prompt |

## Output schema

```json
{
  "schema_version": 1,
  "plugin_id": "security-lens",
  "generated_at": "ISO 8601",
  "findings": [
    {
      "title": "...",
      "severity": "critical | high | medium | low",
      "category": "injection | secret | auth | owasp-* | other",
      "file": "path:line",
      "evidence": "...",
      "suggestion": "..."
    }
  ]
}
```

## 5-test trial (in progress)

- [x] Behavior preserved: prompt text matches `legacy:48-53` verbatim
- [x] Regression test exists: `tests/plugin-security-lens-test.sh`
- [x] Citation discoverable: `legacy/scripts/lib/compound-audit.sh:48-53` still present
- [ ] Mapping matches: `KEEPERS.md §F` row "compound-audit 7-lens cascade" lists this as `kind: agent` plugin — verify after issue manifest lands
- [ ] Removal reproduces symptom: deleting `plugins/agent/security-lens/` and running the smoke suite should leave security findings empty — requires full pipeline orchestration (Phase 1)

When the trial is complete, prune the legacy block (`compound-audit.sh:48-53`) and write `legacy/migrated/security-lens.md`.
