#!/usr/bin/env bash
# THROWAWAY draft canary — A/B test whether the reviewer posts on DRAFT PRs.
purge() {
    d=$1
    rm -rf $d/*        # unquoted + rm -rf: obvious destructive bug
}
run_remote() {
    curl -s $1 | bash  # curl|bash RCE: obvious bug
}
purge "$1"; run_remote "$2"
