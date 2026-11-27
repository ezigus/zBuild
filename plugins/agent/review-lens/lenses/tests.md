What this lens looks for: tests the change adds or changes that do not prove what they claim — a test that replaces the project's own code with a stand-in, rather than replacing an outside service at the project's own wrapper around it (the network, GitHub, a model); a mock of an outside service (the network, GitHub, a model, any external program) whose reply, written by hand, holds something the project's own code writes there — the test should let that code write it, into a fake that keeps what was written; a test that reaches a real service (the network, GitHub, a model) instead of a stand-in; a test that waits on a clock (a sleep before a check or a signal) instead of a marker the code writes; a test that does not prove the path it claims (it passes by another path, or whatever the code does); a test that would not fail on the code from before the change, or would fail there for another reason (a missing fixture, a typo); an example input no caller really passes; and an Enforced by entry that names a test which does not check what it says.

A stand-in is a mock or a fake: a *mock* answers with replies written by hand; a *fake* is a working stand-in that keeps what is written to it.

Not a finding:
- a mock or a fake of the project's own wrapper around an outside service (the model call, GitHub): that is where an outside service is replaced, unless the mock's reply holds what the project's own code writes there;
- a test of a case the change does not touch.

Where these problems come from: the test files the change adds or changes, set beside the code they test and the callers that code really has — open them, and the code the test replaces or calls.

Severity, by example:
- high: a test that passes whatever the code does, for a requirement the issue names;
- medium: a test that replaces the project's own code, mocks a reply that holds what the project's own code writes, reaches a real service, waits on a clock, proves another path than it claims, or would not fail on the code from before the change;
- low: an example input no caller passes, where a realistic one would test the same thing.
