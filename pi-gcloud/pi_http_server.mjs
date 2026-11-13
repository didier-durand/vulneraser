#!/usr/bin/env node
// pi_http_server.mjs — HTTP wrapper around Pi's RPC mode for Google Cloud Run.
//
// Cloud Run requires an HTTP server listening on $PORT. Pi's RPC mode is a
// JSONL protocol over stdin/stdout, so this server spawns a `pi --mode rpc`
// subprocess per request, sends the prompt, collects the streamed text deltas,
// and returns them as an HTTP JSON response.
//
// Endpoints:
//   GET  /health        → {"status":"ok"}
//   POST /prompt        → {"message":"..."}  →  {"text":"...", "usage":{...}}
//   POST /prompt?stream=1 → {"message":"..."}  →  SSE stream of text deltas
//
// This file runs inside the container; Cloud Run sends HTTP requests to it.

import { createServer } from "node:http";
import { spawn } from "node:child_process";

const PORT = parseInt(process.env.PORT || "8080", 10);
const PI_BIN = process.env.PI_BIN || "pi";

function spawnPi() {
  return spawn(PI_BIN, ["--mode", "rpc", "--no-session"], {
    stdio: ["pipe", "pipe", "inherit"],
  });
}

/** Send a JSONL command to Pi's stdin. */
function sendCommand(child, command) {
  return new Promise((resolve, reject) => {
    child.stdin.write(JSON.stringify(command) + "\n", (err) => {
      if (err) reject(err);
      else resolve();
    });
  });
}

/**
 * Send a prompt and collect the full assistant response.
 * Returns { text, usage, model, disposition }.
 */
function promptAndWait(child, message, cmdId) {
  return new Promise((resolve, reject) => {
    let text = "";
    let sawResponse = false;
    let disposition = null;
    let usage = null;
    let model = null;
    let buffer = "";

    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString("utf-8");
      let idx;
      while ((idx = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, idx).replace(/\r$/, "");
        buffer = buffer.slice(idx + 1);
        if (!line.trim()) continue;
        let record;
        try {
          record = JSON.parse(line);
        } catch {
          continue;
        }

        if (
          record.type === "response" &&
          record.id === cmdId
        ) {
          sawResponse = true;
          if (!record.success) {
            reject(new Error(record.error || "prompt rejected"));
            return;
          }
          disposition = record.data?.disposition;
          if (disposition === "handled") {
            resolve({ text: "", disposition, usage: null, model: null });
            return;
          }
          continue;
        }

        if (record.type === "message_update") {
          const event = record.assistantMessageEvent;
          if (event?.type === "text_delta") {
            text += event.delta || "";
          }
        }

        if (record.type === "message_end") {
          const msg = record.message;
          if (msg?.role === "assistant") {
            usage = msg.usage;
            model = msg.model;
          }
        }

        if (record.type === "agent_settled") {
          if (!sawResponse) {
            reject(new Error("agent settled without a prompt response"));
            return;
          }
          resolve({ text, disposition, usage, model });
        }
      }
    });

    child.on("error", (err) => reject(err));
    child.on("exit", (code) => {
      if (!sawResponse) {
        reject(new Error(`pi exited (code ${code}) before responding`));
      }
    });

    sendCommand(child, { id: cmdId, type: "prompt", message }).catch(reject);
  });
}

/**
 * Send a prompt and stream text deltas as Server-Sent Events.
 * Each delta is sent as `data: {"delta":"..."}\n\n`.
 * On completion: `data: {"done":true}\n\n`.
 */
function promptStream(res, message, cmdId) {
  const child = spawnPi();
  let sawResponse = false;

  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });

  let buffer = "";

  child.stdout.on("data", (chunk) => {
    buffer += chunk.toString("utf-8");
    let idx;
    while ((idx = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, idx).replace(/\r$/, "");
      buffer = buffer.slice(idx + 1);
      if (!line.trim()) continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }

      if (record.type === "response" && record.id === cmdId) {
        sawResponse = true;
        if (!record.success) {
          res.write(`data: ${JSON.stringify({ error: record.error })}\n\n`);
          res.end();
          return;
        }
        continue;
      }

      if (record.type === "message_update") {
        const event = record.assistantMessageEvent;
        if (event?.type === "text_delta") {
          res.write(`data: ${JSON.stringify({ delta: event.delta || "" })}\n\n`);
        }
      }

      if (record.type === "agent_settled") {
        res.write(`data: ${JSON.stringify({ done: true })}\n\n`);
        res.end();
      }
    }
  });

  child.on("error", (err) => {
    res.write(`data: ${JSON.stringify({ error: err.message })}\n\n`);
    res.end();
  });

  child.on("exit", () => {
    if (!res.writableEnded) {
      res.write(`data: ${JSON.stringify({ done: true })}\n\n`);
      res.end();
    }
  });

  sendCommand(child, { id: cmdId, type: "prompt", message }).catch(() => {
    res.write(`data: ${JSON.stringify({ error: "failed to send command" })}\n\n`);
    res.end();
  });
}

// --- HTTP server

const server = createServer(async (req, res) => {
  // CORS
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  // Health check
  if (req.method === "GET" && (req.url === "/health" || req.url === "/")) {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  // Prompt endpoint
  if (req.method === "POST" && req.url?.startsWith("/prompt")) {
    let body = "";
    for await (const chunk of req) body += chunk;
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "invalid JSON body" }));
      return;
    }
    if (!parsed.message || typeof parsed.message !== "string") {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "missing 'message' field" }));
      return;
    }

    const cmdId = `http-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

    // Streaming via SSE
    const isStream = req.url.includes("stream=1") || req.url.includes("stream=true");
    if (isStream) {
      promptStream(res, parsed.message, cmdId);
      return;
    }

    // Non-streaming: collect full response
    const child = spawnPi();
    try {
      const result = await promptAndWait(child, parsed.message, cmdId);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        text: result.text,
        disposition: result.disposition,
        model: result.model,
        usage: result.usage,
      }));
    } catch (err) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: err.message }));
    } finally {
      child.stdin?.end();
      child.kill();
    }
    return;
  }

  // 404
  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "not found", endpoints: ["GET /health", "POST /prompt"] }));
});

server.listen(PORT, () => {
  console.log(`pi-http-server listening on :${PORT}`);
  console.log(`  GET  /health   — health check`);
  console.log(`  POST /prompt   — { "message": "..." } → { "text": "..." }`);
  console.log(`  POST /prompt?stream=1 — SSE stream`);
});
