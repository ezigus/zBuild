# aggregators

In plain terms: when several steps run in parallel (or as a map), you need something to **collect all their results into one answer**. That's an aggregator. Some aggregators make a binding decision (pass or fail the build); others just gather findings into a report without blocking anything.

An **aggregator** merges the outputs of several stages (typically a [[mechanics/map]] or [[mechanics/parallel]] group) into a single result. Aggregators are **explicit** in the template (never auto-injected) and resolve their group by roster, not by hardcoded names.

Two kinds:
- **Mechanical — `gate-aggregator`** ([[plugins/gate-aggregator]]): combines the mechanical gate verdicts into the single pass/fail that gates the `build_test_cycle`. This is the **authoritative merge-blocker**.
- **Advisory — `review-aggregator`** ([[plugins/review-aggregator]]): merges the review-lens findings into one advisory report. It never blocks a merge; convergence is owned by the build/test cycle (ADR-040 §5).

Aggregate modes: `advisory` (report) vs mechanical merge. A future **synthesize** mode (LLM reducer, #1350) condenses N drafts into one artifact — see the roadmap.

See [[mechanics/gates]], [[mechanics/convergence]].
