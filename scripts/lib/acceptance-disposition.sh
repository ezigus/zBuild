#!/usr/bin/env bash
# scripts/lib/acceptance-disposition.sh — the acceptance gate's failure-class →
# disposition table (#1959, shipped in #2129). One function, no dependencies,
# so the plugin (runtime) and scripts/lib/lint-disposition-classify.sh (build
# time) read the SAME table — the #1708 pattern applied to the one channel that
# never got it. Every row was added after a run died on the class it lacked
# (#1583, #1585, #1686, #1670, #2097, #2109).
#
# _ag_failure_class_disposition <class> → recoverable | advisory | terminal,
# or EMPTY for a class this table does not know. The runtime caller treats
# empty as recoverable and emits acceptance.gate.unknown_failure_class; the lint
# refuses a manifest that declares a class this returns empty for.
[[ -n "${_ACCEPTANCE_DISPOSITION_LOADED:-}" ]] && return 0
_ACCEPTANCE_DISPOSITION_LOADED=1

_ag_failure_class_disposition() {
    case "${1:-}" in
        # Fixed where they are found, next iteration — the assertion has a
        # model author (test-author, #2022) and the cycle re-verifies.
        untagged_spec|tautology|inert_wiring|no_testfile|no_testfiles|\
        not_passing_at_head|wiring_not_on_path|guard_regressed)
            printf 'recoverable' ;;
        # Infrastructure: a flaky sandbox must never hard-fail the pipeline.
        negctl_error|reachability_error)
            printf 'advisory' ;;
        # Design-authored structure build cannot fix. Written by the early
        # exit in plugin.sh with its own disposition; named here so the table
        # is complete and terminal still outranks recoverable in a mixed set.
        malformed_acceptance_block)
            printf 'terminal' ;;
        *)  : ;;
    esac
}
