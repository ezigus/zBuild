## spec-correspondence — partial

- judged 8 SPEC(s): 6 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-7 partial: The assertion only catches `exhausted` when it is immediately preceded by `disposition:` (the regex `disposition:.*exhausted`), so a prescriptive use such as "emits `exhausted` as its disposition" or an inline prose form not preceded by that keyword would pass undetected.
- SPEC-8 partial: The assertion checks for the absence of the old phrase and the presence of at least one `_*_budget_guidance` pattern anywhere in the document, but does not verify the pattern appears in §1 specifically or that more than one per-stage helper is named, leaving "each stage has its own" unestablished.

