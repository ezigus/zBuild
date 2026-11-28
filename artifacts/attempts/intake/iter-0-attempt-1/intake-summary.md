## intake — pass

- 7 requirement(s): RQLOCK-1, RQLOCK-2, RQLOCK-3, RQADR-1, RQADR-2, RQLOCK-4, RQLOCK-5; 1 limit(s): LMSCOP-1

- RQLOCK-1: Two concurrent `_release_prepend_changelog` calls for the same version in one checkout produce exactly one section.
- RQLOCK-2: Two concurrent `_release_prepend_changelog` calls for different versions in one checkout produce both sections, in order.
- RQLOCK-3: A lock timeout in `_release_prepend_changelog` fails the release: it exits non-zero, prints a message naming the lock, and leaves the CHANGELOG unchanged.
- RQADR-1: The ADR-041 amendment records that the release CHANGELOG writer fails closed on a lock timeout, as an exception to ADR-041's "fail soft" rule.
- RQADR-2: The ADR-041 amendment names its enforcing tests inline.
- LMSCOP-1: Do not change the `--ship` preflight, the branch and tag collision handling, or the `concurrency:` group on `release.yml`. (limit)
- RQLOCK-4: A CHANGELOG write that cannot get its lock fails the release (fail closed): non-zero exit, and a message naming the lock.
- RQLOCK-5: **Code:** `scripts/release.sh` (`_release_prepend_changelog`, using `zbuild_has_flock` from `scripts/lib/compat.sh`).
