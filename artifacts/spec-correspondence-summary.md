## spec-correspondence — mismatch

- judged 21 SPEC(s): 19 correspond, 1 partial, 1 mismatch, 0 uncheckable, 0 unjudged

- SPEC-11 partial: The grep pattern covers only two specific artifact path forms (lens- prefix and scope-manifest.md); the requirement is a universal negative over all hardcoded artifact path literals, so other hardcoded paths in the body would go undetected.
- SPEC-21 MISMATCH: The acceptance-gate's NEGCTL check found this assertion passes at baseline before the feature is present, meaning it can pass when the requirement is not satisfied and therefore does not establish it.

