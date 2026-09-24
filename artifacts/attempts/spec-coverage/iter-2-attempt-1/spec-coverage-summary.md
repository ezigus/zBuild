## spec-coverage — uncovered

- The first acceptance checkbox and the "Folds in" section both require a conformant v2 result on the *interruption* exit path, with disposition `unavailable` when the action's outcome is genuinely unknown — but none of SPEC-2, SPEC-5, or SPEC-9's enumerated exit paths includes an interrupted/unavailable path, so nothing prevents an implementation that writes a conformant result on the named paths only and omits interruption handling.

- NOT COVERED: conformant v2 result on the interruption exit path with disposition `unavailable` for unknown-outcome states (first checkbox "success, failure, and interruption"
- NOT COVERED: "Folds in" — "the plugin reports `unavailable` rather than guessing")
