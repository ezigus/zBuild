# Red-team review notes — issue #1760

## Files read
- core/pipeline/cycle-orchestrator.sh (lines 260-430, 460-590, 780-850, 1138-1165, 2185-2240)
- core/pipeline/template.sh (grep for op validation, abort_when, ne/neq; lines 1200-1265)
- tests/unit/template-loader-recursive-flow-test.sh (lines 200-375)
- tests/integration/cycle-abort-when-no-match-converges-test.sh (grep)
- tests/integration/cycle-orchestrator-abort-when-test.sh (grep lines 138-270)
- tests/unit/core-pipeline-cycle-events-test.sh (grep lines 49-211)

## Key findings

### F1 - ne|neq in evaluators (design deviation, medium, introduced)
All three evaluators use ne|neq) case, meaning ne is silently accepted at runtime despite
being rejected at template load. The design says rename ne to neq and R3 says ne is refused.
R4 *) branch only fires for truly unrecognized ops; ne bypasses it. In test-only mode
(where _tpl_validate_cycles has not run), direct env-var injection of ne would evaluate
correctly without triggering the *) guard.

Relevant lines: cycle-orchestrator.sh 478, 564, 808.

### F2 - Defense-in-depth removed from _cycle_load_template (medium, introduced)
The old _cycle_load_template independently validated exit_when conditions: field (verdict|status),
op (eq|ne), and stage membership. The new code removes all three, relying entirely on
_tpl_validate_cycles having run. If _cycle_load_template is called without prior
_tpl_validate_cycles (test path, or future code path), invalid exit_when conditions
(wrong field, wrong op, non-member stage) enter _CYCLE_EXIT_CONDITIONS without being caught.
SPEC-3 compliance is bypassable if _cycle_load_template is called directly.

### F3 - matches op: malformed ERE silently becomes no-match (low, introduced)
[[ $actual =~ $expected ]] with unquoted expected. If expected is a malformed ERE (e.g. [unclosed),
bash returns rc=2 from [[. The case statement does not handle rc=2; _rc stays 1 (no-match) and
_match stays false. No error is emitted. A misconfigured matches predicate in abort_when
(a safety switch) silently disables abort rather than raising a diagnostic.

Lines: cycle-orchestrator.sh 492, 578, 821.

### F4 - until.op empty string bypasses template load validation (medium, introduced)
In _tpl_validate_cycles (template.sh line 1242): if [[ -n "$uo" ]]; then
If until.op is missing from the template YAML, the awk parser sets _TPL_CYCLE_UNTIL_OP_<safe>="".
The guard skips validation; the empty op passes template load. The error is deferred to
_cycle_load_template runtime. SPEC-2 requires refusal at template LOAD; an empty op escapes that.

### F5 - abort_when.op empty string passes load silently, abort_when fails open (medium, introduced)
Same pattern at template.sh line 1255: if [[ -n "$aw_op" ]]; then
If abort_when: is declared but op: is missing, aw_op="". Template load succeeds.
At runtime, _cycle_check_abort_when line 793 returns 1 for empty op, silently disabling
abort_when. The abort_when predicate is the safety switch the issue was specifically fixing
for fail-open behavior. An empty op in a declared abort_when reproduces the same fail-open
symptom in a different edge case with no diagnostics.

## Conclusions
- Primary bug (unknown op silently never matches in abort_when) is fixed.
- Five introduced concerns: 3 medium, 2 low.
- None are immediately exploitable in production given trust model (template vars are engine-set).
- F2 and F5 are most significant: F2 removes the only defense-in-depth validation layer;
  F5 leaves the abort safety switch fail-open for the empty-op case.

Score: 5/10
