# Design: AI-Powered Skill Injection

## Problem

The skill injection system uses static rules: label grep for issue type, hardcoded lookup tables for skill selection, keyword regex for body analysis, linear formulas for complexity weighting. These heuristics can't understand nuance — "Add OAuth login page" is both frontend and security, but the grep picks whichever matches first. Skills are concatenated verbatim into prompts regardless of what the issue actually needs, producing bloated generic guidance.

The skill memory system records outcomes but never feeds them back into selection. Generated recommendations are never consumed. The system doesn't learn.

## Approach: LLM-as-Router

**One haiku LLM call at intake replaces all heuristics.** The LLM reads the issue, selects from the skill library, generates new skills to fill gaps, and produces targeted rationale. Cost: ~$0.002 per pipeline run.

The 17 curated skill files become a "skill library" that the LLM selects from intelligently. The static registry stays as a fallback — three layers deep.

### Why not per-stage LLM calls?

Per-stage calls (4-5x more) add latency and cost for marginal benefit. Intake has full issue context; subsequent stages add incremental context (plan, diff) but the skill selection rarely needs to change. If mid-pipeline adaptation is needed later, the architecture supports it — but start with one call.

### Why not LLM-as-Synthesizer (generate prompts from scratch)?

Generating custom prompts per-issue loses the curated knowledge in skill files, is non-deterministic, and can't fall back gracefully. The skill files are a knowledge base — the LLM should route to them, not replace them.

---

## Design

### 1. Smart Intake Analysis (`skill_analyze_issue`)

**New function in `skill-registry.sh`.**

Calls `_intelligence_call_claude()` (haiku, cached, with fallback) with:

1. **Issue context**: title + body + labels
2. **Skill catalog**: compact index of all skills (curated + generated) with one-line descriptions
3. **Memory context**: top recommendations from `skill_memory_get_recommendations()` for this issue type
4. **Intelligence analysis**: reuses output from `intelligence_analyze_issue()` if available

**Returns structured JSON:**

```json
{
  "issue_type": "frontend",
  "confidence": 0.92,
  "secondary_domains": ["accessibility", "real-time"],
  "complexity_assessment": {
    "score": 6,
    "reasoning": "WebSocket integration with CSS animation and ARIA — moderate"
  },
  "skill_plan": {
    "plan": ["brainstorming", "frontend-design", "product-thinking"],
    "design": ["architecture-design", "frontend-design"],
    "build": ["frontend-design"],
    "review": ["two-stage-review"],
    "compound_quality": ["adversarial-quality"]
  },
  "skill_rationale": {
    "frontend-design": "Progress bar needs ARIA progressbar role, responsive CSS, touch targets",
    "product-thinking": "UX decision: bar vs percentage text vs stage breakdown"
  },
  "generated_skills": [
    {
      "name": "websocket-realtime",
      "reason": "Issue requires WebSocket event handling — no existing skill covers real-time data flow",
      "content": "## WebSocket Real-Time Patterns\n\n### Connection Management\n..."
    }
  ],
  "review_focus": ["accessibility compliance", "responsive breakpoints"],
  "risk_areas": ["ETA accuracy with non-uniform stage times"]
}
```

**Written to:** `$ARTIFACTS_DIR/skill-plan.json`

**Generated skills saved to:** `scripts/skills/generated/{name}.md`

**Fallback chain:**
1. `skill_analyze_issue()` — LLM-powered (primary)
2. `skill_select_adaptive()` — body keywords + complexity weighting (secondary)
3. `skill_get_prompts()` — static registry (tertiary)

### 2. Skill Catalog Builder (`skill_build_catalog`)

**New function in `skill-registry.sh`.**

Scans both directories and builds a compact index for the LLM prompt:

```
scripts/skills/           → curated skills (17)
scripts/skills/generated/ → AI-generated skills (grows over time)
```

**Output format** (one line per skill, ~30 tokens each):

```
- brainstorming: Socratic design refinement — task decomposition, alternatives, risk analysis, definition of done
- frontend-design: UI/UX patterns — accessibility (ARIA, WCAG), responsive design, component architecture, performance
- websocket-realtime [generated]: WebSocket event handling — connection management, reconnection, state sync
```

**Includes memory context** when available:

```
- frontend-design: UI/UX patterns — accessibility, responsive, components [85% success rate for frontend/plan]
- testing-strategy: Test design — coverage, edge cases, property-based [40% success rate for frontend/plan]
```

The LLM sees which skills have proven track records for this issue type.

### 3. Downstream Stage Consumption (`skill_load_from_plan`)

**New function in `skill-registry.sh`.** Replaces per-stage `skill_select_adaptive()` calls.

```bash
skill_load_from_plan(stage) {
    # 1. Read $ARTIFACTS_DIR/skill-plan.json
    # 2. Extract skills array for this stage
    # 3. For each skill:
    #    - Load from scripts/skills/{name}.md or scripts/skills/generated/{name}.md
    #    - If _refinements/{name}.patch.md exists → append refinement
    # 4. Prepend skill_rationale for each skill (targeted guidance)
    # 5. Return combined prompt text
    # Fallback: if skill-plan.json missing → skill_select_adaptive()
}
```

**Prompt output structure:**

```markdown
## Skill Guidance (frontend issue, AI-selected)

### Why these skills were selected:
- frontend-design: Progress bar needs ARIA progressbar role, responsive CSS, touch targets
- websocket-realtime: Pipeline updates arrive via WebSocket every 2s

### Frontend Design Expertise
[frontend-design.md content + any refinements]

### WebSocket Real-Time Patterns (auto-generated)
[generated/websocket-realtime.md content]
```

The rationale acts as a focusing lens — Claude reads it first and knows what to pay attention to.

### 4. Dynamic Skill Generation

