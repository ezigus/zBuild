# SRE lens checkpoint

## Files read
- diff.patch: two insertions to route.sh + golden update + new test file
- core/router/route.sh (lines 880-940, 1270-1340, 1500-1560, 1600-1750, 1800-1830, 1917-1960, 2050-2115, 2228-2245, 2300-2355)

## Conclusions reached

1. Missing soft-failure guard on emitter calls — MEDIUM, INTRODUCED
   - Lines 1830, 2350: _route_emit_model_route and _route_emit_outcome called without 2>/dev/null || true
   - Every other eb_emit_event call in the loop body (lines 1827, 1919, 2044, 2092, 2102, 2129, 2146, 2231, 2236, 2314) has 2>/dev/null || true
   - Under set -euo pipefail, an eb_emit_event failure in these helpers aborts the iteration/loop
   - The model.outcome case (line 2350) is higher risk: LLM call succeeded, cost recorded, but loop aborts before result is processed

2. Orphaned model.route on failed iterations — LOW, INTRODUCED  
   - model.route is emitted pre-call (line 1830); failed iterations produce it without model.outcome
   - Mirrors sync path behavior (line 203 also pre-call, line 244 success-only)
   - Monitoring expecting paired events will see orphans on failed build/design iterations

3. timeout_s reports base not escalated timeout — LOW, INTRODUCED
   - $secs is base; intra-iteration retries escalate _iter_local_secs (line 2107) 
   - But model.route and model.outcome both report $secs, not _iter_local_secs
   - Consistent with sync path; minor inaccuracy

## Status: COMPLETE

