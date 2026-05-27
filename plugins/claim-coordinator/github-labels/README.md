# GitHub Labels Claim Coordinator

**Plugin id:** `claim-coordinator-github-labels`
**Kind:** `claim-coordinator`
**ADR:** [ADR-005 — Claim Coordinator Contract](../../../../docs/adr/ADR-005-claim-coordinator.md)

## Purpose

Default cross-machine claim coordinator for the zbuild daemon. Uses GitHub issue labels (`claimed:<machine>`) as the distributed claim mechanism so multiple daemon instances can coordinate over a shared repository without a central lock server.

## Contract (ADR-005)

| Hook | Signature | Returns |
|---|---|---|
| `claim_coordinator_init` | `init <run_id>` | 0 success, 2 fatal |
| `claim_coordinator_claim` | `claim <issue_number> <machine_id>` | 0 claimed, 1 already-claimed, 2 error |
| `claim_coordinator_release` | `release <issue_number> <machine_id>` | 0 released, 2 error |
| `claim_coordinator_heartbeat` | `heartbeat <issue_number> <machine_id>` | 0 alive, 2 expired |
| `claim_coordinator_list_claims` | `list_claims` | stdout: `issue:machine` lines |

## TOCTOU mitigation

The `claim` hook has a documented TOCTOU window between label-add and re-verify. Mitigated by:

1. Random backoff 300–1100 ms before re-read
2. Re-read drops the claim if multiple `claimed:*` labels are observed on the issue

## Configuration

| Key | Default | Description |
|---|---|---|
| `backoff_min_ms` | 300 | Minimum backoff before re-verify |
| `backoff_max_ms` | 1100 | Maximum backoff before re-verify |
| `machine_id` | `$(hostname)` | Override machine identity for the claim label |

## Test / CI mode

Set `ZBUILD_CLAIM_BACKEND=local-fs` and `ZBUILD_CLAIM_STORE=<dir>` to use a flock-serialised filesystem store instead of `gh`. Required for unit/integration tests that cannot make GitHub API calls.

## Legacy origin

Ported from `legacy/scripts/lib/daemon-state.sh:602-720`.
