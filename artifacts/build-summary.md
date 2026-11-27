## build — pass

- changed core/claim/claim.sh, docs/adr/ADR-005-claim-coordinator.md, plugins/claim-coordinator/github-labels/plugin.sh (+180 / -12)

- over 2 pass(es), 2 iteration(s)
- no finding was open for it
- step 1: done — plugins/claim-coordinator/github-labels/plugin.sh | if ! rsc_gh "$sd" "$out" api --repo "$slug" "repos/${slug}/issues/${issue}/comments" \
- step 2: done — core/claim/claim.sh | if [[ "$reply" =~ \"race_lost\"[[:space:]]*:[[:space:]]*true ]]; then
- step 3: done — docs/adr/ADR-005-claim-coordinator.md | ### §5 — Concurrent claim detection (amended 2026-11-27, #2534)
