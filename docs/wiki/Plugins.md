# Plugins reference

In plain terms: a **plugin** is a small, replaceable piece that performs exactly one step — things like "run the tests", "post a review comment", or "scan for secrets". Each plugin has a declared contract (what it reads in, what it writes out), and the engine wires them together. You'd look here to understand what a specific step does, what inputs it needs, and what it produces.

One page per **leaf node** (plugin). Each is generated from its `manifest.yaml` — the embedded manifest on each page is the source of truth. See [[Writing-Plugins]] for the contract (ADR-001).

| Plugin | Kind | Role |
|---|---|---|
| [[plugins/build]] | agent | — |
| [[plugins/deploy]] | agent | deploy_agent |
| [[plugins/design]] | agent | — |
| [[plugins/impact]] | agent | — |
| [[plugins/intake]] | agent | intake |
| [[plugins/monitor]] | agent | monitor |
| [[plugins/plan]] | agent | — |
| [[plugins/pr-delivery]] | agent | pr_delivery |
| [[plugins/review-aggregator]] | agent | review_aggregator |
| [[plugins/review-lens]] | agent | review_lens |
| [[plugins/review-report]] | agent | review_report |
| [[plugins/security-lens]] | agent | security-auditor |
| [[plugins/spec-acceptance]] | agent | acceptance_gate |
| [[plugins/validate]] | agent | validate_agent |
| [[plugins/claim-coordinator-github-labels]] | claim-coordinator | claim-coordinator |
| [[plugins/cache-gh-actions]] | tool | cache-backend |
| [[plugins/cache-local]] | tool | cache-backend |
| [[plugins/coverage-gate]] | tool | coverage_gate |
| [[plugins/deploy-release]] | tool | deploy_release_executor |
| [[plugins/design-gate]] | tool | design_gate |
| [[plugins/gate-aggregator]] | tool | gate_aggregator |
| [[plugins/health-check]] | tool | health_check_executor |
| [[plugins/lint-gate]] | tool | lint_gate |
| [[plugins/memory-ruflo]] | tool | memory-backend |
| [[plugins/memory-sqlite]] | tool | memory-backend |
| [[plugins/merge]] | tool | — |
| [[plugins/mutation-gate]] | tool | mutation_gate |
| [[plugins/orch-bash-parallel]] | tool | orchestrator-backend |
| [[plugins/orch-mock]] | tool | orchestrator-backend |
| [[plugins/orch-ruflo-hive]] | tool | orchestrator-backend |
| [[plugins/orch-sequential]] | tool | orchestrator-backend |
| [[plugins/output-github-comment]] | tool | output |
| [[plugins/pr]] | tool | — |
| [[plugins/secret-scan]] | tool | secret_scan |
| [[plugins/shape-floor]] | tool | shape_floor |
| [[plugins/test]] | tool | tester |
