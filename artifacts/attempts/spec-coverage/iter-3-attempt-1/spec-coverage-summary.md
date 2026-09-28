## spec-coverage — uncovered

- The issue's first acceptance checkbox explicitly requires the result file on "interruption" as a distinct exit path; SPEC-2 covers "every terminal exit path (both success and all failure modes)" which categorises exits as two buckets, leaving signal/SIGTERM interruption — named separately by the checkbox — with no SPEC that demands it.

- NOT COVERED: result file written on process interruption (signal/SIGTERM path)
- NOT COVERED: issue checkbox #1 lists "success, failure, and interruption" as three distinct cases and no SPEC addresses the interruption/signal-trap path
