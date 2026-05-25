## File
`core/state/resume.sh`

## Mutation
Flip the 24-hour boundary check for resume recommendation. Change the condition that determines whether a pipeline is "recently interrupted" (e.g., change `86400` seconds to `0`, or invert the comparison operator) so that stale pipelines are recommended for resume and fresh ones are not.

## Expected failing test
`tests/integration/resume-state-machine-test.sh` — the state-transition test asserts that an interrupted pipeline is resumable; with this mutation the resume recommendation logic would fire at the wrong time.

## Result
The mutation is caught: the test fails because the resume recommendation fires for a completed (non-interrupted) pipeline or does not fire for a genuinely interrupted one.
