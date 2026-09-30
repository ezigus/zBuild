## spec-coverage — uncovered

- The issue's explicit acceptance checkbox — "The manifest declares a `primary: true` output" — has no corresponding SPEC; SPEC-1, SPEC-2, and SPEC-3 all edit the manifest but none guard that the existing `primary: true` declaration at manifest.yaml:92 is preserved after those edits.

- NOT COVERED: manifest declares a `primary: true` output after migration — explicit checkbox, issue notes it is "already met" but no SPEC verifies the declaration survives the manifest changes introduced by SPEC-1/2/3
