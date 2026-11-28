#!/usr/bin/env bash
# tests/lib/claim-gh-mock.sh — a stand-in `gh` for the github-labels claim
# coordinator (ADR-005). It is a fake for what our code writes: the issue's
# labels and the comments our code posts are kept, and read back as GitHub
# would give them (ADR-012). Comments a test writes by hand (page-<n>.json) are
# someone else's, already on the issue. All of it lives in files under one
# folder, so a test sets up GitHub's state and reads back what the plugin did.
#
#   claim_gh_mock_install <state_dir>
#     <state_dir>/labels        the issue's labels, one a line
#     <state_dir>/repo-label    present when the repository defines zbuild:claimed
#     <state_dir>/log           every call's arguments, one call a line
#     <state_dir>/page-<n>.json comments already on the issue, one page a file, in
#                               order, listed before the comments our code posted
#     <state_dir>/comments.json the comments our code posted, as GitHub keeps them
#     <state_dir>/now           GitHub's clock: the time a posted or edited comment
#                               gets (default 2026-01-01T00:00:00Z)
#     <state_dir>/per-page      GitHub's page size for our comments (default: the
#                               call's per_page, else 30)
#     <state_dir>/labels-unseen present: `issue view` answers with no labels, as a
#                               read made before another run's add is visible
#     <state_dir>/login, association  who our posts are by (default
#                               github-actions[bot], NONE); a local run posts as a person
#     <state_dir>/newest-first  present: our comments are listed newest first (an
#                               order the code must not rely on)
#     <state_dir>/list-waits-for <n>: a list of the comments waits (bounded) until
#                               <n> of ours are kept — two runs that both read after
#                               both posted
#     <state_dir>/no-created-at present: a posted comment's reply has no created_at
#     <state_dir>/no-id         present: a posted comment's reply has no id
#     <state_dir>/fail-<m>      present: a comment call of method <m> (post, patch,
#                               delete, get) fails
#     <state_dir>/fail-remove   present: `issue edit --remove-label` fails
#     <state_dir>/hang          present: every call blocks until <state_dir>/go
#                               appears (bounded, so no stand-in outlives a test)
#     <state_dir>/add-then-fail present: `issue edit --add-label` applies the label,
#                               then fails (a reply lost after GitHub acted)

