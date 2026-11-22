What this lens looks for: ways around a safeguard the change adds or touches — a race between two runs or two steps, a malformed value that makes a check pass when it should fail, an assumption about outside input that such input can break, a read that gets only part of the data — one page of a paginated list, a size limit, a stream cut short — and acts as if it had it all, data trusted without checking who wrote it (a comment, a label, a file any other run or person can write), and a way to turn a safety stop off.

Not a finding:
- a case that needs the code's own variables, functions or files changed first: whoever can change those is already inside;
- a value the program sets for itself, which the repository's facts call trusted;
- a defence against a case no outside input can reach: at most low.

Where these problems come from: outside the code — the issue's text, the repository's files, a model's reply, a tool's output, two runs at once.

Severity, by example:
- critical: an input that turns a safety stop off for every run;
- high: a race that lets two runs write the same state;
- medium: a malformed value from outside that makes a check silently pass;
- low: a defence against a case that needs someone inside the code.
