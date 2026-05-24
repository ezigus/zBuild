## Adversarial Quality: Systematic Edge Case Discovery

Think like an attacker and a chaos engineer. Find the ways this code will break.

### Failure Mode Analysis
For each component changed, ask:
1. What happens when the input is empty? Null? Maximum size?
2. What happens when an external dependency is down?
3. What happens under concurrent access?
4. What happens when disk is full? Memory is low? Network is flaky?
5. What happens when the clock skews or timezone changes?

### Edge Case Categories

**Data Edge Cases:**
- Empty collections, single-element collections, max-size collections
- Unicode, emoji, RTL text, null bytes in strings
- Numeric overflow, underflow, NaN, Infinity, negative zero
- Date boundaries: midnight, DST transitions, leap seconds, year 2038

**Timing Edge Cases:**
- Race conditions between concurrent operations
- Operations that span a retry/timeout boundary
- Stale cache reads during updates
- Clock skew between distributed components

**State Edge Cases:**
- Partially completed operations (crash mid-write)
- Re-entrant calls (function called while already executing)
- State corruption from previous failed operations
- Idempotency violations (same request processed twice)

### Negative Testing Prompts
- What if a user deliberately sends malformed input?
- What if the network drops mid-request?
- What if the database returns stale data?
- What if two users modify the same resource simultaneously?
- What if the system runs for 30 days without restart?

### Adversarial Thinking
- How could a malicious user exploit this change?
- What error messages leak internal implementation details?
- Are there timing side-channels in security-sensitive operations?
- Can rate limits be bypassed by parameter manipulation?

### Definition of Done for Quality
- All happy paths tested
- All identified edge cases tested or documented as known limitations
- Error paths return meaningful messages (not stack traces)
- Resource cleanup happens even on failure (finally/defer patterns)

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Failure Modes Found**: For each component, list what happens when it fails (5+ specific scenarios)
2. **Negative Test Cases**: Specific test cases covering empty input, null, maximum size, concurrent access, resource exhaustion
3. **Edge Cases Tested**: Data edge cases (Unicode, numeric overflow), timing edge cases (race conditions), state edge cases (partial failure recovery)
4. **Definition of Done for Quality**: Confirmation that all happy paths are tested, edge cases are covered or documented as known limitations, error messages are clear

If any section is not applicable, explicitly state why it's skipped.