claim_gh_mock_install() {
    local s="$1"
    mkdir -p "$s" "$TEST_TEMP_DIR/bin"
    : > "$s/labels"; : > "$s/log"
    printf '#!/usr/bin/env bash\ns=%q\n' "$s" > "$TEST_TEMP_DIR/bin/gh"
    cat >> "$TEST_TEMP_DIR/bin/gh" <<'FAKE'
printf '%s\n' "$*" >> "$s/log"
if [[ -e "$s/hang" ]]; then
    for _ in $(seq 1 300); do [[ -e "$s/go" ]] && break; sleep 0.05; done
fi
_now() { local t="2026-01-01T00:00:00Z"; [[ -s "$s/now" ]] && t="$(cat "$s/now")"; printf '%s' "$t"; }
_fail() { [[ -e "$s/fail-$1" ]] && { echo "HTTP 502: bad gateway" >&2; exit 1; }; return 0; }
# The pages a list call prints: the hand-written ones, then our comments since
# <since>, <per> to a page. <all> 0 prints the first page only.
_list() {
    local since="$1" per="$2" all="$3" f printed=0
    for f in "$s"/page-*.json; do
        [[ -e "$f" ]] || continue
        cat "$f"; printed=1
        [[ "$all" == 1 ]] || return 0
    done
    [[ -s "$s/comments.json" ]] || { [[ "$printed" == 1 ]] || echo '[]'; return 0; }
    jq -c --arg since "$since" --argjson per "$per" --argjson all "$all" \
        --argjson desc "$([[ -e "$s/newest-first" ]] && echo true || echo false)" '
        [.[] | select($since == "" or ((.updated_at // .created_at) >= $since))]
        | if $desc then reverse else . end
        | if length == 0 then [[]] else [range(0; length; $per) as $i | .[$i:$i + $per]] end
        | if $all == 1 then .[] else .[0] end' "$s/comments.json"
}
if [[ "$1" == api ]]; then
    method="" paginate=0 input="" body="" path="" i=0
    args=("$@")
    for (( i = 1; i < ${#args[@]}; i++ )); do
        case "${args[i]}" in
            -X|--method) method="${args[i+1]}"; i=$(( i + 1 )) ;;
            --paginate) paginate=1 ;;
            --input) input="${args[i+1]}"; i=$(( i + 1 )) ;;
            -f|-F|--field|--raw-field)
                [[ "${args[i+1]}" == body=* ]] && body="${args[i+1]#body=}"
                [[ -n "$method" ]] || method=POST; i=$(( i + 1 )) ;;
            -H|--header|--jq|-q|--hostname|-t|--template|-p|--preview|--cache) i=$(( i + 1 )) ;;
            --slurp|--silent|-i|--include|--verbose) ;;
            # `gh api` has no --repo: the path names the repository.
            -*) echo "unknown flag: ${args[i]}" >&2; exit 1 ;;
            *) [[ -n "$path" ]] || path="${args[i]#/}" ;;
        esac
    done
    method="${method:-GET}" query=""
    [[ "$path" == *\?* ]] && { query="${path#*\?}"; path="${path%%\?*}"; }
    if [[ "$path" =~ ^repos/[^/]+/[^/]+/issues/[0-9]+/comments$ ]]; then
        [[ -s "$s/comments.json" ]] || echo '[]' > "$s/comments.json"
        if [[ "$method" == POST ]]; then
            _fail post
            id=1000; [[ -s "$s/next-id" ]] && id="$(cat "$s/next-id")"
            echo "$(( id + 1 ))" > "$s/next-id"
            login="github-actions[bot]"; [[ -s "$s/login" ]] && login="$(cat "$s/login")"
            assoc="NONE"; [[ -s "$s/association" ]] && assoc="$(cat "$s/association")"
            jq -c --argjson id "$id" --arg b "$body" --arg t "$(_now)" --arg l "$login" --arg a "$assoc" \
                '. + [{id: $id, body: $b, created_at: $t, updated_at: $t,
                       user: {login: $l}, author_association: $a}]' \
                "$s/comments.json" > "$s/comments.new" && mv "$s/comments.new" "$s/comments.json"
            jq -c --argjson id "$id" --argjson nc "$([[ -e "$s/no-created-at" ]] && echo true || echo false)" \
                --argjson ni "$([[ -e "$s/no-id" ]] && echo true || echo false)" \
                '.[] | select(.id == $id) | if $nc then del(.created_at) else . end
                 | if $ni then del(.id) else . end' "$s/comments.json"
            exit 0
        fi
        _fail get
        since="" per=30 kv=""
        for kv in ${query//&/ }; do
            case "$kv" in since=*) since="${kv#since=}" ;; per_page=*) per="${kv#per_page=}" ;; esac
        done
        if [[ -n "$since" && ! "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
            echo "HTTP 422: Validation Failed (since is not an ISO 8601 time)" >&2; exit 1
        fi
        [[ -s "$s/per-page" ]] && per="$(cat "$s/per-page")"
        if [[ -s "$s/list-waits-for" ]]; then
            want="$(cat "$s/list-waits-for")"
            for _ in $(seq 1 200); do
                (( $(jq 'length' "$s/comments.json") >= want )) && break; sleep 0.05
            done
        fi
        _list "$since" "$per" "$paginate"; exit 0
    fi
    if [[ "$path" =~ ^repos/[^/]+/[^/]+/issues/comments/([0-9]+)$ ]]; then
        cid="${BASH_REMATCH[1]}"
        [[ -s "$s/comments.json" ]] || echo '[]' > "$s/comments.json"
        jq -e --argjson id "$cid" 'any(.[]; .id == $id)' "$s/comments.json" >/dev/null \
            || { echo "HTTP 404: Not Found" >&2; exit 1; }
        case "$method" in
            PATCH)
                _fail patch
                [[ -n "$input" ]] && body="$(jq -r '.body' "$input")"
                jq -c --argjson id "$cid" --arg b "$body" --arg t "$(_now)" \
                    'map(if .id == $id then .body = $b | .updated_at = $t else . end)' \
                    "$s/comments.json" > "$s/comments.new" && mv "$s/comments.new" "$s/comments.json"
                jq -c --argjson id "$cid" '.[] | select(.id == $id)' "$s/comments.json"; exit 0 ;;
            DELETE)
                _fail delete
                jq -c --argjson id "$cid" 'map(select(.id != $id))' \
                    "$s/comments.json" > "$s/comments.new" && mv "$s/comments.new" "$s/comments.json"
                exit 0 ;;
            *) jq -c --argjson id "$cid" '.[] | select(.id == $id)' "$s/comments.json"; exit 0 ;;
        esac
    fi
    # Any other endpoint: the hand-written pages.
    if [[ "$paginate" == 1 ]]; then
        for f in "$s"/page-*.json; do [[ -e "$f" ]] && cat "$f"; done
    else
        [[ -e "$s/page-1.json" ]] && cat "$s/page-1.json"
    fi
    exit 0
fi
case "$1:$2" in
    issue:view) [[ -e "$s/labels-unseen" ]] || cat "$s/labels"; exit 0 ;;
    issue:edit)
        label="${5:-}"
        if [[ "$4" == "--add-label" ]]; then
            if [[ ! -e "$s/repo-label" ]]; then
                printf "could not add label: '%s' not found\n" "$label" >&2; exit 1
            fi
            /usr/bin/grep -Fxq "$label" "$s/labels" || printf '%s\n' "$label" >> "$s/labels"
            [[ -e "$s/add-then-fail" ]] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
            exit 0
        fi
        if [[ "$4" == "--remove-label" ]]; then
            [[ -e "$s/fail-remove" ]] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
            /usr/bin/grep -Fxv "$label" "$s/labels" > "$s/labels.new" || true
            mv "$s/labels.new" "$s/labels"; exit 0
        fi
        exit 1 ;;
    label:create) : > "$s/repo-label"; exit 0 ;;
esac
exit 0
FAKE
    chmod +x "$TEST_TEMP_DIR/bin/gh"
}