**During intake**, if the LLM determines no existing skill covers a domain:

1. The `generated_skills` array in the JSON contains the new skill content
2. `skill_analyze_issue()` writes each generated skill to `scripts/skills/generated/{name}.md`
3. The skill is immediately available for the current pipeline
4. Future pipelines see it in the catalog and can select it without regenerating

**Directory structure:**

```
scripts/skills/
├── brainstorming.md              # Curated (hand-written)
├── frontend-design.md            # Curated
├── ...                           # 17 curated total
└── generated/                    # AI-generated, growing library
    ├── websocket-realtime.md
    ├── i18n-localization.md
    └── _refinements/             # Outcome-driven patches
        └── frontend-design.patch.md
```

**Generated skill lifecycle:**

| Verdict Count | Action |
|---|---|
| 3+ `keep` or `keep_and_refine` | Graduate to curated directory |
| 3+ `prune` | Delete the file |
| Mixed | Keep in generated, track |

### 5. Outcome Learning Loop (`skill_analyze_outcome`)

**New function in `skill-registry.sh`.**

Fires at pipeline completion (success or failure). One haiku call receives:

1. The skill plan (`skill-plan.json`)
2. Pipeline outcome (stages passed/failed)
3. Review feedback (if review ran)
4. Error context (if stages failed)

**Returns:**

```json
{
  "skill_effectiveness": {
    "frontend-design": {
      "verdict": "effective",
      "evidence": "Plan included ARIA section, review confirmed compliance",
      "learning": "stat-bar CSS reuse hint was directly followed"
    }
  },
  "refinements": [
    {
      "skill": "frontend-design",
      "addition": "For dashboard features, mention existing CSS patterns to encourage reuse"
    }
  ],
  "generated_skill_verdict": {
    "websocket-realtime": "keep_and_refine"
  }
}
```

**Actions:**

| Field | What happens |
|---|---|
| `skill_effectiveness` | Written to skill memory with verdict + evidence (replaces bare boolean) |
| `refinements` | Saved to `scripts/skills/generated/_refinements/{skill}.patch.md` |
| `generated_skill_verdict` | `keep` / `keep_and_refine` / `prune` — controls lifecycle |

**The feedback loop:**

```
Intake → LLM reads catalog + memory → selects + generates skills
    ↓
Pipeline runs with targeted skill guidance
    ↓
Completion → LLM analyzes outcome → updates memory + refines skills
    ↓
Next pipeline → intake LLM sees refined skills + richer memory
    ↓
System gets smarter with every run
```

### 6. Integration Points

**`stage_intake()` in `pipeline-stages.sh`:**
- After `intelligence_analyze_issue()`, call `skill_analyze_issue()`
- Write `skill-plan.json` to artifacts
- Set `INTELLIGENCE_ISSUE_TYPE` from skill plan (replaces label grep)

**`stage_plan()`, `stage_build()`, `stage_review()`, etc.:**
- Replace `skill_select_adaptive()` calls with `skill_load_from_plan("plan")`
- Fallback to `skill_select_adaptive()` if `skill-plan.json` missing

**`sw-pipeline.sh` completion handler:**
- Call `skill_analyze_outcome()` after pipeline finishes
- Apply refinements, lifecycle verdicts

---

## Files

| File | Action | Purpose |
|---|---|---|
| `scripts/lib/skill-registry.sh` | MODIFY | Add `skill_analyze_issue()`, `skill_build_catalog()`, `skill_load_from_plan()`, `skill_analyze_outcome()` |
| `scripts/lib/skill-memory.sh` | MODIFY | Upgrade `skill_memory_record()` to store verdict + evidence + learning (not just boolean) |
| `scripts/lib/pipeline-stages.sh` | MODIFY | Replace `skill_select_adaptive()` calls with `skill_load_from_plan()` in all stages; add `skill_analyze_issue()` to intake |
| `scripts/sw-pipeline.sh` | MODIFY | Add `skill_analyze_outcome()` at pipeline completion |
| `scripts/skills/generated/` | CREATE | Directory for AI-generated skills |
| `scripts/skills/generated/_refinements/` | CREATE | Directory for outcome-driven patches |
| `scripts/test-skill-injection.sh` | MODIFY | Add test suites for LLM-powered selection, generation, outcome loop |

---

## Cost

| Call | When | Model | Cost |
|---|---|---|---|
| `skill_analyze_issue()` | Intake | haiku | ~$0.002 |
| `skill_analyze_outcome()` | Completion | haiku | ~$0.002 |
| **Total per pipeline** | | | **~$0.004** |

Existing pipeline LLM costs (plan/design/build/review with opus/sonnet) are ~$2-8 per run. The skill intelligence adds 0.05-0.2% overhead.

---

## Fallback Guarantees

Every new function has a fallback to the existing system:

| New Function | Fallback | Condition |
|---|---|---|
| `skill_analyze_issue()` | `skill_select_adaptive()` | LLM call fails |
| `skill_load_from_plan()` | `skill_select_adaptive()` | `skill-plan.json` missing |
| `skill_analyze_outcome()` | `skill_memory_record()` (boolean) | LLM call fails |

The static registry and keyword detection remain as safety nets. Zero regression risk for existing pipelines.

---

## Testing

| Suite | Tests |
|---|---|
| Skill catalog builder | Scans both directories, includes generated skills, formats correctly |
| LLM skill analysis | Mock haiku response, verify skill-plan.json written correctly |
| Generated skill lifecycle | Create, use, verdict, graduate, prune |
| Refinement patches | Write patch, verify it appends to skill content |
| Outcome analysis | Mock response, verify memory updated with verdicts |
| Fallback chain | LLM failure → adaptive → static, each level works independently |
| Integration | Full flow: intake → plan → build → review → outcome |
