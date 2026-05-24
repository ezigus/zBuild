---
name: fleet-overview
description: Multi-repo fleet status dashboard
user_invocable: true
---

# Fleet Overview

Show the status of all Shipwright fleet operations across repos.

## Instructions

1. Read `~/.shipwright/fleet-config.json` to get configured repos
2. For each repo, check:
   - Active pipeline state (read `.claude/pipeline-state.md` in each repo)
   - Recent commits (last 3)
   - Any issues labeled `shipwright` (if GitHub CLI available: `gh issue list -l shipwright`)
3. Read `~/.shipwright/costs.json` for spending data
4. Read `~/.shipwright/budget.json` for budget limits
5. Present a summary table:
   - Repo | Status | Pipeline Stage | Workers | Cost
6. Show total fleet cost and remaining budget
7. If fleet is not configured, explain how to set it up: `shipwright fleet start`
