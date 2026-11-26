import { VALIDATOR_PATH } from "./protocol.mjs";

const PUBLIC_PATH = "/v1/events";
const MAX_BODY_BYTES = 65_536;
const MAX_EVENTS = 25;
const ORIGIN_SECRET = /^[A-Za-z0-9_-]{32,128}$/;
const JSON_CONTENT_TYPE = /^application\/json(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?$/i;
const RETENTION_MS = 90 * 24 * 60 * 60 * 1000;
const PRUNE_LIMIT = 5_000;

const INSERT_EVENT = `
  INSERT INTO telemetry_events (
    event_id, install_id, schema_version, received_at_ms, kind, os, arch, ram_bucket,
    gpu_family, app_version, build, channel, launch_count, duration_ms, fps,
    memory_peak_mb, engine, game_name, success, load_ms, error_code
  ) VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(event_id) DO NOTHING`;

class BodyTooLarge extends Error {}

async function readBounded(message) {
  const length = message.headers.get("content-length");
  if (length !== null && Number(length) > MAX_BODY_BYTES) throw new BodyTooLarge();
  if (!message.body) return new Uint8Array();
  const reader = message.body.getReader();
  const output = new Uint8Array(MAX_BODY_BYTES);
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (size + value.byteLength > output.byteLength) {
        await reader.cancel().catch(() => {});
        throw new BodyTooLarge();
      }
      output.set(value, size);
      size += value.byteLength;
    }
    return output.subarray(0, size);
  } finally {
    reader.releaseLock();
  }
}

function reply(status, error, extraHeaders = {}) {
  const headers = {
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...extraHeaders,
  };
  return error ? Response.json({ error }, { status, headers }) : new Response(null, { status, headers });
}

function preflight(request) {
  const method = request.headers.get("Access-Control-Request-Method");
  const headers = request.headers.get("Access-Control-Request-Headers");
  if (method !== "POST" || (headers && headers.split(",").some(name => name.trim().toLowerCase() !== "content-type"))) {
    return reply(400, "invalid_preflight");
  }
  return reply(204, null, {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "600",
  });
}

async function validate(body, env) {
  if (!ORIGIN_SECRET.test(env.TELEMETRY_ORIGIN_SECRET ?? "")) throw new Error("Missing origin secret");
  const options = {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.TELEMETRY_ORIGIN_SECRET}`,
      "Content-Type": "application/json; charset=utf-8",
    },
    body,
    redirect: "manual",
    signal: AbortSignal.timeout(30_000),
  };
  if (env.TELEMETRY_VALIDATOR) {
    const instance = env.TELEMETRY_VALIDATOR.getByName("telemetry-v1");
    return instance.fetch(new Request(`http://container${VALIDATOR_PATH}`, options));
  }

  const origin = new URL(env.TELEMETRY_ORIGIN_URL);
  const loopbackDev = env.TELEMETRY_LOCAL_HTTP === "true" && origin.hostname === "127.0.0.1" && origin.protocol === "http:";
  if ((!loopbackDev && origin.protocol !== "https:") || origin.username || origin.password ||
      origin.pathname !== "/" || origin.search || origin.hash) {
    throw new Error("Invalid validator origin URL");
  }
  if (!loopbackDev) options.headers["X-Real-IP"] = "0.0.0.0";
  return fetch(new URL(VALIDATOR_PATH, origin), options);
}

async function store(db, events, receivedAtMs) {
  const insert = db.prepare(INSERT_EVENT);
  const results = await db.batch(events.map(event => insert.bind(
    event.event_id, event.install_id, receivedAtMs, event.kind, event.os, event.arch,
    event.ram_bucket, event.gpu_family, event.app_version, event.build, event.channel,
    event.launch_count ?? null, event.duration_ms ?? null, event.fps ?? null,
    event.memory_peak_mb ?? null, event.engine ?? null, event.game_name ?? null,
    event.success == null ? null : Number(event.success), event.load_ms ?? null, event.error_code ?? null,
  )));
  if (results.length !== events.length || results.some(result => !result.success)) {
    throw new Error("D1 batch failed");
  }
}

async function ingest(request, env) {
  const receivedAtMs = Date.now();
  if (!JSON_CONTENT_TYPE.test(request.headers.get("content-type") ?? "") || request.headers.has("content-encoding")) {
    return reply(415, "expected_utf8_json");
  }
  let body;
  try {
    body = await readBounded(request);
  } catch (error) {
    return error instanceof BodyTooLarge ? reply(413, "body_too_large") : reply(400, "invalid_body");
  }

  try {
    const result = await validate(body, env);
    if (result.status !== 200) {
      await result.body?.cancel();
      if (result.status === 400) return reply(400, "invalid_events");
      if (result.status === 413) return reply(413, "body_too_large");
      return reply(503, "temporarily_unavailable");
    }
    if (!JSON_CONTENT_TYPE.test(result.headers.get("content-type") ?? "")) {
      await result.body?.cancel();
      return reply(503, "temporarily_unavailable");
    }
    const validated = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await readBounded(result)));
    if (validated.schema_version !== 1 || !Array.isArray(validated.events) ||
        validated.events.length < 1 || validated.events.length > MAX_EVENTS) {
      return reply(503, "temporarily_unavailable");
    }
    await store(env.TELEMETRY_DB, validated.events, receivedAtMs);
  } catch {
    // Never log exceptions from the validator or D1, which can contain request data.
    return reply(503, "temporarily_unavailable");
  }
  return reply(204);
}

async function prune(db, scheduledTime) {
  const cutoff = scheduledTime - RETENTION_MS;
  for (let attempt = 0; attempt < 10; attempt++) {
    const result = await db.prepare(`
      DELETE FROM telemetry_events WHERE rowid IN (
        SELECT rowid FROM telemetry_events WHERE received_at_ms < ? ORDER BY received_at_ms LIMIT ?
      )`).bind(cutoff, PRUNE_LIMIT).run();
    if (!result.success) throw new Error("D1 retention job failed");
    if (result.meta.changes < PRUNE_LIMIT) return;
  }
}

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== PUBLIC_PATH || url.search) return reply(404, "not_found");
    if (request.method === "OPTIONS") return preflight(request);
    if (request.method !== "POST") return reply(405, "method_not_allowed", { Allow: "POST, OPTIONS" });
    return ingest(request, env);
  },

  async scheduled(controller, env) {
    try {
      await prune(env.TELEMETRY_DB, controller.scheduledTime);
    } catch {
      throw new Error("Telemetry retention job failed");
    }
  },
};
