## Architecture Design Expertise

Create an Architecture Decision Record (ADR) that future developers can use as a map.

### Component Decomposition
- Identify the 3-5 key components this change touches
- Define clear boundaries — each component should have ONE reason to change
- Specify interfaces between components (function signatures, data contracts, event schemas)
- Dependencies should point inward — outer layers depend on inner, never the reverse

### Interface Contracts
- Define input/output types for every public function or API boundary
- Specify error contracts — what errors can each component return?
- Document preconditions and postconditions
- Use types to enforce invariants — make invalid states unrepresentable

### Design Decisions
For each non-obvious design decision, document:
1. **Context** — What constraint or requirement drives this?
2. **Decision** — What did you choose?
3. **Alternatives** — What else was considered? Why rejected?
4. **Consequences** — What trade-offs does this create?

### Patterns to Apply
- **Dependency Injection** — Don't hardcode dependencies, accept them as parameters
- **Single Responsibility** — Each module does one thing well
- **Open/Closed** — Extend through composition, not modification
- **Interface Segregation** — Don't force consumers to depend on methods they don't use

### Anti-Patterns to Flag
- God objects that know about everything
- Circular dependencies between modules
- Shared mutable state across components
- Leaky abstractions (implementation details in public interfaces)

### Testing Architecture
- How will each component be tested in isolation?
- What are the integration test boundaries?
- Which external dependencies need mocking?

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Component Diagram**: ASCII-art or structured text diagram showing 3-5 components and their dependencies
2. **Interface Contracts**: TypeScript-style signatures for all public APIs/functions with input/output types and error contracts
3. **Data Flow**: How data moves between components (request → processing → response)
4. **Error Boundaries**: Which components handle which errors, and how errors propagate up the stack

If any section is not applicable, explicitly state why it's skipped.
