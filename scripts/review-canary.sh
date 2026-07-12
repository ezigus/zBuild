#!/usr/bin/env bash
# THROWAWAY canary — verifies the Claude PR reviewer posts inline comments.
# This branch/PR is never merged; it is closed after the review runs.
# It intentionally contains obvious, flaggable issues.

delete_old_logs() {
    dir=$1
    # BUG: unquoted $dir → word-splitting; rm -rf with no validation → if $dir is
    # empty this becomes `rm -rf /*.log` and can delete across the filesystem.
    rm -rf $dir/*.log
}

fetch_url() {
    url=$1
    # BUG: piping curl straight into bash executes arbitrary remote code.
    curl -s $url | bash
}

delete_old_logs "$1"
fetch_url "$2"
