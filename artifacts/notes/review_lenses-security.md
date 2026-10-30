# Security lens notes — issue #1760 op-validation change

## Files read
- core/pipeline/cycle-orchestrator.sh (full: 1–1210, plus 459–838)
- core/pipeline/template.sh (lines 1–100, 1060–1265)
- grep sweeps for `ne|neq`, `matches`, `abort_when`, `until.*op`

## Trust boundary
Templates (YAML config files, plugin manifests) are the primary input boundary.
`value:` fields inside `until:`, `exit_when:`, and `abort_when:` blocks flow
directly into the evaluators as `$expected`. The CLAUDE.md security rule says:
"Validate user input at system boundaries (the CLI, GitHub label parsers, plugin manifests)."

## Findings

### F1 — `matches` op: invalid regex silently never matches (MEDIUM, introduced)

All three evaluators (_cycle_eval_one_condition L492, _cycle_check_until L578,
_cycle_check_abort_when L822) execute:

    matches)  [[ "$actual" =~ $expected ]] && { _match="true"; _rc=0; } ;;

`$expected` is the raw `value:` string from the template. No validation is
performed that it is a well-formed ERE before use.

In bash, `[[ s =~ pat ]]` returns exit code 2 when `pat` is an invalid regex.
The `&&` short-circuits: `_match` stays "false", `_rc` stays 1, and the
predicate emits "false" with no error message. The cycle then runs to
max_iterations without any indication that the predicate failed due to an
invalid regex.

Contrast: the numeric ops `gt|gte|lt|lte` have an explicit guard:
    if ! [[ "$actual" =~ ^-?[0-9]+$ ]] || ! [[ "$expected" =~ ^-?[0-9]+$ ]]; then
        error "... requires numeric operands..."
        return 1
    fi

The `matches` op has no analogous validation. This reproduces the silent
fail-open mode the issue was explicitly designed to eliminate, for the new
`matches` op. For `abort_when`, a silently-non-matching predicate means the
safety abort never fires.

The `matches` op is entirely new to this change; the issue is introduced.

### F2 — `ne` still accepted in all three evaluators despite SPEC-3 retiring it (MEDIUM, introduced)

Design (from the issue Design Decisions section): "rename `ne` to `neq`; remove
`in`". The evaluators should accept only `neq`, not `ne`.

Actual implementation:
    ne|neq)  [[ "$actual" != "$expected" ]] && { _match="true"; _rc=0; } ;;
  (lines 478, 564, 808 of cycle-orchestrator.sh)

The change added `neq` as an alias but kept `ne`, so `ne` still matches the
branch rather than reaching `*)`.

SPEC-3: "ne and in are refused at load." The load-time validator in
_tpl_validate_cycles correctly refuses `ne`. But the runtime evaluators are
the defense-in-depth layer (SPEC-8 relies on `*)` to refuse unrecognised ops
at eval time). With `ne|neq`, `ne` bypasses the `*) error` branch entirely
and silently evaluates as `neq`. Any path that bypasses the template loader
(direct variable injection in tests, a state file from a pre-fix run, or a
test fixture) lands in the evaluator with `ne` and it works silently.

This is introduced: before this change the evaluators had `ne)`. The change
was supposed to rename that to `neq)` but instead appended `|neq`, retaining
`ne`.

### F3 — `until.op` empty skips load-time validation (LOW, introduced)

In _tpl_validate_cycles (template.sh line 1242):
    if [[ -n "$uo" ]]; then
        case "$uo" in
            eq|neq|gt|gte|lt|lte|contains|matches) : ;;
            *) error "..."; return 1 ;;
        esac
    fi

When `until.op` is absent from the YAML (the `op:` key is simply missing), `uo`
is empty and the op check is skipped entirely. No load-time error fires.

The missing field is caught at runtime by _cycle_load_template:
    if [[ -z "$_CYCLE_UNTIL_STAGE" || -z "$_CYCLE_UNTIL_FIELD" \
          || -z "$_CYCLE_UNTIL_OP" || -z "$_CYCLE_UNTIL_VALUE" ]]; then
        error "... until.{stage,field,op,value} all required"

So the failure is not silent — it fires at runtime. But the SPEC says "refused
at template load"; the guard narrows enforcement to non-empty ops only.

This is introduced: the guard is new code added by this change. Pre-existing
code had no op validation for `until` at all; the new code adds it, but with
an empty-guard that does not cover missing fields.

## Score rationale

The main fix (load-time abort_when.op and until.op validation, eight-op set
enforcement, `*) error` branch in evaluators) is structurally sound.

F1 is the most significant: it introduces a new silent-failure path for the new
`matches` op that exactly mirrors the original bug (abort_when predicate never
fires). F2 undermines the defense-in-depth `*)` branch for `ne`. F3 is narrow
in practical impact but is a gap between the SPEC's stated guarantee and the
code.

Score: 6 (two medium issues introduced; no critical/injection/path-traversal
issues found; pre-change trust-boundary handling unchanged)
