# convergence

How a [[mechanics/cycle]] decides to stop. Every cycle is **bounded** and converges on an explicit condition.

- **`exit_when`** — the condition(s) that end the cycle, evaluated after each iteration. Conditions reference a member's verdict (e.g. `gate-aggregator.verdict == pass`).
- **all / any** — multiple conditions can be combined; the cycle exits when **all** (or **any**) hold.
- **max iterations** — a hard upper bound so a cycle can never loop forever.
- **`on_max`** — what happens when the bound is hit without converging: `continue` (fall through to the next stage — ADR-019) or fail. `simple.yaml` uses `on_max: continue` so an unconverged cycle still proceeds.
- **plateau / stall detection** — the engine emits `cycle.plateau` / `cycle.stalled` events when iterations stop making progress.

See [[mechanics/cycle]], [[mechanics/gates]], [[mechanics/route_back]].
