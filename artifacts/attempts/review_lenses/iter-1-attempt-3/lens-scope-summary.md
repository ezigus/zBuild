## review-lens-scope — fail

- found: medium: The DSRACE-1 and DSRACE-7 test sections pipe into `/usr/bin/head -1` under `set -euo pipefail`, violating the explicit rule "never pipe into a bare head, in any .sh file, test files included"; the SIGPIPE guard does not catch it because it excludes `-test.sh` files from the `| head` scan and its regex matches `head` as a bare word, not `/usr/bin/head`. (plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh)

- score: 8
