#!/usr/bin/env bash
# tests/lib/claim-gh-mock.sh — a stateful mock `gh` for the github-labels claim
# coordinator (ADR-005). The issue's labels, whether the repository defines the
# label, and the comments live in files under one folder, so a test sets up
# GitHub's state and reads back what the plugin did to it.
#
#   claim_gh_mock_install <state_dir>
#     <state_dir>/labels        the issue's labels, one a line
#     <state_dir>/repo-label    present when the repository defines zbuild:claimed
#     <state_dir>/log           every call's arguments, one call a line
#     <state_dir>/page-<n>.json the comment pages `api --paginate` prints, in order
#                               (`api` without --paginate prints page-1.json only)
#     <state_dir>/fail-remove   present: `issue edit --remove-label` fails
#     <state_dir>/hang          present: every call blocks until <state_dir>/go
#                               appears (bounded, so no mock outlives a test)
#     <state_dir>/add-then-fail present: `issue edit --add-label` applies the label,
#                               then fails (a reply lost after GitHub acted)

claim_gh_mock_install() {
    local s="$1"
    mkdir -p "$s" "$TEST_TEMP_DIR/bin"
    : > "$s/labels"; : > "$s/log"
    cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
s="$s"
printf '%s\n' "\$*" >> "\$s/log"
if [[ -e "\$s/hang" ]]; then
    for _ in \$(seq 1 300); do [[ -e "\$s/go" ]] && break; sleep 0.05; done
fi
case "\$1:\$2" in
    issue:view) cat "\$s/labels"; exit 0 ;;
    issue:edit)
        label="\${5:-}"
        if [[ "\$4" == "--add-label" ]]; then
            if [[ ! -e "\$s/repo-label" ]]; then
                printf "could not add label: '%s' not found\n" "\$label" >&2; exit 1
            fi
            /usr/bin/grep -Fxq "\$label" "\$s/labels" || printf '%s\n' "\$label" >> "\$s/labels"
            [[ -e "\$s/add-then-fail" ]] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
            exit 0
        fi
        if [[ "\$4" == "--remove-label" ]]; then
            [[ -e "\$s/fail-remove" ]] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
            /usr/bin/grep -Fxv "\$label" "\$s/labels" > "\$s/labels.new" || true
            mv "\$s/labels.new" "\$s/labels"; exit 0
        fi
        exit 1 ;;
    label:create) : > "\$s/repo-label"; exit 0 ;;
    api:--paginate)
        for f in "\$s"/page-*.json; do [[ -e "\$f" ]] && cat "\$f"; done; exit 0 ;;
    api:*)
        [[ -e "\$s/page-1.json" ]] && cat "\$s/page-1.json"; exit 0 ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
}
