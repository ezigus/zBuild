## spec-coverage — uncovered

- No SPEC verifies that a template-level router budget overrides the manifest-declared one.

- NOT COVERED: "the template override still wins where one is set" — SPEC-6 covers only that the manifest declares `config.router` with `timeout_s`/`max_turns`
- NOT COVERED: no SPEC asserts the precedence rule when a template also sets those values.
