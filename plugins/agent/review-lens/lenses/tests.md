What this lens looks for: tests the change adds or changes that do not prove what they claim — a test that replaces the project's own code with a fake, rather than faking an outside service at the project's own wrapper around it (the network, GitHub, a model); a test that reaches a real service (the network, GitHub, a model) instead of a stand-in; a test that waits on a clock (a sleep before a check or a signal) instead of a marker the code writes; a test that does not prove the path it claims (it passes by another path, or whatever the code does); a test that would not fail on the code from before the change, or would fail there for another reason (a missing fixture, a typo); an example input no caller really passes; and an Enforced by entry that names a test which does not check what it says.

Not a finding:
- a fake of the project's own wrapper around an outside service (the model call, GitHub): that is where an outside service is faked;
- a test of a case the change does not touch.

Where these problems come from: the test files the change adds or changes, set beside the code they test and the callers that code really has — open them, and the code the test fakes or calls.

Severity, by example:
- high: a test that passes whatever the code does, for a requirement the issue names;
- medium: a test that fakes the project's own code, reaches a real service, waits on a clock, proves another path than it claims, or would not fail on the code from before the change;
- low: an example input no caller passes, where a realistic one would test the same thing.
