---
name: agent-debug
description: Debug a stuck or failing Skipper agent
user_invocable: true
---

# Agent Debug

Diagnose why a Skipper agent is stuck or failing.

## Instructions

1. Check running agent processes: `shipwright ps` or `shipwright heartbeat list`
2. Check agent logs: look in `~/.shipwright/logs/` for recent log files
3. Check for heartbeat staleness:
   - Read `~/.shipwright/heartbeats/` directory
   - Any heartbeat file older than 5 minutes indicates a stuck agent
4. Check resource usage: memory and CPU via system tools
5. Check for context exhaustion: look for "context" or "compaction" in recent logs
6. Check for error patterns in `~/.shipwright/memory/` (failure pattern store)
7. Provide diagnosis:
   - Is the agent stuck (stale heartbeat)?
   - Is it in an error loop (repeated failures in memory)?
   - Has it exhausted context (needs session restart)?
   - Is it resource-constrained (high CPU/memory)?
8. Suggest remediation:
   - For stuck agents: `shipwright cleanup --force`
   - For error loops: check the specific error pattern and fix
   - For context exhaustion: restart with `--max-restarts`
   - For resource issues: reduce `max_parallel` in daemon config
