## spec-correspondence — partial

- judged 21 SPEC(s): 20 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-11 partial: The grep checks only two specific patterns (`lens-` prefixed paths and `scope-manifest.md`) but the requirement is a universal negative over all hardcoded artifact path literals; other artifact paths hardcoded in the body would pass the assertion without satisfying the requirement.

