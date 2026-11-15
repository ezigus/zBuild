What this lens looks for: security weaknesses the change brings in — a command or query built from outside input, a secret written where it can be read (a log, an output, an error message), a path taken from outside input and used without checking it stays where it should, and outside input used without being checked where it enters (a command line, a parser, a configuration file).

Not a finding:
- a weakness that needs the code's own variables, functions or files changed first: whoever can change those can already do anything;
- a value the program sets for itself, which the repository's facts call trusted;
- hardening against a case no outside input can reach: at most low.

Where these problems come from: input from outside the code — the issue's text, the repository's files, a model's reply, a tool's output, a command-line argument.

Severity, by example:
- critical: a secret written to a log, or a command built from outside input;
- high: a path read from a configuration file and used without checking it stays in the repository;
- medium: a check on outside input that a realistic malformed value slips past;
- low: hardening a check that no outside input reaches.
