# CLI Reference

The `zbuild` command-line tool is the main way you interact with zBuild. You use it to start pipelines, resume interrupted runs, check status, and maintain your installation.

**Basic pattern:** `zbuild <command> [args…]`

Run `zbuild --help` at any time for a built-in summary.

---

## Start here — the everyday commands

If you're new to zBuild, these five commands cover most of what you'll do day-to-day:

1. **Start a pipeline on a GitHub issue:**
   ```
   zbuild pipeline start --issue 42
   ```

2. **Start a pipeline with a plain-text goal:**
   ```
   zbuild pipeline start --goal "Add pagination to the search results page"
   ```

3. **Resume a pipeline that was interrupted:**
   ```
   zbuild --resume-latest
   ```

4. **Check the status of the current pipeline:**
   ```
   zbuild status
   ```

5. **Validate your installation (run this if something seems broken):**
   ```
   zbuild doctor
   ```

---

## Session shortcuts

These flags can be used directly without a subcommand:

| Flag | What it does |
|---|---|
| `zbuild --resume <run_id>` | Resume a specific interrupted run (shorthand for `pipeline resume --run-id <id>`) |
| `zbuild --resume-latest` | Resume the most recent interrupted run |
| `zbuild --attach <run_id>` | Follow live output (`events.jsonl`) for a running pipeline, filtered to that run |

---

## Commands

### `pipeline start`

Start a new pipeline run. You must provide either `--issue` or `--goal`.

```
zbuild pipeline start --issue <N> | --goal "<text>"
                      [--dry-run]
                      [--platform-override <p>]
                      [--scope <path>]...        (repeatable; validated: no absolute, no ..)
                      [--no-resume]
                      [--mcp-server <url>]...     (repeatable)
                      [--mcp-transport stdio|sse]
                      [--mcp-timeout <seconds>]
```

- `--issue <N>` — run the pipeline against GitHub issue number N.
- `--goal "<text>"` — run the pipeline against a free-text goal (use this if you don't have a GitHub issue).
- `--dry-run` — plan and evaluate without making any changes to files or branches.
- `--scope <path>` — add an allowed path for file access (see [[mechanics/scope-governance]]). Repeatable.
- `--mcp-server`, `--mcp-transport`, `--mcp-timeout` — configure MCP (Model Context Protocol) connections. These export `ZBUILD_MCP_SERVERS`, `ZBUILD_MCP_TRANSPORT`, and `ZBUILD_MCP_TIMEOUT` respectively.

### `pipeline resume`

Resume the most recent interrupted or in-progress run, or a specific run by id.

```
zbuild pipeline resume [--run-id <id>] [--from-stage <stage>] [--force]
```

- `--run-id <id>` — target a specific run (omit to resume the most recent).
- `--from-stage <stage>` — restart from a specific stage instead of where the run left off.
- `--force` — override an abort status and resume anyway.

### `pipeline status`

Show the resume recommendation for the current (or specified) state file.

```
zbuild pipeline status [--run-id <id>]
```

### `cleanup`

Prune stale artifacts left behind by previous runs. Every category is reported whether or not it has anything in it, so you can see what is accumulating without deleting a thing.

**Default behavior: dry-run, all categories except `--worktrees`.** Nothing is deleted unless you pass `--apply` or `--force`.

```
zbuild cleanup [--branches] [--state-dirs] [--stashes] [--tmpdirs]
               [--scratch] [--state-branches] [--orch-pools] [--cache]
               [--worktrees]
               [--dry-run|--apply|--force]
               [--age-days N]   (default 7 — see "two clocks" below)
               [--age-hours N]  (stashes, tmpdirs, orch pools; default 1)
               [--restore-stash <N> --apply]
               [--quiet]
```

| Category | What it reclaims |
|---|---|
| `--branches` | `zbuild/issue-*` work branches |
| `--state-branches` | `zbuild/state/issue-*` prior-work snapshots |
| `--state-dirs` | whole job folders — `~/.zbuild/state/runs/<run_id>/` and everything in them (artifacts, events, stage I/O, scratch), plus legacy flat state files |
| `--scratch` | per-stage scratch — usually the largest consumer on disk |
| `--stashes` | `zb-applycheck-*` git stashes |
| `--tmpdirs` | leaked zbuild temp directories |
| `--orch-pools` | orchestrator slot pools from runs that did not exit cleanly |
| `--cache` | the content cache at `~/.zbuild/cache/` |
| `--worktrees` | dead-run worktrees + stale git worktree registrations (opt-in) |

**The memory store is never reclaimed.** It is deliberately agnostic to the issues it supports, so no category targets it.

#### Two clocks

There is one retention number, but it is measured from different starting points depending on what the thing is:

- **Things keyed to an issue** — `--branches`, `--state-branches` — age from the moment the **issue closes**. While an issue is open, its work branch holds unmerged code and its state branch holds the prior work the next run reuses, so ageing them from last touch would delete live work mid-flight.
- **Everything else** ages from its own **last touch**. Scratch, temp dirs, pools and cache entries are garbage or regenerable.

If the issue's state cannot be established — no `gh`, an API error, an unreadable answer — the target is **kept, never pruned**. An issue that no longer exists falls back to plain age.

`--worktrees` stays opt-in because reclaiming a worktree discards a whole checkout. It honours `--age-days`, so `--age-days 0` reclaims a run that died today. It never touches a tree with uncommitted work, and the branch itself always survives — a branch ref lives in the repository, not in the worktree holding it.

### Other commands

| Command | Purpose |
|---|---|
| `zbuild status` | Pipeline status (JSON) |
| `zbuild doctor` | Validate install + config (checks bash≥5, gh, jq, sqlite3, and more) |
| `zbuild plugin list` | List all discovered plugins |
| `zbuild deferred <sub>` | Deferred-work scanners (`backfill` \| `tracker`). Run `zbuild deferred --help`. |
| `zbuild manifest <sub>` | Manifest YAML drift management (`sync`). Run `zbuild manifest --help`. |
| `zbuild upgrade --from <dir>` | Re-run `install.sh` from a source clone (pulls `main` first) |
| `zbuild --version`, `version` | Print version — semver from `config/VERSION`; sha/branch from install metadata when set |
| `zbuild --help`, `help`, `-h` | Show help |

---

## Exit codes

`0` means success. Any non-zero value indicates failure.

The engine also uses internal signal codes between pipeline stages — for example, a route-back signal (rc=11) or a blocking-gate halt. See [[Troubleshooting]] and [[mechanics/event-bus]] for how to read what happened when something non-obvious occurs.
