# ADR-008: Dependency Policy (Actions, Node, npm)

**Status:** Accepted
**Date:** 2026-05-24

## Context

zBuild has three categories of external dependencies that can rot:

1. **GitHub Actions** — `actions/checkout`, `actions/setup-node`, etc. Each action major version pins a JavaScript runtime (e.g., `actions/checkout@v4` runs on Node.js 20). When GitHub deprecates that runtime, the action emits a warning, then breaks. Today (2026-05-24) we saw the warning on `checkout@v4` (Node 20 → forced to Node 24 starting 2026-06-02).
2. **Node.js itself** — both as the runtime for `bin/zbuild` (via `package.json` `engines`) and as the runtime for any tooling our CI uses (e.g., `npm publish`).
3. **npm dependencies** — currently none required by zBuild; future plugins may add some.

Without an explicit policy, deprecations sneak up. The 2026-06-02 forced-upgrade caught us mid-Phase-0; that's the kind of thing that should be auto-PR'd in advance, not surfaced as a CI warning.

## Decision

### Actions: always latest stable major

- Bump GitHub Actions to the latest stable major version. Today: `actions/checkout@v5`, `actions/setup-node@v5`.
- Pin to major version (`@v5`), not SHA or minor. Major bumps get reviewed; minor/patch is automatic via Dependabot.
- Dependabot config (`.github/dependabot.yml`) opens weekly PRs for action updates. PRs are reviewed and merged manually; no auto-merge.

### Node.js: LTS + 1

- CI runs Node LTS (currently Node 22 / "Jod"). Bump within 4 weeks of a new LTS shipping.
- `package.json` `engines.node` declares the minimum supported version. Today: `">=20.0.0"` for users; CI uses 22 for forward-compatibility checks.
- Bash 5+ floor is independent (per ADR-003-adjacent). zBuild is primarily bash; Node is only required for npm install / publish.

### npm dependencies

- Direct production dependencies: avoid where possible. zBuild's runtime is bash; Node is install-time only.
- If we add a Node dependency: pin minor in `package.json` (e.g., `^4.2.0`); Dependabot proposes weekly updates; major bumps reviewed manually.
- Lockfile (`package-lock.json`) committed.

### Enforcement

- **CI annotation watch**: any deprecation warning in a CI run is a soft signal. The maintainer reviews weekly Dependabot PRs.
- **Quarterly audit**: every quarter, manually verify all `actions/*@v<n>` references are within one major of latest, and Node engine version is current LTS or LTS-1.
- **Pre-release checklist** (in ADR-007 test strategy): before tagging a release, run `gh run list --limit 5 --json conclusion,annotations` and review any deprecation messages.

## Consequences

**Good:**
- Action / Node deprecations get PR'd before they break CI.
- One place to look (`dependabot.yml`) when something gets flagged.
- Quarterly audit catches drift even if Dependabot is paused.

**Bad:**
- Weekly Dependabot noise. Mitigation: `open-pull-requests-limit: 5` per ecosystem; we triage in batch.
- Action major-version bumps occasionally break CI (e.g., changed defaults). We accept this as the cost of staying current. PRs are reviewed before merge.

## References

- [GitHub: Deprecation of Node 20 on GitHub Actions runners](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/)
- [Dependabot docs](https://docs.github.com/en/code-security/dependabot)
- [ADR-007 — Test Strategy](ADR-007-test-strategy.md) — pre-release checklist hook
- This ADR was prompted by the 2026-05-24 CI warning on `actions/checkout@v4`.
