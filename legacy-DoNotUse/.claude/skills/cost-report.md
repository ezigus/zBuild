---
name: cost-report
description: Token usage and cost analysis
user_invocable: true
---

# Cost Report

Analyze Shipwright token usage and costs.

## Instructions

1. Run `shipwright cost show` to get the cost dashboard output
2. Read `~/.shipwright/costs.json` for detailed cost data
3. Read `~/.shipwright/budget.json` for budget configuration
4. Calculate:
   - Total spend today, this week, this month
   - Average cost per pipeline run
   - Most expensive pipeline runs
   - Cost breakdown by stage (build vs test vs review)
5. Compare against budget:
   - Daily budget limit vs actual
   - Remaining budget for today
   - Projected monthly cost at current rate
6. Provide optimization suggestions:
   - Switch to `cost-aware` template for non-critical work
   - Use model routing (haiku for simple stages, opus for complex)
   - Reduce max_iterations for build loops
   - Enable fast-test-cmd to reduce test overhead
7. Present as a clean report with tables and recommendations
