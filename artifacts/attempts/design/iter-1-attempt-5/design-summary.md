## design — fail

- the design fails 4 check(s)

- The issue asks for this and no SPEC covers it: R-3: the requirement "Every test that used it as a fixture passes on `orch-mock` or `bash-parallel`" is not covered — SPEC-3 demands the plugin directory and golden be deleted and a guard catch any surviving reference, but a test satisfies that guard by simply being deleted (or having the reference stripped with no replacement)
- The issue asks for this and no SPEC covers it: SPEC-2 covers the config-names-sequential path
- The issue asks for this and no SPEC covers it: SPEC-9 requires the suite to pass, but it passes equally whether the formerly-orch-sequential test coverage is migrated or simply removed
- The issue asks for this and no SPEC covers it: no SPEC demands the coverage be preserved and passing on another backend

This try is kept as the working copy for the next run; design.md is unchanged.
