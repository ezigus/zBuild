# ADR-065 — Process budget: the engine's fork count is a tested contract

**Status:** Accepted (2026-09-19)
**Issue:** #2151
**Related:** ADR-001 (Discovery + lockfile), ADR-012 (test tiering), ADR-053 (test flake policy — the serial-pin cap that also needs an amendment to raise), ADR-041 (the fd-9 lock discipline the trace harness must respect)

## Context

zBuild is bash. Every `$(jq …)`, `$(dirname …)`, `$(awk …)` is a fork and an exec, and the
engine does them by the thousand: on 2026-09-19 `source core/pipeline/runner.sh` execs 1,375
processes before any stage runs (1,050 of them `awk`), and a mocked seven-stage pipeline run
(`tests/golden/parity/run-fixture.sh`) execs about 7,100. The suite is therefore fork-bound, not
compute-bound: #1840 run 1 (35184719395) spent 4,910 of its 6,989 CPU-seconds in the kernel
creating processes. Fork throughput scales with cores, so the same suite takes ~15 minutes on a
10-core Mac and ~58 minutes inside the daemon's `test` stage on a 4-vCPU GitHub runner — the
single largest cost in every long run. Buying larger runners was considered and rejected: it
hides the cost rather than removing it.

A census by call site (bash xtrace with `PS4='+@${BASH_SOURCE[0]-}:${LINENO}@ '`) put a third
of the mocked run's execs on one line — `core/pipeline/input-resolve.sh:113`, an awk per manifest
inside `_inputs_scan_manifests`, whose memo is never filled in the parent shell and whose every
caller runs it inside `$( )`: 41 calls × 55 manifests. The next third is `yaml_cache_prewarm`
(one awk per manifest per key, 55 × 12) and the event bus (a `sed` per key and value, a `jq` per
key, a `date` and a `mkdir` per event). None of this is inherent; all of it was invisible because
nothing measured it.

## Decision

### §1 — The number is a contract

