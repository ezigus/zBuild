# Troubleshooting

Something isn't working. Start here.

## Step 1: run the doctor

```bash
zbuild doctor
```

This checks that all prerequisites are installed and configured correctly (bash ≥ 5, `gh`, `jq`, `sqlite3`, and others). Fix anything it flags before digging deeper — most setup problems show up here.

## Step 2: check the common issues list

**`command not found: zbuild`**
`~/.local/bin` isn't on your `PATH`. Add this to your shell profile and restart your terminal:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

**Bash version error**
macOS ships with Bash 3.2, which is too old. Install Bash 5:
```bash
brew install bash
```
Then make sure the new Bash appears first on your `PATH`.

**Timeouts don't seem to fire (macOS)**
macOS doesn't include `gtimeout`. Install it with:
```bash
brew install coreutils
```
See [[Installation]] for the full macOS setup checklist.

**`flock` missing**
The local-filesystem claim backend requires `flock`:
```bash
brew install flock        # macOS
apt install util-linux    # Debian / Ubuntu
```

## Step 3: inspect the run

If a run started but something went wrong inside it:

**Watch it live:**
```bash
zbuild --attach <run_id>
```

**Read the event log** — every action zBuild takes is recorded here:
```
~/.zbuild/state/runs/<run_id>/events.jsonl
```

**Read the pipeline state** — what stage the run reached, and what verdict it got:
```
~/.zbuild/state/runs/<run_id>/pipeline-state.json
```

A `latest` symlink always points at the most recent run, so you can also use:
```
~/.zbuild/state/runs/latest/events.jsonl
```

## Step 4: resume an interrupted run

If a run stopped in the middle, you can pick it up where it left off:

```bash
zbuild pipeline status            # show what would resume, and from where
zbuild --resume-latest            # resume the newest run
zbuild --resume <run_id>          # resume a specific run
zbuild pipeline resume --run-id <id> --force   # override an abort status
```

## Step 5: clean up stale artifacts

Old branches, state files, and temporary directories can accumulate. Clean them up:

```bash
zbuild cleanup            # dry-run: shows what would be removed
zbuild cleanup --apply    # actually remove it
```

---

## Advanced — diagnosing cycles and engine internals (newcomers can skip)

### A cycle didn't converge

A **cycle** is a stage that repeats until its quality check passes or it hits a maximum attempt count. When it hits the max, it follows the `on_max` policy (often `continue`, meaning it moves on rather than aborting the run).

To diagnose why a cycle didn't converge, look for these events in `events.jsonl`:

- `cycle.plateau` — the cycle ran out of attempts without improving.
- `cycle.stalled` — the cycle is producing the same output repeatedly (stuck-detector fired).
- `cycle.unconverged` — the cycle exited without the success condition being met.

See [[mechanics/convergence]] for the full convergence protocol.

### Reading the event log

The event log at `~/.zbuild/state/runs/<run_id>/events.jsonl` records every `pipeline.*`, `stage.*`, `plugin.*`, `model.*`, `cycle.*`, and `redaction.*` event in order. Each line is a JSON object. You can filter it with `jq`:

```bash
# Show only stage events
jq 'select(.type | startswith("stage."))' \
  ~/.zbuild/state/runs/latest/events.jsonl

# Show the final verdict for each stage
jq 'select(.type == "stage.complete") | {stage: .stage, verdict: .verdict}' \
  ~/.zbuild/state/runs/latest/events.jsonl
```

See [[mechanics/event-bus]] for the full event schema.

### Diagnosing CI stage timeouts

Stage timeouts surface as a non-zero exit code from the pipeline stage, but the
_reason_ (turn count exhausted, wall-clock budget hit, SIGTERM mid-call vs
mid-emit) is only visible in the Claude session transcript — not in the stage
return code or raw output.

**Local runs:** read the transcript directly from the Claude CLI's project
directory:
```
~/.claude/projects/<repo-slug>/<session-id>.jsonl
```
Each line is a JSON object. Look for `turn_count`, elapsed-time fields, and
whether the final assistant turn was cut off mid-emission.

**CI runs (any outcome):** download the `pipeline-artifacts-issue-N-<run-id>`
zip from the GitHub Actions run summary. Every session the CLI wrote during the
job is bundled, encrypted, at the top of the artifact:
```
pipeline-artifacts-issue-N-<run-id>/
  claude-transcripts.tar.gz.enc
```
Decrypt with the repo secret `ZBUILD_TRANSCRIPT_KEY` (the value lives only in
the GitHub secret and in the operator's local copy — never in the repo):
```
ZBUILD_TRANSCRIPT_KEY=... openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass env:ZBUILD_TRANSCRIPT_KEY -in claude-transcripts.tar.gz.enc | tar -xz
```
which yields `<encoded-cwd>/<session-id>.jsonl`, one file per model call. To
find the call for a stage, match the session's first record (it holds the
prompt, which opens with the stage banner, e.g. `ZBUILD BUILD — iter 3/10`)
against the `model.route` / `loop.iteration` timestamps in `events.jsonl`.

The collect step runs on success, failure, AND cancellation (a 6-hour GitHub
kill is `cancelled`, so a `failure()`-only step misses exactly the runs that
need it). The job log lists every transcript found with its size; "collected 0"
means the CLI wrote no session, which is itself a finding. If the secret is not
set on a public repository the step collects nothing and says so in a warning:
```
openssl rand -hex 32 | tee ~/.zbuild/transcript.key | gh secret set ZBUILD_TRANSCRIPT_KEY
```
JSONL is not redacted before upload — the encryption is the access control that
stands in for redaction (the claude process carries the OAuth token in its
environment, so a transcript can contain it).

**Key distinction:** the 300 s wall-clock budget and the per-stage turn cap
are separate limits. A timeout that hits the turn cap looks different from one
that hits the wall clock — the difference is only visible in the transcript.
