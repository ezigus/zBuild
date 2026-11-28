What this lens looks for: logic the change gets wrong — an off-by-one, an empty or missing value it does not handle, a wrong assumption about the shape of data, and a branch that never runs or always runs. What the change's tests prove is the tests lens's, not this one's.

Not a finding:
- a case no caller reaches: name the caller that reaches it, or it is not one;
- another way of writing code that already gives the right result.

Where these problems come from: the values the code's callers really pass and the data it really reads — open them.

Severity, by example:
- critical: the main path returns the wrong result or loses data;
- high: a case the issue names is handled wrongly;
- medium: an edge case a caller really passes that the change gets wrong;
- low: a misleading message or name.