The engine's external process count on the mocked full run is a tested quantity, held by
`tests/e2e/fork-budget-test.sh` as `FORK_BUDGET`. The test runs the parity fixture under bash
xtrace (`BASH_ENV` injecting `set -x`, `PS4` stamping `source:line`, `BASH_XTRACEFD=7` — fd 3 is
stage-io, 8 is coverage, 9 is flock), classifies each traced command word as external when the
test shell resolves it to a file on `PATH` (or it is one of the fixture's mocks), and asserts the
total is within budget. Its failure output is the diagnosis: the top call sites and per-file
totals, so the next reader starts where the forks are.

> **Amended 2026-09-30 (#2236).** The count must not depend on load. The same tree measured 4,528
> alone and 4,610 inside a full `npm test`: the worker pool's wait loop
> (`core/orch/local_engine.sh`) ran `sleep 0.1` and `date +%s` once per poll, so it counted elapsed
> time, not code (18 polls quiet, 44 under load). The clock read is now `$EPOCHSECONDS`, a builtin,
> and a wait whose repeat count is elapsed time carries `# fork-budget-exempt: <why>` on its line. The
> test lists marked sites apart ("exempt waits") and does not count them. The marker is only for a
> poll's wait, never for work: a marked line that execs anything other than the wait hides real forks.

### §2 — The budget only ratchets down

A PR that removes forks lowers `FORK_BUDGET` to just above its new measurement. A PR that must
raise it says why in an amendment to this ADR (the ADR-053 §5 precedent for the serial-pin cap).
"It is only a few hundred more" is not a reason; the run-4 postmortem of #1840 is what a few
hundred per stage per iteration adds up to.

> **Amended 2026-10-01 (#1842): raised to 6,340, with the reason.** The measured fixture
> (`tests/golden/parity/run-fixture.sh`) was not running what production runs:
> - Its mock repo was never a git repo. `/usr/bin/env git init` resolved to the fixture's own mock `git`, which does nothing.
> - Its mock `rev-parse` answered with a made-up path.
> - Hydrate, build's diff and persist's snapshot therefore all failed fast and cheaply.
> - It ran `review-aggregator` over zero lenses. That "ready" review is what let `pr-open` open a PR (#1753), and #1842 now refuses it.
>
> The fixture now has a real repo and the production review family, one lens wide. That costs about 1,900 execs that a real run was always paying. Separately, the counter read words inside a quoted assigned value as commands (`v='review lens: security'` counted macOS's `security` binary). That accounted for 132 execs on main's fixture; SPEC-1b holds the fix. Measured: main's fixture 4,367 with the fixed counter, #1842's fixture 6,280 (macOS). The largest new site, persist's two `git` processes per artifact file, is #2249, which ratchets this back down.

> **Ratcheted 2026-10-02 (#2249): 6,340 → 5,740.** Persist staged each artifact with two `git` processes; it now stages a whole snapshot with two (`hash-object --stdin-paths`, `update-index --index-info`), and falls back to per-file staging only when a batch fails (#1878). The fixture's local git plumbing now reaches real git, so its snapshots save instead of failing fast. Measured 5,685 on macOS.

### §3 — A memo is only as good as its fill in the parent shell

`$( … )` and `< <( … )` fork: the child inherits every associative array the parent has filled
and can never write back. A memo that is consulted from a subshell but filled only inside one is
not a memo — `_inputs_scan_manifests` ran 2,255 awks with its `_IR_SCAN_KEY` guard "in place".
The rule: every per-run memo is filled once, in the parent, at a prewarm seam that runs before
anything reads it from a subshell (`core/pipeline/runner.sh` warms the yaml cache and discovery
at file scope before `core/orch/contract.sh` is sourced — #2105 — and again in `main()`). A memo
that cannot be filled in the parent, because the reader is a separately spawned plugin process,
may instead be file-backed under `$ZBUILD_STATE_DIR/runtime/` with an explicit flush and the
shared `ZBUILD_YAML_CACHE=0` kill switch — the `known-event-types.cache` (ADR-001 §Declared
events) and `mgraph-memo` (#2129) precedents.

### §4 — One pass, not one per key

A reader over N manifests forks once — `awk` with an `FNR == 1` reset over the whole file list —
never N times and never N × K for K keys. `eb_manifest_events`
(`core/event-bus/known-types.sh`) is the existing example. The manifest index (#2152) applies
this to the yaml prewarm and `_inputs_scan_manifests`.

### §5 — Named, not planned

The census also names the event bus's per-event processes, the `$(dirname` / `$(basename` /
`$(cat` idioms (363 / 59 / 235 sites in the engine; `${p%/*}`, `${p##*/}`, `$(<f)` are free),
`manifest_graph_collect`'s per-hit awk and `cksum`, and `validate_manifest`'s three direct awks
per manifest per walk. Each is a later ratchet; this ADR does not schedule them.

> **Amended 2026-10-10 (#1806): the event bus's per-event processes are gone.** One
> `eb_emit_event` used to start a `jq` per field plus one for the envelope, a `date`, a `mkdir`,
> and, with the SQLite mirror on, a `sed` per mirrored field (about 22 for an 11-field event). It
> now starts one `jq`, which builds the fields and the envelope together, and the jsonl lock's
> `flock`; the mirror adds its `sqlite3` and lock. The clock is `EPOCHREALTIME` read by the shell,
> which also gives macOS real milliseconds, and the SQL quoting is a parameter expansion. The
> fields reach `jq` as numbered `--arg` pairs, never a positional list, because `jq` reads
> options after `--args` and a value such as `-n` must stay a value.
> Ratcheted 5,480 → 5,040 (measured 4,991 on macOS).

> **Amended 2026-10-24 (round 4): the SQLite event mirror is removed.** Every event was written
> twice: to `events.jsonl`, which everything reads (`eb_query_events`, the status comment, the stage
> reports, the tests), and to `events.db`, which nothing read — the bus's own comments said so ("jsonl
> is the only read path", "a dropped row is harmless"). The copy cost a lock and a `sqlite3` on every
> event, about 9,600 processes in the 60 slowest test files alone. `eb_emit_event` now writes
> `events.jsonl` only; `ZBUILD_EVENTS_DB` is no longer read. `sqlite3` stays an optional tool for the
> memory-sqlite plugin, so `zbuild doctor` still checks for it. ADR-006, ADR-035 and ADR-041 are
> amended to match.

> **Amended 2026-10-24 (round 4): a call stays only if something needs it.** Every program on a
> path that runs for each file write, event or state update must have a reader or protect a
> guarantee:
> - `atomic_write` dropped its `df` free-space check (a full disk fails the write, which already
>   refuses and leaves the target untouched, #1773) and `mktemp` (the shell opens the temp file with
>   noclobber). It rotates a `.bak` only when asked (`--bak`), which only the state writers do,
>   because only state recovery reads a `.bak`. It tries `stat` in the platform's flavour first.
>   Replacing a file went from 10 programs to 4 on macOS.
> - `locked_state_update` names its work files in the shell, copies the state with the shell, and
>   reads the collision guard's run id, status and age with one `jq` against the shell's clock (no
>   `dirname`, `mktemp`, `cp` or `date`).

> **Amended 2026-10-25 (round 6): one cache key per path; the per-dispatch checks run in the
> shell.**
> - A manifest cache keys a path with `//` collapsed. The runner filled the caches from the env's
>   spelling of the plugins root (`$TMPDIR` ends in `/`) while stages read with `cd && pwd`'s,
>   so every stage rebuilt the index.
> - The write boundary's mark and check start only `git` (the root check once per shell, then
>   `status`), the `find` sweeps and the clock probe's `rm`; the directory names, marker,
>   writes-declaration read and changed-path comparison are done by the shell.
> - The producer index joins the flow in the shell before its memo check, and a
>   `manifest_graph_collect` memo hit reads its file and the manifest's id in the shell.
> - The manifest's outputs block (the primary output, each output's record, format and
>   summary flag) is read by the shell, with the awk readers' exact answers; the index follows a
>   plugin dir linked in by a symlink.
> - A run's default branch, persist's git dir and a stage's time limit are asked once per shell;
>   a trunk that does not resolve and a git-dir lookup that fails are asked again.

> **Amended 2026-10-25 (round 5): per-stage chores read once.** Sourcing the engine starts no
> process; a mocked run's programs came from chores repeated for every stage, file or event:
> - Persist's secret scan ran five programs per artifact file. It now runs two `grep`s over the
>   whole directory, and the per-file check only on the files they name, in the same order, so
>   the reported file and kind are unchanged.
> - The attempt record sums only outputs that can compare (one that exists now and had a sum
>   before), reads the manifest once per dispatch, and is written by one `jq`.
> - `atomic_write` opens its temp file with the mode it must end with, so a mode without an
>   execute bit needs no `chmod`; `atomic_replace` makes its temp name in the shell.
> - An event whose fields are plain ASCII is written by the shell, byte for byte as `jq` would
>   write it; anything else still goes through `jq`. The lock stays: one append is not one atomic
>   write for a long line.
> - A router-knob lookup is one `awk`; a requires.core check strips `plugin.sh` once and parses
>   the list once.
>
> A mocked run went from 3,955 programs to 3,098, and from 5,852 processes to 5,255.

> **Amended 2026-10-24: more of the named sites are one pass.** The budget's run is one mocked
> pipeline (4,808 programs), but a single test file started up to 22,701, because tests run the same
> engine paths many times. `scripts/lib/fork-census.sh <cmd...>` now counts any command, with the
> same counter the budget uses. Measured on the ten slowest files, these were the largest sites, and
> each now reads its input once:
> - `manifest_graph_collect` read every manifest's `id:` with its own `awk` on a miss, and a stage
>   bound by role (a review lens, the acceptance check) is always a miss. It is now one `awk` over all
>   of them. `manifest_graph_resolve_member`'s role walk read `provides.role` the same way and is
>   also one `awk`.
> - `validate_manifest` checked requires-present, requires.core-is-a-list, `summary` and `usage`
>   with four `awk`s per manifest, on every discovery walk. They are now one.
> - `atomic_write`, which every engine file write goes through, ran `dirname`, `tail` and `awk`
>   around its free-space `df`. The shell does that now.
> - The run-status comment read each field of each row and of the header with its own `jq`, and
>   each time shown cost a `jq` and a `date`. It now uses one `jq` per row and one for the header,
>   and the clock is shell arithmetic and `printf '%(…)T'`. The render test went from 22,701 to 4,612.
>
> Ratcheted 5,040 → 4,440 (measured 4,378 on macOS).

> **Amended 2026-10-24 (round 2): the suite's schedule, and discovery's memo across processes.**
> The full local suite took 519s on a 10-CPU Mac. Integration finished last: its serial-pinned files
> ran first, one after another (141s), before its pool started, and the pool took files
> alphabetically, so a 180s file could start last.
> - The pinned files now run one at a time in their own lane while the pool runs.
> - The pool starts files longest-first by `tests/test-durations.tsv`, written from a timing log by
>   `scripts/lib/test-durations.sh`. A file with no recorded time starts first. Results are still
>   reported in file order.
> - A tier runs at most 6 files at once by default, not 8. The tiers run together and starting
>   programs is what saturates the machine: 6 per tier took 473s where 8 took 519–531s and 4 took 527s.
> - `npm run lint` and CI's Lint job run `shellcheck` in three batches (102s → 47s alone).
> - §3 applied to discovery: the walk's answer is also kept in a file under the run's state (or the
>   data root). It is used only while nothing under the plugins tree, the disabled list or the
>   validator code is newer than it, so an in-place edit re-walks. A shell that never warmed the
>   in-shell memo, such as a test sourcing the registry or a plugin process, used to re-validate every
>   manifest on every lookup: `stage-resolution-parity-test.sh` went from 11,391 programs to 1,515.
>
> The machine stays saturated either way, so the next rounds cut work: the `$( )` subshells that
> copy a whole engine shell, not only the programs `FORK_BUDGET` counts.

> **Amended 2026-10-24 (round 3): subshells are counted, and the hot ones are gone.** A `$( )`
> around an engine function copies the whole engine shell. `FORK_BUDGET` cannot see that copy,
> yet in the 60 slowest test files there were 410,581 processes against 292,889 programs.
> `fork_census_processes` counts every process bash ran in, and the budget test now also holds the
> mocked run to `PROCESS_BUDGET`, which ratchets down like `FORK_BUDGET`. The rule: a hot path reads
> into a variable, through a `_v` function that takes the variable's name, not through `$( )`.
> - `yaml_get_v <var> <file> <key>` gives what `var="$(yaml_get …)"` gives, value and rc. A miss
>   fills the cache in the calling shell, where a miss inside `$( )` filled nothing. The registry,
>   the resolver, lifecycle, persona and the cycle code read manifests with it. The cache's
>   contract is unchanged: an in-place manifest edit needs `yaml_cache_flush`.
> - The same goes for declared output paths (`_registry_resolve_output_path_v`), a status-comment
>   row's times, summary and inputs, discovery's tree check (one `find`, read by the shell) and the
>   `manifest_graph` memo's file name (no `cksum`).
> - One discovery memo serves a whole test run: `scripts/run-tests.sh` sets
>   `ZBUILD_DISCOVERY_MEMO_DIR`, so each file no longer pays its own first walk.
>
> The full local suite went from 493s to 401s. Ratcheted `FORK_BUDGET` 4,440 → 4,380 (4,312 measured)
> and set `PROCESS_BUDGET` 6,220 (6,139 measured; main before this round measured 8,331).

## Consequences

- A fork regression fails CI with its call site named, instead of surfacing months later as a
  slower daemon.
- Test authors get the harness for free: `bash scripts/lib/fork-census.sh <cmd...>` prints the
  count, the top call sites and the per-file totals of any command; `fork_census_traced` and
  `fork_census_count` are the same two functions the budget test uses.
- The number is platform-sensitive at the margin (`gtimeout` vs `timeout`, `stat` flavours);
  the budget carries a small headroom and CI's e2e job is Linux-only, so the ratchet is set from
  the Linux number.

## Implementation Notes (#2151, #2152)

- `scripts/lib/fork-census.sh` — `fork_census_traced` (the harness), `fork_census_count` (the
  classifier and tally), and a command-line census; `tests/e2e/fork-budget-test.sh` sources it and
  holds `FORK_BUDGET` with its ratchet history in the comment above it.
- `core/plugin-registry/manifest-index.sh` (#2152) — the first §4 application: one find + one awk
  fill `yaml_cache_prewarm` and `_inputs_scan_manifests`; `core/pipeline/runner.sh` fills the
  input-resolve maps at file scope right after sourcing `input-resolve.sh` (§3).
- Tests: `manifest-index-test.sh` (equivalence corpus, fork counts, the parent fill),
  `yaml-get-cache-test.sh` SPEC-9 (one awk per prewarm).

## Verification

`bash tests/e2e/fork-budget-test.sh` — SPEC-1 a canary script with one external exec counts
exactly 1 (the detector cannot go inert); SPEC-2 the mocked run still exits 0 under tracing;
SPEC-3 the trace names ≥ 20 source files and ≥ 1,000 execs (an fd-7-closed child traces to
stderr and must not pass as "under budget"); SPEC-4 total ≤ `FORK_BUDGET`. Red step: with the
counter stubbed, SPEC-1 fails `expected: 1, got: 0`.

## Enforced by

- §1 → `tests/e2e/fork-budget-test.sh` SPEC-1 (the canary counts one exec), SPEC-1b (a quoted value is not a command), SPEC-2, SPEC-3, SPEC-4 (the total is within `FORK_BUDGET`)
- §1 (amended #2236, exempt waits) → `tests/e2e/fork-budget-test.sh` (marked waits are listed apart and not counted)
- §2 → `tests/e2e/fork-budget-test.sh` SPEC-4 (`FORK_BUDGET` carries its ratchet history in the comment above it)
- §3, §4 → `tests/unit/manifest-index-test.sh` (fork counts, the parent fill); `tests/unit/yaml-get-cache-test.sh` SPEC-9 (one awk per prewarm)
- §5 (amended #1806, the event bus) → `tests/unit/event-bus-emit-cost-test.sh` E1 (one emit starts one `jq` and the lock, nothing per field), E2 (no `sed` for the mirror), E3 (UTC with real milliseconds whatever `ZBUILD_PLATFORM` says), E4 (the envelope is unchanged, and option-like values stay data)
- §1 (amended 2026-10-24, the census of any command) → `tests/unit/fork-census-test.sh` SPEC-1 (the census of a one-program script says 1 and names its line), SPEC-2 (the functions are callable after sourcing), SPEC-3 (the budget test uses this counter and keeps no copy)
- §4, §5 (amended 2026-10-24) → `tests/unit/manifest-graph-collect-memo-test.sh` SPEC-5 (a walk is one `awk`), SPEC-6 (a role lookup is one more `awk`, hit or miss); `tests/unit/manifest-validation-doc-fields-test.sh` SPEC-7 (the structural checks are one `awk`); `tests/unit/file-mode-kept-on-replace-test.sh` P6 (`atomic_write` starts no `dirname`, `tail` or `awk`); `tests/unit/run-status-render-time-test.sh` SPEC-6 (a row and the header are one `jq` each; a time starts no program)
- §3 (amended 2026-10-24, round 2: discovery across processes) → `tests/unit/discover-plugins-memo-test.sh` SPEC-4 (a cold lookup in a new subshell does not walk again), SPEC-5 (nor in a new process), SPEC-6 (an edited manifest re-walks and drops out), SPEC-7 (a changed plugin source re-walks), SPEC-8 (`discovery_cache_flush` and `ZBUILD_PLUGIN_DISCOVERY_CACHE=0` walk)
- §1 (amended 2026-10-24, round 2: the schedule) → `tests/unit/run-tests-schedule-test.sh` SPEC-1 (longest first, unrecorded first), SPEC-2/3 (pinned files in their own lane, one at a time), SPEC-4 (counts and FAIL lines in file order), SPEC-5 (file order without a durations file), SPEC-6 (the durations file is written from a timing log); `tests/unit/run-tests-tier-concurrency-test.sh` SPEC-4e (the default cap is 6); `tests/unit/ci-npm-script-parity-test.sh` SPEC-4 (shellcheck runs in parallel batches and a failing batch fails)
- §1, §2 (amended 2026-10-24, round 3: processes) → `tests/unit/fork-census-test.sh` SPEC-4 (subshells are counted as processes); `tests/e2e/fork-budget-test.sh` SPEC-7 (the mocked run's processes are within `PROCESS_BUDGET`)
- §3 (amended 2026-10-24, round 3) → `tests/unit/yaml-get-cache-test.sh` SPEC-12 (`yaml_get_v` matches `$(yaml_get)`), SPEC-13 (a miss fills the calling shell's cache); `tests/unit/output-paths-resolve-test.sh` SPEC-1/2; `tests/unit/run-status-render-time-test.sh` SPEC-6 (a row costs one process); `tests/unit/discover-plugins-memo-test.sh` SPEC-9 (a shared memo directory), SPEC-10 (a warm lookup costs one process); `tests/unit/manifest-graph-collect-memo-test.sh` SPEC-7 (no `cksum`, and a hit only under its own root); `tests/unit/run-tests-schedule-test.sh` SPEC-7 (one memo directory per run, removed after it)
- §5 (amended 2026-10-24, round 4: no SQLite mirror) → `tests/unit/event-bus-emit-cost-test.sh` E2 (an emit given a db path starts no `sqlite3`, takes one lock and writes no `events.db`); `tests/unit/core-event-bus-test.sh` (no `events.db` or its lock is written)
- §5 (amended 2026-10-25, round 5: per-stage chores read once) → `tests/unit/persist-secret-scan-cost-test.sh` C1 (a clean dir costs two greps), C2 (only a matching file is read on its own), C3 (the finding is unchanged); `tests/unit/attempt-archive-cost-test.sh` C1 (what one record starts), C2 (no `$( )` copies), C3 (changed/unchanged/new still right); `tests/unit/helpers-cost-test.sh` H1 (no repeat `mkdir`), H2 (`atomic_replace` starts `cp` and `mv` only), H3 (the copy keeps its mode); `tests/unit/event-bus-emit-cost-test.sh` E1 (no `jq` for a plain-ASCII emit), E6 (the line is byte for byte what `jq` writes); `tests/unit/router-manifest-budget-test.sh` SPEC-8b (one lookup, one `awk`); `tests/unit/requires-core-resolution-test.sh` SPEC-14 (one check strips and parses once)
- §3, §5 (amended 2026-10-25, round 6) → `tests/unit/manifest-index-test.sh` SPEC-5 (`a//b` and `a/b` are one key for the index, the input-resolve maps, `yaml_get`, `yaml_get_v` and a flush); `tests/unit/stage-dispatch-cost-test.sh` D1/D2 (what the write boundary starts), D3 (a non-writer's change is still refused), D4 (a repeat producer-index call starts nothing), D5 (a memo hit starts nothing), D6 (the id reader matches awk); `tests/unit/manifest-output-readers-test.sh` R1 (the outputs readers start nothing), R2 (they match the awk readers on every manifest and a corpus); `tests/unit/manifest-index-test.sh` SPEC-9 (a symlinked plugin dir is indexed); `tests/unit/run-constant-lookups-cost-test.sh` L1–L5 (the trunk, git dir and stage limit once per shell)
- §5 (amended 2026-10-24, round 4: only needed calls) → `tests/unit/atomic-write-cost-test.sh` W1 (replacing a file starts cat, one stat, chmod and mv), W2 (a `.bak` only with `--bak`), W3 (modes kept), W4 (a write that cannot start refuses and drains stdin); `tests/integration/state-collision-guard-test.sh` "cost" (one guarded update: no dirname or date, two jqs, and mktemp and cp only for the `.bak`)
