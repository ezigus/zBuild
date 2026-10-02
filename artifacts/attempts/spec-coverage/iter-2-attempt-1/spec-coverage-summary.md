## spec-coverage — uncovered

- The issue's "every exit path" acceptance checkbox requires a conformant v2 result on the missing-state-file path, but SPEC-9 asserts only rc=1 and no SPEC asserts pr-result.json content (result_contract:2, verdict=error, non-empty disposition, non-empty reason) for that path.

- NOT COVERED: missing-state-file exit path — SPEC-9 only covers the rc change (2→1)
- NOT COVERED: no SPEC requires pr-result.json carrying result_contract:2, verdict=error, non-empty disposition, and non-empty reason on that path, which the issue's "every exit path" acceptance checkbox demands
