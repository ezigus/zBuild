## issue-acceptance — fail

- The plugin references `"${ZBUILD_STAGE_INPUTS}"` without a default value; under `set -euo pipefail` this crashes with "unbound variable" when the variable is absent, so existing integration and e2e callers that do not set it receive no result file and the SPEC-9 deployed-template path fails with verdict=error instead of healthy.

- NOT MET: v2 result file written on every exit path (crash before any write when ZBUILD_STAGE_INPUTS is unset)
- NOT MET: fail-closed behaviour preserved verbatim (SPEC-9 integration path broken by the same crash)
- NOT MET: SIGPIPE antipattern introduced in the new test code.
