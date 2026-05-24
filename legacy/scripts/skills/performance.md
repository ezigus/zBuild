## Performance Expertise

Apply these optimization patterns:

### Profiling First
- Measure before optimizing — identify the actual bottleneck
- Use profiling tools appropriate to the language/runtime
- Focus on the critical path — optimize what users experience

### Caching Strategy
- Cache expensive computations and repeated queries
- Set appropriate TTLs — stale data vs freshness trade-off
- Invalidate caches on write operations
- Use cache layers: in-memory (L1) → distributed (L2) → database (L3)

### Database Performance
- Add indexes for frequently queried columns (check EXPLAIN plans)
- Avoid N+1 queries — use batch loading or JOINs
- Use connection pooling
- Consider read replicas for read-heavy workloads

### Algorithm Complexity
- Prefer O(n log n) over O(n²) for sorting/searching
- Use appropriate data structures (hash maps for lookups, trees for ranges)
- Avoid unnecessary allocations in hot paths
- Pre-compute values that are used repeatedly

### Network Optimization
- Minimize round trips — batch API calls where possible
- Use compression for large payloads
- Implement pagination — never return unbounded result sets
- Use CDNs for static assets

### Benchmarking
- Include before/after benchmarks for performance changes
- Test with realistic data volumes (not just unit test fixtures)
- Measure p50, p95, p99 latencies — not just averages

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Baseline Metrics**: Current performance metrics before optimization (p50/p95/p99 latency, throughput, resource usage)
2. **Optimization Targets**: Specific targets (e.g., "reduce p95 latency from 250ms to <100ms") with rationale
3. **Profiling Strategy**: Tools and methodology to identify bottlenecks (CPU profiler, memory profiler, query analyzer, benchmarks)
4. **Benchmark Plan**: Before/after benchmarks with realistic data volume and success criteria for each optimization

If any section is not applicable, explicitly state why it's skipped.
