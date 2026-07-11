# leaf

The simplest operator: **run one plugin as one stage.** Most stages in a template are leaves (`intake`, `plan`, `pr`, …).

- **Shape:** a single stage entry that resolves to a plugin by role-then-id (ADR-042/047).
- **Input/output:** the plugin reads its declared inputs from prior stages and writes its declared artifact(s); see the plugin's page under [[Plugins]] for its exact contract.
- **Verdict:** a leaf may carry a gate (see [[mechanics/gates]]) whose verdict determines pass/fail.

Composed by [[mechanics/sequence]], [[mechanics/parallel]], [[mechanics/cycle]], and [[mechanics/map]]. See [[Pipeline-and-Stages]].
