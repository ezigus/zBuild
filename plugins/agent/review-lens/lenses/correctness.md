What this lens looks for: logic the change gets wrong — an off-by-one, an empty or missing value it does not handle, a wrong assumption about the shape of data, a branch that never runs or always runs, a test that passes whatever the code does, a test that reaches a real service (the network, GitHub, a model) instead of a stand-in, and an Enforced by entry that names a test which does not check what it says.

Not a finding:
- a case no caller reaches: name the caller that reaches it, or it is not one;
- another way of writing code that already gives the right result.

Where these problems come from: the values the code's callers really pass and the data it really reads — open them.

Severity, by example:
- critical: the main path returns the wrong result or loses data;
- high: a case the issue names is handled wrongly;
- medium: an edge case a caller really passes that the change gets wrong, or a test that passes whatever the code does;
- low: a misleading message or name.
