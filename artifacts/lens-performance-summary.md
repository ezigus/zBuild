## review-lens-performance — pass

- found: low: Two grep-based subshell spawns parse the `acquired` field from JSON on every acquire path, while `jq` is already imported and used immediately below for the `holder` field. (core/claim/claim.sh)

- low: Two grep-based subshell spawns parse the `acquired` field from JSON on every acquire path, while `jq` is already imported and used immediately below for the `holder` field. (core/claim/claim.sh)
- score: 9
