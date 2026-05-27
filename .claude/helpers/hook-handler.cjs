'use strict';
const { execSync, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const PROJECT_ROOT = path.resolve(__dirname, '..', '..');

// Global safety: exit cleanly if something hangs
const _safetyTimer = setTimeout(() => process.exit(0), 5000);
_safetyTimer.unref();

let _exitCode = 0; // module-level; set before process.exit()

const BASH_BLOCKLIST = [
  'rm -rf /', 'rm -rf ~', 'git push --force origin main', 'git push --force origin master',
  'git push -f origin main', 'git push -f origin master',
  'git reset --hard origin/main', 'git reset --hard origin/master',
  ':(){:|:&};:', 'format c:', 'rm --no-preserve-root', 'dd if='
];
const BASH_REGEX_BLOCKLIST = [/curl\s+.*\.env/i, /wget\s+.*\.env/i];
const SECRET_PATTERNS = [
  /AKIA[0-9A-Z]{16}/,                    // AWS key
  /sk-ant-[A-Za-z0-9\-_]{20,}/,         // Anthropic key
  /sk-[A-Za-z0-9]{20,}/,                // OpenAI key
  /ghp_[A-Za-z0-9]{36}/,               // GitHub PAT
  /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/,
  /password\s*[:=]\s*['"]?[^\s'"]{8,}/i
];
const SECRET_PATH_EXEMPTIONS = ['/tests/', '/test/', '.test.', '_test.', 'fixtures'];

function isTestPath(filePath) {
  return SECRET_PATH_EXEMPTIONS.some(p => filePath.includes(p));
}

function normalizeWhitespace(s) {
  return s.replace(/\s+/g, ' ').trim();
}

/**
 * Strip heredoc bodies and single/double-quoted string content from a command
 * so blocklist patterns only match actual shell directives, not message text.
 */
function stripStringContent(cmd) {
  // Remove heredoc bodies: everything between <<'EOF'/<<EOF delimiter lines
  let stripped = cmd.replace(/<<'?(\w+)'?[\s\S]*?\1/g, '<<HEREDOC');
  // Remove content inside single-quoted strings (preserve the quotes)
  stripped = stripped.replace(/'[^']*'/g, "''");
  // Remove content inside double-quoted strings that span more than one token
  // (conservative: only strip if string is longer than 20 chars)
  stripped = stripped.replace(/"[^"]{20,}"/g, '""');
  return normalizeWhitespace(stripped);
}

function emitEvent(type, pairs) {
  try {
    const eventBus = path.join(PROJECT_ROOT, 'core/event-bus/event-bus.sh');
    if (!fs.existsSync(eventBus)) return;
    // Pass all values as positional args ($1=eventBus, $2=type, $3..=pairs)
    // so no value is ever interpolated into shell source text.
    const script = `source "$1" && eb_emit_event "$2" ${pairs.map((_, i) => `"$${i + 3}"`).join(' ')}`;
    execFileSync('bash', ['-c', script, '--', eventBus, type, ...pairs], {
      timeout: 2000, stdio: ['ignore', 'ignore', 'pipe']
    });
  } catch (_) { /* non-fatal */ }
}

function readStdinTimeout(ms) {
  return new Promise(resolve => {
    if (process.stdin.isTTY) { resolve(''); return; }
    let data = '';
    const timer = setTimeout(() => { process.stdin.destroy(); resolve(data); }, ms);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => { data += chunk; });
    process.stdin.on('end', () => { clearTimeout(timer); resolve(data); });
    process.stdin.on('error', () => { clearTimeout(timer); resolve(data); });
  });
}

async function handlePreBash(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  // Support both {"command":"..."} and {"tool_input":{"command":"..."}} payloads
  const rawCmd = normalizeWhitespace(parsed.command || parsed.tool_input?.command || '');
  if (!rawCmd) return;
  // Strip heredoc bodies and quoted string content so blocklist matches
  // shell directives only — not literal text in commit messages, etc.
  const cmd = stripStringContent(rawCmd);

  for (const blocked of BASH_BLOCKLIST) {
    if (cmd.includes(blocked)) {
      // Do NOT include the dangerous command text in the event log
      emitEvent('hook.pre_bash.blocked', ['reason=blocklist']);
      process.stderr.write(`[zbuild hook] Blocked dangerous command: ${blocked}\n`);
      process.stdout.write(JSON.stringify({ decision: 'block', reason: `blocklist: ${blocked}` }) + '\n');
      _exitCode = 1;
      return;
    }
  }
  for (const re of BASH_REGEX_BLOCKLIST) {
    if (re.test(cmd)) {
      // Do NOT include the dangerous command text in the event log
      emitEvent('hook.pre_bash.blocked', ['reason=regex_blocklist']);
      process.stderr.write(`[zbuild hook] Blocked command matching pattern: ${re}\n`);
      process.stdout.write(JSON.stringify({ decision: 'block', reason: `regex_blocklist: ${re}` }) + '\n');
      _exitCode = 1;
      return;
    }
  }
  emitEvent('hook.pre_bash.allowed', [`command=${cmd.slice(0, 80)}`]);
}

async function handlePreEdit(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  const filePath = parsed.tool_input?.file_path || parsed.tool_input?.path || '';
  if (isTestPath(filePath)) return;

  // Collect content from all edit forms: Write/Edit (new_string/content) + MultiEdit (edits[].new_string)
  const parts = [
    parsed.tool_input?.new_string || '',
    parsed.tool_input?.content || '',
    ...(parsed.tool_input?.edits || []).map(e => e.new_string || ''),
  ];
  const content = parts.join('\n');
  if (!content.trim()) return;

  for (const pattern of SECRET_PATTERNS) {
    if (pattern.test(content)) {
      emitEvent('hook.pre_edit.blocked', [`file=${filePath}`, 'reason=secret_detected']);
      process.stderr.write(`[zbuild hook] Blocked write: secret pattern detected in ${filePath}\n`);
      process.stdout.write(JSON.stringify({ decision: 'block', reason: 'secret_detected' }) + '\n');
      _exitCode = 1;
      return;
    }
  }
  emitEvent('hook.pre_edit.allowed', [`file=${filePath}`]);
}

async function handlePostEdit(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  const filePath = parsed.tool_input?.file_path || parsed.tool_input?.path || '';
  emitEvent('hook.post_edit', [`file=${filePath}`]);
}

async function handlePostBash(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  const cmd = (parsed.tool_input?.command || '').slice(0, 80);
  const rc = parsed.tool_response?.exitCode ?? 0;
  emitEvent('hook.post_bash', [`command=${cmd}`, `exit_code=${rc}`]);
}

const ROUTE_DOMAINS = [
  { domain: 'pipeline', patterns: [/pipeline/i, /delivery/i, /\bissue\b.*\d+/i, /run.*pipeline/i] },
  { domain: 'test', patterns: [/test\s+suite/i, /run.*test/i, /\btests?\b/i, /\bspec\b/i] },
  { domain: 'build', patterns: [/\bbuild\b/i, /\bcompile\b/i, /\bnpm\s+run\b/i] },
  { domain: 'deploy', patterns: [/\bdeploy\b/i, /\brelease\b/i, /\bpublish\b/i] },
  { domain: 'review', patterns: [/\breview\b/i, /\bpr\b/i, /pull\s+request/i] },
];

async function handleRoute(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  const prompt = (parsed.prompt || '').slice(0, 120);

  // Classify the prompt domain
  let domain = 'general';
  for (const entry of ROUTE_DOMAINS) {
    if (entry.patterns.some(re => re.test(prompt))) {
      domain = entry.domain;
      break;
    }
  }

  process.stdout.write(`[ROUTE] domain=${domain} prompt_length=${prompt.length}\n`);
  emitEvent('hook.route', [`domain=${domain}`, `prompt_length=${prompt.length}`]);
}

async function handleSessionRestore(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  const sessionId = parsed.session_id || '';
  emitEvent('hook.session.restore', [`session_id=${sessionId}`]);
}

async function handleSessionEnd(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  const sessionId = parsed.session_id || '';
  emitEvent('hook.session.end', [`session_id=${sessionId}`]);
}

async function handleCompact(input, trigger) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  emitEvent('hook.compact', [`trigger=${trigger}`]);
}

