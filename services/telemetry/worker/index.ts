import { validateEvents } from './validator.ts';
import type { TelemetryEvent } from './validator.ts';

interface Env {
  TELEMETRY_DB: D1Database;
  TELEMETRY_RATE_LIMIT?: RateLimit;
}

const PUBLIC_PATH = '/v1/events';
const MAX_BODY_BYTES = 65_536;
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

async function readBounded(request: Request): Promise<Uint8Array> {
  if (Number(request.headers.get('content-length')) > MAX_BODY_BYTES) throw new BodyTooLarge();
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const output = new Uint8Array(MAX_BODY_BYTES);
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return output.subarray(0, size);
      if (size + value.byteLength > output.byteLength) {
        await reader.cancel().catch(() => {});
        throw new BodyTooLarge();
      }
      output.set(value, size);
      size += value.byteLength;
    }
  } finally {
    reader.releaseLock();
  }
}

function reply(status: number, error?: string, extraHeaders: Record<string, string> = {}): Response {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...extraHeaders,
  };
  return error ? Response.json({ error }, { status, headers }) : new Response(null, { status, headers });
}

function preflight(request: Request): Response {
  const method = request.headers.get('Access-Control-Request-Method');
  const headers = request.headers.get('Access-Control-Request-Headers');
  if (method !== 'POST' || headers?.split(',').some(name => name.trim().toLowerCase() !== 'content-type')) {
    return reply(400, 'invalid_preflight');
  }
  return reply(204, undefined, {
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '600',
  });
}

async function store(db: D1Database, events: TelemetryEvent[], receivedAtMs: number): Promise<void> {
  const insert = db.prepare(INSERT_EVENT);
  const results = await db.batch(events.map(event => insert.bind(
    event.event_id, event.install_id, receivedAtMs, event.kind, event.os, event.arch,
    event.ram_bucket, event.gpu_family, event.app_version, event.build, event.channel,
    event.launch_count ?? null, event.duration_ms ?? null, event.fps ?? null,
    event.memory_peak_mb ?? null, event.engine ?? null, event.game_name ?? null,
    event.success == null ? null : Number(event.success), event.load_ms ?? null, event.error_code ?? null,
  )));
  if (results.length !== events.length || results.some(result => !result.success)) {
    throw new Error('D1 batch failed');
  }
}

async function ingest(request: Request, env: Env): Promise<Response> {
  const receivedAtMs = Date.now();
  if (!JSON_CONTENT_TYPE.test(request.headers.get('content-type') ?? '') || request.headers.has('content-encoding')) {
    return reply(415, 'expected_utf8_json');
  }
  if (env.TELEMETRY_RATE_LIMIT) {
    // Only the Cloudflare limiter receives the source address.
    const source = request.headers.get('CF-Connecting-IP') ?? 'unknown';
    try {
      const { success } = await env.TELEMETRY_RATE_LIMIT.limit({ key: source });
      if (!success) {
        return reply(429, 'rate_limited', {
          'Retry-After': '10',
          'Access-Control-Expose-Headers': 'Retry-After',
        });
      }
    } catch {
      return reply(503, 'temporarily_unavailable');
    }
  }
  let body: Uint8Array;
  try {
    body = await readBounded(request);
  } catch (error) {
    return error instanceof BodyTooLarge ? reply(413, 'body_too_large') : reply(400, 'invalid_body');
  }
  try {
    const validated = validateEvents(body);
    if (validated === null) return reply(400, 'invalid_events');
    await store(env.TELEMETRY_DB, validated.events, receivedAtMs);
  } catch {
    // Database errors can contain event data. Keep responses generic.
    return reply(503, 'temporarily_unavailable');
  }
  return reply(204);
}

async function prune(db: D1Database, scheduledTime: number): Promise<void> {
  const cutoff = scheduledTime - RETENTION_MS;
  for (let attempt = 0; attempt < 10; attempt++) {
    const result = await db.prepare(`
      DELETE FROM telemetry_events WHERE rowid IN (
        SELECT rowid FROM telemetry_events WHERE received_at_ms < ? ORDER BY received_at_ms LIMIT ?
      )`).bind(cutoff, PRUNE_LIMIT).run();
    if (!result.success) throw new Error('D1 retention job failed');
    if (result.meta.changes < PRUNE_LIMIT) return;
  }
}

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== PUBLIC_PATH || url.search) return reply(404, 'not_found');
    if (request.method === 'OPTIONS') return preflight(request);
    if (request.method !== 'POST') return reply(405, 'method_not_allowed', { Allow: 'POST, OPTIONS' });
    return ingest(request, env);
  },

  async scheduled(controller, env) {
    try {
      await prune(env.TELEMETRY_DB, controller.scheduledTime);
    } catch {
      throw new Error('Telemetry retention job failed');
    }
  },
} satisfies ExportedHandler<Env>;
