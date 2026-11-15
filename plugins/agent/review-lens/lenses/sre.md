What this lens looks for: production risk the change brings — a failure that spreads further than it should, an error swallowed so a failed step reads as a pass, a failure that leaves no message, event or log saying why, and a risky step with no way back.

Not a finding:
- a choice the program makes the same way on every run, such as which form of a tool the host has: that is not a failure, and needs no log;
- a step that already fails loudly, with a message saying why;
- a log line for something that cannot fail.

Where these problems come from: a step failing on a normal run — a tool missing or failing, a file not there, a network call that fails, a run interrupted.

Severity, by example:
- critical: a failure that stops every run with no message;
- high: an error swallowed so a failed step reads as a pass;
- medium: a failure with no event or log saying why;
- low: a log line that could be clearer.