async function handleSubagentStart(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  emitEvent('hook.subagent.start', [`agent=${parsed.agent_id || ''}`]);
}

async function handleSubagentStop(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  emitEvent('hook.subagent.stop', [`agent=${parsed.agent_id || ''}`]);
}

async function handleNotify(input) {
  let parsed = {};
  try { parsed = JSON.parse(input); } catch (_) { return; }
  emitEvent('hook.notify', [`message=${(parsed.message || '').slice(0, 80)}`]);
}

const handlers = {
  'pre-bash': handlePreBash,
  'pre-edit': handlePreEdit,
  'post-edit': handlePostEdit,
  'post-bash': handlePostBash,
  'route': handleRoute,
  'session-restore': handleSessionRestore,
  'session-end': handleSessionEnd,
  'compact-manual': (i) => handleCompact(i, 'manual'),
  'compact-auto': (i) => handleCompact(i, 'auto'),
  'subagent-start': handleSubagentStart,
  'subagent-stop': handleSubagentStop,
  'notify': handleNotify,
};

async function main() {
  const cmd = process.argv[2];
  if (!cmd || !handlers[cmd]) {
    // Unknown command — exit cleanly (don't block Claude)
    return;
  }
  const input = await readStdinTimeout(500);
  await handlers[cmd](input);
}

main().catch(() => {}).finally(() => process.exit(_exitCode));
