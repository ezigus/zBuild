# Test-author checkpoint — issue #1799

## Files read
- design.md: plugin.sh adds state-aware draft forcing; advisory-section.sh gains convergence section. State file has `.status` and `.cycle_iterations[id].status`. Gate aggregator result comes from ZBUILD_STAGE_INPUTS `.inputs.gate_aggregator_result`.
- plugin.sh: `_pr_open_run_inner(review_json, state_file, output_pr_result_json, issue_num)`. `_draft_bool` set from `_TPL_PR_DRAFT` then used for `--draft` flag and written to pr-result.json `.data.draft`. No current state.status or cycle_iterations check.
- advisory-section.sh: `_pr_open_compose_body(issue, plan_summary, review_json, review_verdict, advisory_report, test_verdict)`. No convergence or gate_aggregator section currently.
- pr-open-test.sh: Tests 2,2b,2c,3,4,7,8,9. State file restored between tests. Body capture pattern: mock gh, loop through "$@", capture arg after "--body" to a temp file.

## SPEC assignments
- SPEC-1 (test 10): state.status=failed → data.draft=true, --draft to gh
- SPEC-2 (test 11): cycle_iterations[cycle-build].status=max_iterations → data.draft=true, --draft to gh
- SPEC-3 (test 12): max_iterations state → body has "not converged", "cycle-build", "5"
- SPEC-4 (test 13): gate_aggregator_result with failing verdict in ZBUILD_STAGE_INPUTS → body has gate names and reason

## Key decisions
- Body capture: gh() mock loops "$@" with prev-arg tracking; writes arg after "--body" to a file. Works because $(gh pr create ...) subshell inherits BODY12_FILE from parent.
- All tests use no-existing-PR path (gh pr list returns empty) so gh pr create is called and body is capturable.
- Restore STATE_FILE and ZBUILD_STAGE_INPUTS after each test.
- SPEC-3 test uses cycle-build with iterations_used=5/max=5; checks for "not converged", "cycle-build", "5".
- SPEC-4 test: writes gate-aggregator-result.json with failed=["gate-security","gate-tests"], reason="Security gate: critical vulnerability found"; updates stage-inputs.json; checks body for those strings.

## Status
Writing testfile now.
