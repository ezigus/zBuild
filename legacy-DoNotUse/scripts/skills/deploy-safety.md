## Deploy Safety: Ship Without Breaking Production

Every deploy is a controlled experiment. Verify before promoting.

### Pre-Deploy Checklist
- [ ] All CI checks green on the exact commit being deployed
- [ ] No open critical/security review findings
- [ ] Database migrations are backward-compatible (old code can run with new schema)
- [ ] Feature flags are in place for risky changes
- [ ] Rollback plan is documented and tested

### Blue-Green / Canary Strategy
1. Deploy to inactive slot (green) — do NOT shift traffic yet
2. Run health checks against green slot directly
3. Run smoke tests against green slot
4. Shift small percentage of traffic (canary: 5-10%)
5. Monitor error rates for 5 minutes
6. If clean, promote to 100%
7. If errors spike, rollback immediately

### Rollback Readiness
- Verify rollback command works BEFORE deploying
- Keep previous version running until new version is verified
- Database migrations must be reversible (never drop columns in same deploy)
- Cache invalidation: new version must handle old cached data

### Deploy Risk by Issue Type

**Frontend deploys:**
- CDN cache invalidation timing
- Browser cache busting (new asset hashes)
- Progressive enhancement for users with old cached bundles

**API deploys:**
- Backward compatibility with existing clients
- API versioning if breaking changes
- Rate limit configuration for new endpoints

**Database deploys:**
- Migration order: schema first, then code, then cleanup
- Backfill operations should be idempotent
- Monitor query performance after index changes

**Infrastructure deploys:**
- DNS propagation delay
- Connection draining for load balancer changes
- Secret rotation: both old and new must work during transition

### Incident Prevention
- Deploy during low-traffic windows when possible
- Have a human (or monitor) watching for 15 minutes post-deploy
- Set up alerts for error rate spikes before deploying
- Never deploy on Friday unless it's a hotfix

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Pre-Deploy Checklist**: Verification of all items (CI green, no critical findings, migrations backward-compatible, feature flags in place, rollback plan tested)
2. **Blue-Green Strategy**: Specific sequence of steps from green deployment through canary through full promotion
3. **Rollback Verification**: Confirmation that rollback command has been tested and works (not just theoretical)
4. **Deploy Risk Assessment**: Explicit identification of risks by issue type (frontend cache, API compatibility, database migration, infrastructure changes)

If any section is not applicable, explicitly state why it's skipped.
