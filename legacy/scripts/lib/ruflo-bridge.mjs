#!/usr/bin/env node
// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║  ruflo-bridge — Long-lived Node bridge for ruflo MCP calls               ║
// ║                                                                           ║
// ║  Listens on a unix domain socket for newline-delimited JSON requests of   ║
// ║  the shape {"tool": "...", "args": {...}}. Each request is dispatched     ║
// ║  either to an in-process import('ruflo') (preferred — sub-millisecond)    ║
// ║  or to a `ruflo mcp exec` subprocess (fallback — keeps Node module cache  ║
// ║  warm so cost is amortized across all calls in a pipeline run).           ║
// ║                                                                           ║
// ║  Wire format (request):  {"tool":"<name>","args":{...}}\n                 ║
// ║  Wire format (response): {"success":true,"result":...}\n                  ║
// ║                       OR {"success":false,"error":"...","code":"..."}\n   ║
// ║                                                                           ║
// ║  Lifecycle:                                                               ║
// ║    1. Stale socket file is unlinked before listen() (crash recovery)     ║
// ║    2. PID file is written *after* listen() resolves (no stale PID race)   ║
// ║    3. SIGTERM/SIGINT close server, unlink socket and PID file, exit 0    ║
// ║                                                                           ║
// ║  The bridge owns transport only — never caches, schedules, or retries.    ║
// ║  Lifecycle wiring into ruflo_init/ruflo_cleanup is deferred to #502.      ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

import net from "node:net";
import readline from "node:readline";
import { existsSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { homedir } from "node:os";
import { execFileSync } from "node:child_process";

const VERSION = "3.6.1";

const SOCK =
  process.env.RUFLO_BRIDGE_SOCK ||
  `${homedir()}/.shipwright/ruflo-bridge.sock`;
const PID_FILE = `${SOCK}.pid`;
const DISPATCH_TIMEOUT_MS = Number(
  process.env.RUFLO_BRIDGE_DISPATCH_TIMEOUT_MS || 10_000,
);
const STARTED_AT = Date.now();

// Resolve ruflo binary lazily so we can skip subprocess fallback in tests.
const RUFLO_BIN = process.env.RUFLO_BIN || "ruflo";

// ─── In-process module probe ────────────────────────────────────────────────
// The upstream ruflo package may or may not expose ESM bindings. We try once
// at startup; if the import fails or the requested tool isn't a function on
// the resolved module, dispatch falls back to `ruflo mcp exec`. Either path
// benefits from the bridge: the Node runtime stays warm.
let rufloModule = null;
let rufloImportError = null;
try {
  rufloModule = await import("ruflo");
} catch (err) {
  rufloImportError = err;
}

function logStderr(msg) {
  process.stderr.write(`ruflo-bridge: ${msg}\n`);
}

// ─── dispatch — route a single (tool, args) call to its handler ─────────────
// Errors are propagated to the per-connection handler which wraps them as
// {success:false,...}; never throws synchronously back into net.createServer.
async function dispatch(tool, args) {
  if (typeof tool !== "string" || tool.length === 0) {
    const e = new Error("missing tool name");
    e.code = "invalid_request";
    throw e;
  }
  if (args !== undefined && (args === null || typeof args !== "object" || Array.isArray(args))) {
    const e = new Error("args must be an object");
    e.code = "invalid_request";
    throw e;
  }
  const safeArgs = args || {};

  if (tool === "ping") {
    return {
      pong: true,
      uptime_ms: Date.now() - STARTED_AT,
      version: VERSION,
      pid: process.pid,
    };
  }

  // Preferred path: in-process call into ruflo module.
  if (rufloModule && typeof rufloModule[tool] === "function") {
    return await rufloModule[tool](safeArgs);
  }

  // Fallback: shell out. Node module cache stays warm; only the ruflo CLI
  // binary cold-starts (~30ms vs 200–500ms total when called fresh from bash).
  try {
    const out = execFileSync(
      RUFLO_BIN,
      ["mcp", "exec", "--tool", tool, "--args", JSON.stringify(safeArgs)],
      { encoding: "utf8", timeout: DISPATCH_TIMEOUT_MS },
    );
    const trimmed = out.trim();
    if (!trimmed) return null;
    try {
      return JSON.parse(trimmed);
    } catch {
      return trimmed;
    }
  } catch (err) {
    if (err && err.code === "ENOENT") {
      const e = new Error(`unknown tool: ${tool}`);
      e.code = "unknown_tool";
      throw e;
    }
    if (err && err.signal === "SIGTERM") {
      const e = new Error(`dispatch exceeded ${DISPATCH_TIMEOUT_MS}ms`);
      e.code = "dispatch_timeout";
      throw e;
    }
    const e = new Error(err && err.message ? err.message : String(err));
    e.code = "ruflo_runtime";
    throw e;
  }
}

// ─── socket setup — remove stale socket, ensure parent dir exists ───────────
function prepareSocketPath(sockPath) {
  const parent = dirname(sockPath);
  if (!existsSync(parent)) mkdirSync(parent, { recursive: true });
  if (existsSync(sockPath)) {
    try {
      unlinkSync(sockPath);
    } catch {
      // best-effort — listen() will surface a real error if the path is busy
    }
  }
}

prepareSocketPath(SOCK);

// ─── server — newline-delimited JSON framing per connection ─────────────────
const server = net.createServer((conn) => {
  const rl = readline.createInterface({ input: conn });
  rl.on("line", async (line) => {
    let resp;
    try {
      let req;
      try {
        req = JSON.parse(line);
      } catch (parseErr) {
        const e = new Error(`JSON parse failed: ${parseErr.message}`);
        e.code = "invalid_request";
        throw e;
      }
      const result = await dispatch(req && req.tool, req && req.args);
      resp = { success: true, result };
    } catch (err) {
      resp = {
        success: false,
        error: String((err && err.message) || err || "unknown error"),
        code: (err && err.code) || "ruflo_runtime",
      };
    }
    try {
      conn.write(JSON.stringify(resp) + "\n");
    } catch {
      // connection died mid-write — server stays up
    }
    conn.end();
  });
  conn.on("error", () => {
    // ignore client-side disconnects; never crash the server
  });
});

server.on("error", (err) => {
  logStderr(`server error: ${err.message}`);
  process.exitCode = 1;
});

server.listen(SOCK, () => {
  try {
    writeFileSync(PID_FILE, String(process.pid));
  } catch (err) {
    logStderr(`failed to write PID file: ${err.message}`);
  }
  const dispatchMode = rufloModule ? "in-process" : "subprocess";
  logStderr(
    `ready on ${SOCK} (pid=${process.pid}, version=${VERSION}, dispatch=${dispatchMode})`,
  );
  if (!rufloModule && rufloImportError) {
    logStderr(`in-process import unavailable: ${rufloImportError.message}`);
  }
});

// ─── shutdown — tear down socket and PID file on signal ─────────────────────
let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  try {
    server.close();
  } catch {
    // ignore — the unlinks below are what actually matter
  }
  try {
    if (existsSync(SOCK)) unlinkSync(SOCK);
  } catch {
    // best-effort
  }
  try {
    if (existsSync(PID_FILE)) unlinkSync(PID_FILE);
  } catch {
    // best-effort
  }
  logStderr(`shutdown (signal=${signal || "unknown"})`);
  process.exit(0);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGHUP", () => shutdown("SIGHUP"));
