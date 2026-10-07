# Acceptance checkpoint — issue #1799

## Files read
- plugins/tool/pr-open/plugin.sh:125-184 — new state-check block: reads state.status and cycle_iterations, forces _draft_bool=true when status=failed or any cycle has status=max_iterations. Runs AFTER _TPL_PR_DRAFT normalization and ORs in.
- plugins/tool/pr-open/lib/advisory-section.sh:119-186 — new _pr_open_render_convergence_section (renders "not converged" with iterations_used/max_iterations) and _pr_open_render_gate_section (renders failing gates + reason). Both wired into _pr_open_compose_body as args 7-8.

## Conclusions
- R-1 (failed → draft): implemented at plugin.sh:140-145, test 10 red on main. MET.
- R-2 (max_iterations → draft): implemented at plugin.sh:142-145, test 11 red on main. MET.
- R-3 (body names failing gates + reason): _pr_open_render_gate_section renders "Failing gates: X, Y. <reason>", test 13 checks gate-security, gate-tests, and reason text. MET.
- R-4 (body shows iterations used/max, says "not converged"): renders "> ⚠️ **cycle-id not converged** (5/5 iterations)". Both values present. Test 12 checks "not converged", cycle name, and "5". MET.
- R-5 (passing run still non-draft): code defaults _draft_bool=false; new checks only OR in true. MET.
- R-6 (_TPL_PR_DRAFT=true still forces draft): normalization at line 130-131 runs first and sets true; new checks can only add more true. MET.
- R-7 (regression tests red on main): SPEC statuses confirm tests 10 and 11 were red on old code. MET.

## Still open
Nothing — verdict is pass.
