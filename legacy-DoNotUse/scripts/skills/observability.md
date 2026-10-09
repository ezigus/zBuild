## Observability: Watch the Deploy Like a Hawk

Post-deploy monitoring catches what tests miss. Real traffic reveals real problems.

### What to Monitor (by Priority)

**P0 — Immediate (first 5 minutes):**
- Error rate: any increase over baseline?
- Health check: still returning 200?
- Latency: p50/p95/p99 within normal range?
- Memory/CPU: any sudden spikes?

**P1 — Short-term (5-30 minutes):**
- Business metrics: are users completing key flows?
- Queue depths: are background jobs processing normally?
- Connection pools: any exhaustion or leak patterns?
- Disk usage: any unexpected growth?

**P2 — Medium-term (1-24 hours):**
- Memory trends: gradual leak over time?
- Error rate trends: slowly increasing?
- User-reported issues: any new support tickets?
- Performance degradation under sustained load?

### Anomaly Detection Patterns
- **Spike detection**: >2x baseline error rate in any 1-minute window
- **Trend detection**: steadily increasing error rate over 5-minute window
- **Absence detection**: expected periodic events stop occurring
- **Latency shift**: p95 latency increases >50% from baseline

### Log Analysis
- Search for new ERROR/FATAL/PANIC entries not present before deploy
- Check for stack traces — they indicate unhandled exceptions
- Look for retry storms — repeated failed attempts at the same operation
- Monitor for resource exhaustion messages (OOM, connection refused, disk full)

### Auto-Rollback Triggers
Automatically rollback if ANY of these occur:
- Health check fails 3 consecutive times
- Error rate exceeds threshold for 2+ minutes
- Critical service dependency becomes unreachable
- Memory usage exceeds 90% of limit

### Monitoring by Issue Type

**Frontend changes:**
- JavaScript error rates in browser (if client-side monitoring exists)
- Asset load failures (404s on new bundles)
- Core Web Vitals regression (LCP, FID, CLS)

**API changes:**
- Response status code distribution (2xx vs 4xx vs 5xx)
- Request throughput — drops indicate client-side breakage
- Authentication failures — spikes indicate auth regression

**Database changes:**
- Query latency per endpoint
- Connection pool utilization
- Slow query log entries
- Replication lag (if applicable)

### Incident Escalation
If monitoring detects issues:
1. Execute rollback (if auto-rollback enabled)
2. Create incident issue with monitoring data
3. Attach relevant logs and metrics
4. Tag the original issue with `incident` label
5. Do NOT silence alerts — let them fire

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Monitoring Checklist**: P0/P1/P2 metrics to watch (error rate, latency, memory, health checks) with specific thresholds
2. **Anomaly Detection Triggers**: Explicit conditions that trigger alerts (spike detection >2x, trend detection over 5min, absence detection, latency shift >50%)
3. **Log Analysis**: Search strategy for new ERROR/FATAL entries, stack traces, retry storms, resource exhaustion patterns
4. **Auto-Rollback Decision Criteria**: Conditions that trigger automatic rollback (health check failures, error rate threshold, critical dependency unreachable, memory exhaustion)

If any section is not applicable, explicitly state why it's skipped.
