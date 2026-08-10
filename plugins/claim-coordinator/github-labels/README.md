# GitHub Labels Claim Coordinator

**Plugin id:** `claim-coordinator-github-labels`
**Kind:** `claim-coordinator`
**ADR:** [ADR-005 — Claim Coordinator Contract](../../../../docs/adr/ADR-005-claim-coordinator.md)

## Purpose

Default cross-machine claim coordinator for the zbuild daemon. Uses GitHub issue labels (`claimed:<machine>`) as the distributed claim mechanism so multiple daemon instances can coordinate over a shared repository without a central lock server.

## Contract (ADR-005)

| Hook | Signature | stdout | Exit codes |
|---|---|---|---|
| `claim_coordinator_claim` | `claim <issue_id>` | `{"acquired": bool, "lease_id": "<machine>:<issue>", ...}` | 0 attempted (check JSON), 1 backend error, 2 usage error |
| `claim_coordinator_release` | `release <issue_id> [lease_id]` | — | 0 always |
| `claim_coordinator_heartbeat` | `heartbeat <lease_id>` | — | 0 always (labels don't expire) |
| `claim_coordinator_list_claims` | `list_claims` | `[{"issue": N, "holder": "...", "acquired_at": null}]` | 0 success, 1 backend error |

## TOCTOU mitigation

The `claim` hook has a documented TOCTOU window between label-add and re-verify. Mitigated by:

1. Random backoff 300–1100 ms before re-read
2. Re-read drops the claim if multiple `claimed:*` labels are observed on the issue

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ZBUILD_CLAIM_BACKEND` | `gh` | Backend: `gh` (GitHub API) or `local-fs` (flock-serialised filesystem, for tests) |
| `ZBUILD_CLAIM_MACHINE_ID` | `$(hostname)` | Override machine identity used in the claim label |
| `ZBUILD_CLAIM_BACKOFF_MIN_MS` | `300` | Minimum backoff (ms) before re-verify after label-add |
| `ZBUILD_CLAIM_BACKOFF_MAX_MS` | `1100` | Maximum backoff (ms) before re-verify |
| `ZBUILD_CLAIM_FLOCK_TIMEOUT_SEC` | `5` | flock wait timeout for local-fs backend |
| `ZBUILD_CLAIM_STORE` | _(required for local-fs)_ | Directory for local-fs label files |

## Test / CI mode

Set `ZBUILD_CLAIM_BACKEND=local-fs` and `ZBUILD_CLAIM_STORE=<dir>` to use a flock-serialised filesystem store instead of `gh`. Required for unit/integration tests that cannot make GitHub API calls.

## Legacy origin

Ported from `legacy/scripts/lib/daemon-state.sh:602-720`.
