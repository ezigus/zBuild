## intake — pass

- 7 requirement(s): RQTIE-1, RQREB-1, RQTIE-2, RQCMT-1, RQLBL-1, RQADR-1, RQTIE-3

- RQTIE-1: When two runs claim an issue at the same moment, exactly one proceeds
- RQREB-1: After adding the label, a run re-reads the issue
- RQTIE-2: If another run claimed it too, the run that claimed first wins
- RQCMT-1: The later run marks its progress comment as not started
- RQLBL-1: The later run exits without removing the label
- RQADR-1: Amend ADR-005: the first claim wins a tie, and how "first" is decided
- RQTIE-3: Either the claim writes its holder record itself, synchronously, before it re-reads, or the tie-break uses something that exists at claim time (for example when the label was added).
