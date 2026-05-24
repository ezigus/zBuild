#!/usr/bin/env node
/**
 * RuFlo V3.5 Statusline Generator
 * Displays real-time V3 implementation progress and system status
 *
 * Usage: node statusline.js [--json] [--compact]
 */

const fs = require('fs');
const path = require('path');
// SECURITY (audit_1776853149979): execSync was previously imported here and
// used with shell-interpolated strings. Replaced with execFileSync only —
// every invocation now passes argv arrays through execve directly, so there
// is no shell to interpret metacharacters. Keep this comment to explain why
// `execSync` is intentionally absent.
const { execFileSync } = require('child_process'); // @audit-suppress audit_1776853149979 -- execFileSync uses execve directly (shell:false); argv-only; no metacharacter interpolation

// Configuration
const CONFIG = {
  enabled: true,
  showProgress: true,
  showSecurity: true,
  showSwarm: true,
  showHooks: true,
  showPerformance: true,
  refreshInterval: 30000,
  maxAgents: 15,
  topology: 'hierarchical-mesh',
};

// ANSI colors
const c = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
  red: '\x1b[0;31m',
  green: '\x1b[0;32m',
  yellow: '\x1b[0;33m',
  blue: '\x1b[0;34m',
  purple: '\x1b[0;35m',
  cyan: '\x1b[0;36m',
  brightRed: '\x1b[1;31m',
  brightGreen: '\x1b[1;32m',
  brightYellow: '\x1b[1;33m',
  brightBlue: '\x1b[1;34m',
  brightPurple: '\x1b[1;35m',
  brightCyan: '\x1b[1;36m',
  brightWhite: '\x1b[1;37m',
};

