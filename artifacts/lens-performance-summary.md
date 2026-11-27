## review-lens-performance — fail

- found: medium: All comment pages for the issue are fetched without a server-side time filter; for issues with long comment histories the number of API round-trips and the volume of data written to disk grow linearly with the total comment count. (plugins/claim-coordinator/github-labels/plugin.sh)

- score: 8
