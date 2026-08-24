[Phase 0/C10] restrict the model's write permissions — replace the blanket permission bypass (amends ADR-018)

Part of #1819 (Phase 0 — the stage↔engine contract). Third of three in the write-boundary chain: **C8 → #1809 → C10**.

**Build Mode: Dogfood** — ADR-057 gate 4. Derived, not inherited:

- **Gate 2 does not fire.** The hot-reloaded contract-reader set is the transitive closure of `_RUNNER_CONTRACT_LIB_ENTRYPOINTS` (`core/pipeline/runner.sh:1024-1031`) — six files, all under `scripts/lib`. `core/router/route.sh` is not one. The run is graded by the engine installed from `main` (ADR-023/#1629) and the work happens in a per-run worktree (ADR-052), so the change cannot affect the run building it.
- **Gate 3 does not fire.** It asks what a *defective merge* costs. `allow_auto_merge` is **false** on this repository and every PR is merged by a human after CI, so a defect must survive both to land. Gate 3's named examples — the pre-flight validator, `install.sh`, the template loader, `runner.sh:main()`, the event bus — are defects subtle enough to pass review and then brick every subsequent run. Two argv splices behind a probe-verified settings file are not that.
- **Verification is not a Build Mode input.** Neither a dogfood nor CI exercises the new flags (CI's router tests mock `claude` with an argv-recording PATH shim, so they enforce no permissions). That is exactly why the P0–P4 probes below are mandatory — but ADR-057 §1 is explicit: *"the question is **not** 'can the run test this change?' — it almost never can; **CI does that**."* Who verifies is a separate question from who writes.

**The probes remain a hard prerequisite** and are done by hand regardless of who writes the implementation. Do not start the build stage until P0–P4 results are in this issue.

**Classification: ENGINE — `core/router/route.sh` × ADR-018.**

## Problem

C8 and #1809 **detect** out-of-bounds writes. The reason a stage can make one is that the engine launches the model with permission checks **completely disabled**:

- `core/router/route.sh:807` (single-shot path)
- `core/router/route.sh:1557` (agent-loop path)

Both append `--dangerously-skip-permissions` unconditionally.

This was a deliberate, recorded decision. ADR-018 rests on it at lines 25, 28-33, 40, 41, 68, 350 and 462, justified by:

> Without `--dangerously-skip-permissions`, tools (Read/Edit/Write/Bash) are off by default in headless invocations.

**That claim was written against an older CLI and has not been re-measured.** The installed CLI is 2.1.235 and offers `--permission-mode {acceptEdits,auto,bypassPermissions,manual,dontAsk,plan}`, `--settings <file-or-JSON-string>` and `--add-dir`, none of which existed then. Reversing an accepted ADR requires an amendment, not a code edit.

## Measure first — five probes, before writing any code

Results pasted into this issue with the CLI version pinned. Not re-measuring is exactly how ADR-018's claim went stale; repeating that mistake here would be self-inflicted.

| Probe | Question |
|---|---|
| **P0** | `--permission-mode acceptEdits`, no settings — does a Write still work at all? Settles whether the ADR-018 claim still holds. |
| **P1** | + `--settings <file>` — does an in-bounds write still succeed? |
| **P2** | Out-of-bounds `Write` to `$HOME` — refused? |
| **P3** | Out-of-bounds via `Bash` (`bash -c 'echo x > $HOME/…'`) — **likely still succeeds.** |
| **P4** | `--add-dir <scratch>` — scratch write succeeds while `$HOME` stays denied? |

**If P3 succeeds, say so.** The ADR then records that prevention covers the Edit/Write surface while the command-line surface is covered only by C8's `TMPDIR` redirect and #1809's sweep. Do not claim what the probes do not show.

## Fix

Replace the blanket bypass at both sites with:

```
--permission-mode acceptEdits --add-dir <worktree> --add-dir <scratch> --settings <file>
```

`acceptEdits`, **not** `bypassPermissions` — the latter is the same blanket bypass renamed (`claude --help`: *"Bypass all permission checks"*). `acceptEdits` auto-approves edits without prompting, so ADR-018 Pattern 1 still works headless, while leaving the permission system **engaged** so deny rules are consulted. `manual` blocks headless; `plan` collides with the existing `--disallowed-tools EnterPlanMode,ExitPlanMode`; `auto`/`dontAsk` are underspecified in the help text and must not be adopted on a guess.

**Settings as a file**, at `${ZBUILD_STAGE_SCRATCH}/claude-settings.json` (a C8-sanctioned area), not an inline JSON string:

1. `-p` mode **silently ignores** a settings file that fails validation. A file can be `jq`-validated and the spawn **refused**; an inline string is already argv by the time you would notice.
2. It keeps argv a stable token set for the NUL-recording PATH shims the flag tests use.
3. It is a durable, diffable record of what was actually granted.
4. It keeps policy out of `ps` and shell history.

Built **before** `_zbuild_make_fresh_shell` runs — the same "restate it before the scrub" pattern already at `core/router/route.sh:368-372`.

**Implementation in `core/router/permissions.sh` (new).** `route.sh` carries only the two `_claude_args+=( … )` splices, so reverting the WIRING file leaves a correct-but-uninvoked lib and Level 3 is a genuine experiment rather than a wholesale revert. The settings write must stay inside `core/router/` or `tests/unit/redaction-chokepoint-test.sh:47,66-70` bites.

## Acceptance

```acceptance
SPEC-1[change]: the model spawn carries --permission-mode acceptEdits and --settings instead of the blanket permission bypass.
SPEC-2[change]: the settings file grants exactly the worktree and this stage's scratch dir, and is jq-valid before the spawn.
SPEC-3[guard]: an unparseable settings file refuses the spawn rather than silently spawning unrestricted.
SPEC-4[guard]: the blanket permission-bypass flag appears nowhere in core/router/.
TESTFILES:
  tests/unit/router-claude-flags-test.sh
  tests/unit/router-permissions-test.sh
  tests/integration/router-claude-flags-test.sh
WIRING:
  core/router/route.sh
```

- [ ] P0–P4 results recorded in this issue, with the CLI version, **before** implementation.
- [ ] `docs/adr/ADR-018-*.md` carries an `**Amended:**` line superseding lines 25, 28-33, 40, 41, 68, 350, 462; the line-28 claim is replaced by the P0 result and the CLI version.
- [ ] `tests/unit/router-claude-flags-test.sh:86,103` and `tests/integration/router-claude-flags-test.sh:114` updated in the file's existing order-insensitive token-set style (`:73-77`).
- [ ] `tests/unit/stage-checkpoint-test.sh:259-271` still green (it greps `route.sh` for two literal source strings in the retry loop, well away from `:807`/`:1557`).
- [ ] `grep -rn 'skip-permissions' docs/wiki/` clean.
- [ ] Full dogfood end-to-end: **every** LLM stage still produces its artifact. A stage that silently lost a tool shows up as a thin or empty artifact, not a crash — that is the failure mode to watch for.
- [ ] Reddens at the merge-base.

## Ordering

Land **after #1809**, deliberately. Run a few dogfoods with detection on, read the actual `stage.write_boundary.violated` records, and write the deny list from evidence rather than guesswork — so the ADR-018 amendment can cite what the sweep really saw.

Where: `core/router/permissions.sh` (new), `core/router/route.sh:807,1557`, `docs/adr/ADR-018-stage-invocation-modes.md`. Refs #1809, C8, #466 (adopted the flag), ADR-018, ADR-024.




---

## Note 2026-08-23 — one input to the probes changes later (ADR-059)

No change to this issue's scope, Build Mode, or the P0–P4 probe requirement. One thing to be aware of when the settings file / `--add-dir` set is written.

[ADR-059](../blob/main/docs/adr/ADR-059-issue-vs-run-keying.md) moves everything zBuild writes under one base and re-keys the worktree from `run_id` to the **issue**:

```
$ZBUILD_HOME/repos/<repo>/issues/<N>/worktree/          (was ~/.zbuild/runs/<run_id>/worktree)
                                    /runs/<run_id>/     scratch, runtime/, events
```

Two consequences for a permission allowlist:

1. **Any allowed path written as a literal will be wrong after the layout move.** Derive the allowed roots from the same env vars ADR-058 §1 exports (`ZBUILD_REPO_ROOT`, `ZBUILD_STATE_DIR`, `ZBUILD_STAGE_SCRATCH`) rather than from a path pattern. Six of the ~17 existing call sites fail **silently** when that root moves; a permission allowlist that silently widens or narrows would be a seventh, and a worse one.
2. **The worktree becomes durable.** Today a stray model write into the tree dies with the run. Under ADR-059 the tree belongs to the issue and survives every run of it, so an over-broad grant has a longer blast radius. That argues for this issue, not against it — but it is a reason not to defer it past the layout move.

ADR-058's five areas are unchanged in number and in identity; only their **lifetimes** and paths change (ADR-058 §7).

Refs ADR-058 §1 §7, ADR-059 §1 §5, #1809.