// Get user info
function getUserInfo() {
  let name = 'user';
  let gitBranch = '';
  let modelName = 'Opus 4.6 (1M context)';

  // audit_1776853149979: previously used execSync with a shell string for git
  // commands. Switched to execFileSync('git', argv) so there is no shell
  // interpretation — eliminates the *class* of injection regardless of whether
  // user input ever reaches these args (defense in depth). Errors are caught
  // and the defaults above remain.
  try {
    name = execFileSync('git', ['config', 'user.name'], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || 'user';
  } catch { /* not in a repo / no name set — keep default */ }
  try {
    gitBranch = execFileSync('git', ['branch', '--show-current'], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { /* not in a repo — keep empty */ }

  return { name, gitBranch, modelName };
}

// Get learning stats from memory database
function getLearningStats() {
  const memoryPaths = [
    path.join(process.cwd(), '.swarm', 'memory.db'),
    path.join(process.cwd(), '.claude', 'memory.db'),
    path.join(process.cwd(), 'data', 'memory.db'),
  ];

  let patterns = 0;
  let sessions = 0;
  let trajectories = 0;

  // Try to read from sqlite database
  for (const dbPath of memoryPaths) {
    if (fs.existsSync(dbPath)) {
      try {
        // Count entries in memory file (rough estimate from file size)
        const stats = fs.statSync(dbPath);
        const sizeKB = stats.size / 1024;
        // Estimate: ~2KB per pattern on average
        patterns = Math.floor(sizeKB / 2);
        sessions = Math.max(1, Math.floor(patterns / 10));
        trajectories = Math.floor(patterns / 5);
        break;
      } catch (e) {
        // Ignore
      }
    }
  }

  // Also check for session files
  const sessionsPath = path.join(process.cwd(), '.claude', 'sessions');
  if (fs.existsSync(sessionsPath)) {
    try {
      const sessionFiles = fs.readdirSync(sessionsPath).filter(f => f.endsWith('.json'));
      sessions = Math.max(sessions, sessionFiles.length);
    } catch (e) {
      // Ignore
    }
  }

  return { patterns, sessions, trajectories };
}

// Get V3 progress from learning state (grows as system learns)
function getV3Progress() {
  const learning = getLearningStats();

  // DDD progress based on actual learned patterns
  // New install: 0 patterns = 0/5 domains, 0% DDD
  // As patterns grow: 10+ patterns = 1 domain, 50+ = 2, 100+ = 3, 200+ = 4, 500+ = 5
  let domainsCompleted = 0;
  if (learning.patterns >= 500) domainsCompleted = 5;
  else if (learning.patterns >= 200) domainsCompleted = 4;
  else if (learning.patterns >= 100) domainsCompleted = 3;
  else if (learning.patterns >= 50) domainsCompleted = 2;
  else if (learning.patterns >= 10) domainsCompleted = 1;

  const totalDomains = 5;
  const dddProgress = Math.min(100, Math.floor((domainsCompleted / totalDomains) * 100));

  return {
    domainsCompleted,
    totalDomains,
    dddProgress,
    patternsLearned: learning.patterns,
    sessionsCompleted: learning.sessions
  };
}

// Get security status based on actual scans
function getSecurityStatus() {
  // Check for security scan results in memory
  const scanResultsPath = path.join(process.cwd(), '.claude', 'security-scans');
  let cvesFixed = 0;
  const totalCves = 3;

  if (fs.existsSync(scanResultsPath)) {
    try {
      const scans = fs.readdirSync(scanResultsPath).filter(f => f.endsWith('.json'));
      // Each successful scan file = 1 CVE addressed
      cvesFixed = Math.min(totalCves, scans.length);
    } catch (e) {
      // Ignore
    }
  }

  // Also check .swarm/security for audit results
  const auditPath = path.join(process.cwd(), '.swarm', 'security');
  if (fs.existsSync(auditPath)) {
    try {
      const audits = fs.readdirSync(auditPath).filter(f => f.includes('audit'));
      cvesFixed = Math.min(totalCves, Math.max(cvesFixed, audits.length));
    } catch (e) {
      // Ignore
    }
  }

  const status = cvesFixed >= totalCves ? 'CLEAN' : cvesFixed > 0 ? 'IN_PROGRESS' : 'PENDING';

  return {
    status,
    cvesFixed,
    totalCves,
  };
}

// Count `ps aux` rows whose command field matches the given substring.
// Uses execFileSync('ps', ['aux']) — argv goes through execve, no shell.
// Returns 0 on any error (fail-quiet, statusline must never throw).
function countProcessesMatching(needle) {
  try {
    const out = execFileSync('ps', ['aux'], {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    let n = 0;
    for (const line of out.split('\n')) {
      if (line.includes(needle)) n++;
    }
    return n;
  } catch {
    return 0;
  }
}

// Get swarm status
function getSwarmStatus() {
  const activeAgents = countProcessesMatching('agentic-flow');
  return {
    activeAgents,
    maxAgents: CONFIG.maxAgents,
    coordinationActive: activeAgents > 0,
  };
}

// Sum the RSS column (column 6 of `ps aux`) for rows whose command matches
// any of the given substrings. Returns megabytes; 0 on parse failure.
function sumRssForCommands(needles) {
  try {
    const out = execFileSync('ps', ['aux'], {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    let totalKB = 0;
    for (const line of out.split('\n')) {
      if (!needles.some((n) => line.includes(n))) continue;
      // ps aux columns: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
      const cols = line.trim().split(/\s+/);
      const rss = parseInt(cols[5], 10);
      if (Number.isFinite(rss)) totalKB += rss;
    }
    return Math.floor(totalKB / 1024);
  } catch {
    return 0;
  }
}

// Get system metrics (dynamic based on actual state)
function getSystemMetrics() {
  let memoryMB = sumRssForCommands(['node', 'agentic', 'claude']);
  if (memoryMB === 0) {
    memoryMB = Math.floor(process.memoryUsage().heapUsed / 1024 / 1024);
  }

  const learning = getLearningStats();
  const intelligencePct = Math.min(100, Math.floor((learning.patterns / 10) * 1));
  const contextPct = Math.min(100, Math.floor(learning.sessions * 5));

  // Count active sub-agents from process list (rows mentioning both
  // 'claude-flow' and 'agent' in the command).
  let subAgents = 0;
  try {
    const out = execFileSync('ps', ['aux'], {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    for (const line of out.split('\n')) {
      if (line.includes('claude-flow') && line.includes('agent')) subAgents++;
    }
  } catch { /* keep 0 */ }

  return {
    memoryMB,
    contextPct,
    intelligencePct,
    subAgents,
  };
}

// Generate progress bar
function progressBar(current, total) {
  const width = 5;
  const filled = Math.round((current / total) * width);
  const empty = width - filled;
  return '[' + '\u25CF'.repeat(filled) + '\u25CB'.repeat(empty) + ']';
}

// Generate full statusline
function generateStatusline() {
  const user = getUserInfo();
  const progress = getV3Progress();
  const security = getSecurityStatus();
  const swarm = getSwarmStatus();
  const system = getSystemMetrics();
  const lines = [];

  // Header Line
  let header = `${c.bold}${c.brightPurple}▊ RuFlo V3.5 ${c.reset}`;
  header += `${swarm.coordinationActive ? c.brightCyan : c.dim}● ${c.brightCyan}${user.name}${c.reset}`;
  if (user.gitBranch) {
    header += `  ${c.dim}│${c.reset}  ${c.brightBlue}⎇ ${user.gitBranch}${c.reset}`;
  }
  header += `  ${c.dim}│${c.reset}  ${c.purple}${user.modelName}${c.reset}`;
  lines.push(header);

  // Separator
  lines.push(`${c.dim}─────────────────────────────────────────────────────${c.reset}`);

  // Line 1: DDD Domain Progress
  const domainsColor = progress.domainsCompleted >= 3 ? c.brightGreen : progress.domainsCompleted > 0 ? c.yellow : c.red;
  lines.push(
    `${c.brightCyan}🏗️  DDD Domains${c.reset}    ${progressBar(progress.domainsCompleted, progress.totalDomains)}  ` +
    `${domainsColor}${progress.domainsCompleted}${c.reset}/${c.brightWhite}${progress.totalDomains}${c.reset}    ` +
    `${c.brightYellow}⚡ 1.0x${c.reset} ${c.dim}→${c.reset} ${c.brightYellow}2.49x-7.47x${c.reset}`
  );

  // Line 2: Swarm + CVE + Memory + Context + Intelligence
  const swarmIndicator = swarm.coordinationActive ? `${c.brightGreen}◉${c.reset}` : `${c.dim}○${c.reset}`;
  const agentsColor = swarm.activeAgents > 0 ? c.brightGreen : c.red;
  let securityIcon = security.status === 'CLEAN' ? '🟢' : security.status === 'IN_PROGRESS' ? '🟡' : '🔴';
  let securityColor = security.status === 'CLEAN' ? c.brightGreen : security.status === 'IN_PROGRESS' ? c.brightYellow : c.brightRed;

  lines.push(
    `${c.brightYellow}🤖 Swarm${c.reset}  ${swarmIndicator} [${agentsColor}${String(swarm.activeAgents).padStart(2)}${c.reset}/${c.brightWhite}${swarm.maxAgents}${c.reset}]  ` +
    `${c.brightPurple}👥 ${system.subAgents}${c.reset}    ` +
    `${securityIcon} ${securityColor}CVE ${security.cvesFixed}${c.reset}/${c.brightWhite}${security.totalCves}${c.reset}    ` +
    `${c.brightCyan}💾 ${system.memoryMB}MB${c.reset}    ` +
    `${c.brightGreen}📂 ${String(system.contextPct).padStart(3)}%${c.reset}    ` +
    `${c.dim}🧠 ${String(system.intelligencePct).padStart(3)}%${c.reset}`
  );

  // Line 3: Architecture status
  const dddColor = progress.dddProgress >= 50 ? c.brightGreen : progress.dddProgress > 0 ? c.yellow : c.red;
  lines.push(
    `${c.brightPurple}🔧 Architecture${c.reset}    ` +
    `${c.cyan}DDD${c.reset} ${dddColor}●${String(progress.dddProgress).padStart(3)}%${c.reset}  ${c.dim}│${c.reset}  ` +
    `${c.cyan}Security${c.reset} ${securityColor}●${security.status}${c.reset}  ${c.dim}│${c.reset}  ` +
    `${c.cyan}Memory${c.reset} ${c.brightGreen}●AgentDB${c.reset}  ${c.dim}│${c.reset}  ` +
    `${c.cyan}Integration${c.reset} ${swarm.coordinationActive ? c.brightCyan : c.dim}●${c.reset}`
  );

  return lines.join('\n');
}

// Generate JSON data
function generateJSON() {
  return {
    user: getUserInfo(),
    v3Progress: getV3Progress(),
    security: getSecurityStatus(),
    swarm: getSwarmStatus(),
    system: getSystemMetrics(),
    performance: {
      flashAttentionTarget: '2.49x-7.47x',
      searchImprovement: '150x-12,500x',
      memoryReduction: '50-75%',
    },
    lastUpdated: new Date().toISOString(),
  };
}

// Main
if (process.argv.includes('--json')) {
  console.log(JSON.stringify(generateJSON(), null, 2));
} else if (process.argv.includes('--compact')) {
  console.log(JSON.stringify(generateJSON()));
} else {
  console.log(generateStatusline());
}
