# Resume Contract — Plugin Author Cheat-Sheet

Operational reference for what state survives `kill -9` and what doesn't. Full rationale in [ADR-006](adr/ADR-006-resume-contract.md). This doc tells you what to do.

## TL;DR

zBuild persists **only** what plugins declare in their manifest's `state.persisted`. Everything else is reconstructed on resume by the plugin's `init` hook. The engine refuses to resume if a `reconstructed` key isn't set before any `run` invocation.

## Persisted state (engine guarantees survival)

Written via `core/state/atomic_write` (with `.bak` rotation). Survives `kill -9`, OS panic, USB-power-yank.

| Key | Owner | Notes |
|---|---|---|
| `stage_statuses` | engine | per-stage enum |
| `current_iteration` | engine | **fixed** vs legacy resume gap; always restored on resume |
| `self_heal_count` | engine | per-stage retry counter |
| `scope_manifest_hash` | engine | detects scope changes across resume |
| `cost_ledger_pointer` | engine | resume continues cost tracking |
| `claim_lease_id` | engine | required for claim-coordinator heartbeat after resume |
| `plugin_state[<id>]` | per-plugin | YOU write this via `set_state_field` |

## Reconstructed state (you recompute on `init`)

Cheap to recompute, expensive to persist, OR derivable from other persisted state.

| Key | Owner | How to reconstruct |
|---|---|---|
| `git_diff` | per-stage | `git diff <baseline>` |
| `repo_hash` | engine | hash of `git rev-parse HEAD` |
| `env_snapshot` | per-stage | re-read env vars |
| `router_recommendations` | engine | recompute from cost ledger + outcomes |
| `scope_violations_history` | engine | replay from event bus |
| `loop_state_md` | debug | regenerate; gitignored |

## What you do as a plugin author

### 1. Declare in your manifest

```yaml
state:
  persisted: [last_findings, last_cycle_score]
  reconstructed: [git_diff]
```

### 2. Write persisted state via the engine

```bash
# In plugin.sh:
my_plugin_run() {
    # ...
    set_state_field "$ZBUILD_STATE_FILE" '.plugin_state."my-plugin".last_cycle_score' '95'
}
```

DO NOT write your own state files. They won't be backed up; they won't be cleaned up; they won't survive resume reliably.

### 3. Reconstruct in `init`

```bash
# In plugin.sh:
my_plugin_init() {
    if [[ "${ZBUILD_RESUMING:-0}" == "1" ]]; then
        # Recompute reconstructed state
        MY_GIT_DIFF="$(git diff --name-only)"
        if [[ -z "$MY_GIT_DIFF" ]]; then
            error "my-plugin: required reconstructed state missing"
            return 1
        fi
    fi
}
```

### 4. Refuse to run if reconstructed state is missing

The engine doesn't enforce this with type checking — you do. Refusing in `init` produces a loud, immediate failure instead of a silent wrong-answer later.

## What the engine guarantees on resume

1. All `persisted` keys are restored before any plugin observes them.
2. The engine emits `pipeline.resume` event.
3. The engine sets `ZBUILD_RESUMING=1` in the environment of all `init` calls.
4. If `init` fails, the engine refuses to continue (no silent half-resume).
5. If `pipeline-state.json` is corrupt, the engine recovers from `.bak` via `validate_json`. If both are corrupt, the engine refuses to resume.

## What the engine does NOT guarantee

- Identical behavior to an uninterrupted run. LLM nondeterminism makes this impossible. Plugins that depend on identical-behavior-across-resume are broken by design.
- Cost equivalence. Resume re-runs `init`, may re-route models, may re-pay for some computation.
- Wall-clock continuity. Resume adds startup latency proportional to `state.persisted` size and `init` cost.

## Testing your plugin's resume behavior

Minimum test (lift from `tests/core-state-test.sh`):

```bash
# Step 1: init + write some persisted state
my_plugin_init
my_plugin_run "$@"  # writes plugin_state."my-plugin".last_score

# Step 2: simulate kill + restart
unset _MY_PLUGIN_LOADED  # force re-source
source plugins/agent/my-plugin/plugin.sh
export ZBUILD_RESUMING=1
my_plugin_init

# Step 3: verify reconstructed state is set
assert_eq "git_diff reconstructed" "non-empty" "$([[ -n "$MY_GIT_DIFF" ]] && echo non-empty || echo empty)"

# Step 4: verify persisted state still readable
score="$(get_state_field "$ZBUILD_STATE_FILE" '.plugin_state."my-plugin".last_score' '0')"
assert_eq "last_score persisted across resume" "95" "$score"
```

For high-confidence: actually `exec` a new bash process and verify state survives the process boundary. See `tests/core-state-resume-exec-test.sh` for the pattern.
