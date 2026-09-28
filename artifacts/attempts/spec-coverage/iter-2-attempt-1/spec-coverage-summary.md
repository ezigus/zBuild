## spec-coverage — uncovered

- The issue requires that anything the plugin currently communicates via sidecar, event, or exit code moves into the result and that plugin-specific detail goes under a namespaced `data` field; SPEC-3 mandates only `result_contract`, `verdict`, `disposition`, and `reason` — no SPEC asserts the presence or structure of a `data` field.

- NOT COVERED: plugin-specific detail written under a namespaced `data` field in intake-result.json
