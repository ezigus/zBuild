## spec-correspondence — mismatch

- judged 17 SPEC(s): 15 correspond, 1 partial, 1 mismatch, 0 uncheckable, 0 unjudged

- SPEC-2 partial: The assertion covers closed-issue refusal, success, no-goal failure, missing state_file, empty-after-sanitization, branch-refused, and SIGTERM, but there is no `assert_file_exists` check for the failed-fetch failure path (T_456_i), which SPEC-1 treats as a distinct terminal exit.
- SPEC-14 MISMATCH: The requirement specifies that `template_stage_router_timeout_s()` (with `_s` suffix) is the function consulted, but the assertion defines and exercises `template_stage_router_timeout()` (no `_s` suffix); a passing assertion proves the router honors the un-suffixed function, not the one the requirement names.

