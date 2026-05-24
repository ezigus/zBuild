# Claude Instructions (Thin Wrapper)

Use centralized standards as source of truth:
- /Users/ericziegler/code/standards/ai-agent-standards/core/core-policy.md
- /Users/ericziegler/code/standards/ai-agent-standards/adapters/claude-adapter.md
- /Users/ericziegler/code/standards/ai-agent-standards/repo-overrides/shipwright.md
- /Users/ericziegler/code/standards/ai-agent-standards/resolution/profile-resolution-matrix.md
- /Users/ericziegler/code/standards/ai-agent-standards/resolution/shipwright-detection-contract.md

Default profile eligibility for this repo: shipwright.
Shipwright profile is conditional per detection contract.

Load local generated instructions:
@../.ai-standards/generated/claude-instructions.md

Optional repo-specific additions:
@../.ai-standards/local/claude-additions.md

## Feature Flags

| Flag | Default | Purpose |
|------|---------|---------|
| `RUFLO_SELF_HEAL_HIVE=true` | unset | Enable root-cause triage on test failure with specialist hypothesis spawning and synthesis |

