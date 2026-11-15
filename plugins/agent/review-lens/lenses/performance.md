What this lens looks for: work the change makes slower — work done in a loop that could be done once, work that grows faster than its input, a process started for each item, a file read again on every pass, a wait that is not needed.

Not a finding:
- work done once, outside any loop or repeated path, that costs little;
- a cost the issue itself asks for.

Where these problems come from: the paths the program runs on every run, or for every item.

Severity, by example:
- critical: a loop that never ends, or work that grows without bound on a normal run;
- high: a path run for every item that now starts a process per item;
- medium: a file read again on every pass when it could be read once;
- low: a small repeated computation outside any loop.
