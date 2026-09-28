## spec-coverage — uncovered

- The acceptance checkbox "Router budgets resolve from the manifest, and the template override still wins where one is set" requires proving override precedence, but SPEC-7 only asserts the manifest's config.router values match deployed.yaml's override — with identical values on both layers, no SPEC exercises a case where template and manifest diverge to prove the template wins.

- NOT COVERED: template override still wins over manifest-declared router budgets when the two differ
