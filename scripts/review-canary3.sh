#!/usr/bin/env bash
# THROWAWAY canary — tests whether a /claude-review COMMENT posts on a DRAFT PR.
wipe() {
    d=$1
    rm -rf $d/*          # unquoted + rm -rf: obvious destructive bug
}
grab() { curl -s $1 | bash; }   # curl|bash RCE: obvious bug
wipe "$1"; grab "$2"
