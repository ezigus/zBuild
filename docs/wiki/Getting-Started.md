# Getting Started

zBuild runs a task (like fixing a bug or adding a feature) through a *pipeline* — a fixed series of steps (plan, build, test, review, open PR) that runs the same way every time. This page walks you through your first two runs: a safe preview with no side effects, then a real run against a GitHub issue.

Before you begin, complete [[Installation]] and make sure you are inside a git repository you want zBuild to work on.

## Step 1: Try a dry run

A *dry run* exercises the full pipeline without writing any code or opening a pull request. It is the safest way to see what zBuild would do.

```bash
zbuild pipeline start --goal "Add an e2e test for the checkout flow" --dry-run
```

What happens:
- zBuild loads a *template* (a file that defines the pipeline steps; the default is `simple`) and walks through each *stage* (one named step in the pipeline).
- Progress is recorded as a stream of events. To watch them live, run `zbuild --attach <run_id>` in a second terminal, or read the file directly at `~/.zbuild/state/runs/<run_id>/events.jsonl`.

## Step 2: Run from a GitHub issue

Point zBuild at an issue number and it will plan, build, test, review, and open a pull request automatically:

```bash
zbuild pipeline start --issue 42
```

Useful flags:
- `--scope src/payment --scope tests/` — restrict which files the run may touch (the flag is repeatable).
- `--platform-override <p>` — override automatic platform detection.
- `--no-resume` — start a fresh run instead of continuing an interrupted one.

## Step 3: Resume an interrupted run

If a run stops partway through, zBuild can pick up where it left off:

```bash
zbuild --resume-latest            # resume the most recent run
zbuild --resume <run_id>          # resume a specific run
zbuild pipeline status            # show what would resume and from which stage
```

## Step 4: Inspect a running pipeline

```bash
zbuild status                     # overall pipeline status
zbuild --attach <run_id>          # live-tail events for a running pipeline
```

---

Where to go next:
- **[[Configuration]]** — choose AI models and templates, set per-repo overrides.
- **[[Pipeline-and-Stages]]** — understand what happens at each stage.
- **[[CLI-Reference]]** — every command and flag in one place.

## Advanced: what happens inside each stage

*Newcomers can skip this section — it covers engine internals you won't need until you're customising pipelines.*

Each stage's AI calls pass through the [redaction chokepoint](mechanics/redaction-chokepoint) before reaching the model, stripping secrets and sensitive paths. Events are written as newline-delimited JSON to `events.jsonl` and can be replayed or diffed for debugging.
