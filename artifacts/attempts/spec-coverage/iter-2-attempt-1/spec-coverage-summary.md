## spec-coverage — uncovered

- SPEC-5, SPEC-6, and SPEC-9 assert only `result_contract:2` and `verdict` but omit `disposition`, which the issue mandates as part of the mandatory v2 triple (verdict, disposition, reason) on every exit path.

- NOT COVERED: merge delegation success path (SPEC-5) asserts `result_contract:2, verdict=pass` but leaves `disposition` unspecified — the issue requires disposition as a mandatory field on every exit path under v2
- NOT COVERED: merge delegation failure path (SPEC-6) asserts `result_contract:2, verdict=error` but leaves `disposition` unspecified
- NOT COVERED: fallback gh-pr-create success path (SPEC-9) asserts `result_contract:2, verdict=pass` but leaves `disposition` unspecified
