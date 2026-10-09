## Validation Thoroughness: Prove It Works in Production

Smoke tests are necessary but not sufficient. Validate the actual user experience.

### Smoke Test Design
- Test the critical user path end-to-end (not just health endpoints)
- Verify the SPECIFIC functionality from this issue works
- Include authentication flow if the feature requires auth
- Test with realistic data, not just empty/default states

### Health Check Layers
1. **Liveness** — Is the process running? (HTTP 200 on /health)
2. **Readiness** — Can it serve traffic? (dependencies connected, workers initialized)
3. **Functional** — Does the new feature actually work? (feature-specific endpoint test)

### Regression Detection
- Run the full test suite against the deployed environment (not just smoke)
- Compare response times to baseline — >20% regression is a red flag
- Verify existing features still work (not just the new one)
- Check error rates in logs for the first 100 requests

### Production Readiness Checklist
- [ ] Health endpoint returns 200
- [ ] Key feature endpoint returns expected response
- [ ] Error rate is below baseline threshold
- [ ] Response latency is within acceptable range (p95 < SLO)
- [ ] No new error patterns in logs
- [ ] Database connections are healthy
- [ ] External service integrations are working

### Issue Closure Criteria
Before automatically closing the issue:
1. Smoke tests pass
2. Health checks pass (5 consecutive successes)
3. No error rate spike in first 5 minutes
4. Feature-specific validation passes
5. PR is merged and deployed

### Failure Response
If validation fails:
1. Do NOT close the issue
2. Create an incident issue with validation failure details
3. Trigger rollback if auto-rollback is configured
4. Preserve deploy logs and smoke test output for debugging

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Smoke Test Specification**: Explicit test cases covering the critical user path with realistic data (not just health endpoints)
2. **Health Check Results**: Liveness check (process running), Readiness check (dependencies connected), Functional check (feature works)
3. **Regression Detection**: Comparison of response times to baseline, error rate against baseline threshold, log analysis for new error patterns
4. **Issue Closure Decision**: PASS/FAIL verdict with supporting evidence (all health checks passed, no error rate spike, feature-specific validation passed)

If any section is not applicable, explicitly state why it's skipped.
