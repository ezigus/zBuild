# security-lens

The security-lens plugin is an advisory security-audit lens that checks for command injection, credential exposure, authentication bypass paths, and OWASP vulnerabilities.

**Security Audit Lens**

- **Kind:** `agent`
- **Role:** `security-auditor`
- **Manifest:** `plugins/agent/security-lens/manifest.yaml`

## Manifest

```yaml
id: security-lens
name: Security Audit Lens
kind: agent
version: 0.1.0
description: |
  Security audit lens. One of the 7 compound-audit personas. Detects command
  injection, credential/secret exposure, auth/authz bypass paths, and OWASP
  top 10 vulnerability patterns. Does NOT report non-security issues — that
  discipline is what prevents cross-lens false-positive multiplication.
  Prompt lifted verbatim from legacy/scripts/lib/compound-audit.sh:48-53.

hooks:
  run: security_lens_run
  cleanup: security_lens_cleanup

requires:
  core:
    - redaction
    - event-bus
    - state
  plugins: []

provides:
  role: security-auditor
  artifact_type: findings.json
  schema_version: 1

config:
  tier_default: T3
  max_findings: 50
  # Trigger keywords for escalation (legacy: _COMPOUND_TRIGGERS_security at :367)
  triggers: "injection|auth|secret|credential|permission|bypass|xss|csrf|traversal|sanitiz"

inputs:
  # security-lens runs inside compound_quality (orchestrator). It does NOT
  # participate in the linear inter-stage contract validated by ADR-020 at
  # pipeline-start; compound_quality dynamic fan-in is tracked as a follow-up
  # (`dynamic_inputs: from_role:`).
  # 843-I (#924): the former `diff_patch` input was declared but never read by
  # the plugin (a misleading contract). Removed. The scan-target question
  # (intake goal vs diff.patch) is the separate V2 follow-up; if the scan pivots
  # to the diff, the input is re-introduced there as a consumed edge.
  - id: scope_manifest
    type: file
    source: stage:intake
    required: true
outputs:
  - id: findings
    path: ${artifact_dir}/security-findings.json
    type: findings.json
    required: true
    # ADR-020 amendment (#507): primary output. ADR-019 informational role —
    # presence of findings.json == pass; the indicator never goes red on
    # security-lens content alone (gate semantics unchanged in #507).
    primary: true

state:
  persisted: [last_findings, last_cycle_score]
  reconstructed: [git_diff]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
