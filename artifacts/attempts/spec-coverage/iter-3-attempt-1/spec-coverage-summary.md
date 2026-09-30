## spec-coverage — uncovered

- The issue mandates `verdict`, `disposition`, and `reason` as mandatory fields on every conformant v2 result, but four SPECs name only verdict and disposition without requiring a non-empty reason on their exit paths.

- NOT COVERED: mandatory `reason` field missing from the fallback-gh-fail exit path — SPEC-8 specifies `verdict=error, disposition=unavailable` but omits `reason`
- NOT COVERED: mandatory `reason` field missing from the pr-open delegation SUCCESS path — SPEC-14 specifies `verdict=pass, disposition=complete` but omits `reason`
- NOT COVERED: mandatory `reason` field missing from the merge delegation SUCCESS path — SPEC-15 specifies `verdict=pass, disposition=complete` but omits `reason`
- NOT COVERED: mandatory `reason` field missing from the SIGTERM/SIGINT interrupted path — SPEC-17 specifies `verdict=error, disposition=interrupted` but omits `reason`
