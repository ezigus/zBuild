## Brainstorming: Socratic Design Refinement

**IMPORTANT: You are in an autonomous pipeline. Do NOT ask questions or wait for answers. Instead, answer each question yourself based on the issue context, codebase analysis, and your best judgment. Document your reasoning directly in the plan.**

Before writing the implementation plan, challenge your assumptions with these questions:

### Requirements Clarity
- What is the **minimum viable change** that satisfies this issue?
- Are there implicit requirements not stated in the issue?
- What are the acceptance criteria? If none are stated, define them.

### Design Alternatives
- What are at least 2 different approaches to solve this?
- What are the trade-offs of each? (complexity, performance, maintainability)
- Which approach minimizes the blast radius of changes?

### Risk Assessment
- What could go wrong with the chosen approach?
- What existing functionality could break?
- Are there edge cases not covered by the issue description?

### Dependency Analysis
- What existing code does this depend on?
- What other code depends on what you're changing?
- Are there any circular dependency risks?

### Simplicity Check
- Can this be solved with fewer files changed?
- Is there existing infrastructure you can reuse?
- Would a simpler approach work for 90% of cases?

Document your reasoning in the plan. Show the alternatives you considered and why you chose this approach.

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Task Decomposition**: Numbered list of concrete implementation tasks with explicit dependencies (e.g., "Task 3 blocks Task 5")
2. **Risk Analysis**: For each identified risk, state what could break and your mitigation strategy
3. **Definition of Done**: Specific, testable acceptance criteria that prove this issue is resolved
4. **Alternatives Considered**: At least 2 approaches with explicit trade-offs (complexity, performance, maintainability, blast radius)

If any section is not applicable, explicitly state why it's skipped.
