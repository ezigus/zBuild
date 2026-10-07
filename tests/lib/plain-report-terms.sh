#!/usr/bin/env bash
# tests/lib/plain-report-terms.sh — the words a report a run writes must not
# contain (#2330, ADR-068 §8): the engine's own codes and numbers, and wording
# that says WHO must act instead of WHAT must be checked. Shared by every test
# that guards a report.

# One extended regex, matched case-insensitively.
PLAIN_REPORT_BANNED_RE='max_iterations|unowned|(^|[^[:alnum:]])yield(ed|s)?([^[:alnum:]]|$)|(^|[^[:alnum:]])halt(ed|s)?([^[:alnum:]]|$)|disposition|request_changes|member_terminal_failure|blocking_member_failure|blocked_on_scope|cycle_abort|llm_rate_limited|llm_unavailable|scope_too_large|(^|[^[:alnum:]])rc[ =]?[0-9]|a person|human'

# plain_report_violations <text> — the offending lines, one per line (empty when clean).
plain_report_violations() {
    grep -iE "$PLAIN_REPORT_BANNED_RE" <<< "$1" || true
}
