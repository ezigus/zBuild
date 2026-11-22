What this lens looks for: production risk the change brings — a failure that spreads further than it should, an error swallowed so a failed step reads as a pass, a failure that leaves no event or status line saying why, a call to something outside the program with no timeout, anything taken — a claim, a lock, a label, a file — that a crash or an interrupt leaves behind, and a risky step with no way back.

Fails loudly means an event or a status line, not only a message on stderr. A deliberate fail-open must be visible the same way: an event or a status line says it happened.

Not a finding:
- a choice the program makes the same way on every run, such as which form of a tool the host has: that is not a failure, and needs no log;
- a step that already fails loudly — an event or a status line saying why;
- a log line for something that cannot fail.

Where these problems come from: a step failing on a normal run — a tool missing or failing, a file not there, a network call that fails, a run interrupted.

Severity, by example:
- critical: a failure that stops every run with no message;
- high: an error swallowed so a failed step reads as a pass;
- medium: a failure with no event or log saying why;
- low: a log line that could be clearer.
