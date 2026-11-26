const MAX_BODY_BYTES = 65_536;
const MAX_EVENTS = 25;
const MAX_EVENT_FIELDS = 15;
const MAX_DURATION_MS = 86_400_000;

const OS = ["Windows", "macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD", "Android", "iOS", "Web", "Unknown"] as const;
const ARCH = ["x86_64", "x86_32", "arm64", "arm32", "riscv64", "riscv32", "wasm64", "wasm32", "unknown"] as const;
const RAM = ["lt_4_gb", "4_7_gb", "8_15_gb", "16_31_gb", "32_63_gb", "gte_64_gb", "unknown"] as const;
const GPU = [
  "geforce_rtx", "geforce_gtx", "nvidia_rtx", "nvidia", "radeon_rx", "amd",
  "intel_arc", "intel_iris", "intel_uhd", "intel", "apple", "adreno", "mali", "powervr", "software", "unknown",
] as const;

const COMMON_FIELDS = new Set([
  "event_id", "install_id", "kind", "os", "arch", "ram_bucket", "gpu_family", "app_version", "build", "channel",
]);
const KIND_FIELDS = new Map([
  ["app_start", new Set(["launch_count"])],
  ["app_usage", new Set(["duration_ms", "fps", "memory_peak_mb"])],
  ["engine_start", new Set(["engine", "game_name", "success", "load_ms", "error_code"])],
  ["engine_usage", new Set(["engine", "game_name", "duration_ms", "fps", "memory_peak_mb"])],
  ["engine_error", new Set(["engine", "game_name", "error_code"])],
]);
const EVENT_FIELDS = new Set([...COMMON_FIELDS, ...Array.from(KIND_FIELDS.values()).flatMap(fields => [...fields])]);

export type TelemetryEvent = {
  event_id: string;
  install_id: string;
  kind: "app_start" | "app_usage" | "engine_start" | "engine_usage" | "engine_error";
  os: (typeof OS)[number];
  arch: (typeof ARCH)[number];
  ram_bucket: (typeof RAM)[number];
  gpu_family: (typeof GPU)[number];
  app_version: string;
  build: string;
  channel: string;
  launch_count?: 1;
  duration_ms?: number;
  fps?: number | null;
  memory_peak_mb?: number;
  engine?: string;
  game_name?: string;
  success?: boolean;
  load_ms?: number;
  error_code?: string;
};

export type TelemetryEnvelope = { schema_version: 1; events: TelemetryEvent[] };

type Scalar = string | number | boolean | null;
type EventFields = Record<string, Scalar | undefined>;

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const RELEASE = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/;
const TOKEN = /^[a-z0-9][a-z0-9_-]{0,39}$/;
const GAME_NAME_LENGTH = /^.{1,120}$/u;
const FORBIDDEN_GAME_NAME = /^\p{Z}|\p{Z}$|[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}/\\:]/u;

function matches(value: Scalar | undefined, pattern: RegExp): boolean {
  return typeof value === "string" && pattern.test(value);
}

function inRange(value: Scalar | undefined, max: number): boolean {
  // The parser only produces integer numbers.
  return typeof value === "number" && value >= 0 && value <= max;
}

function isTelemetryEvent(event: EventFields): event is EventFields & TelemetryEvent {
  const { kind, game_name: gameName } = event;
  if (typeof kind !== "string") return false;
  const allowed = KIND_FIELDS.get(kind);
  if (!allowed || Object.keys(event).some(key => !COMMON_FIELDS.has(key) && !allowed.has(key))) return false;

  if (!matches(event.event_id, UUID_V4) || !matches(event.install_id, UUID_V4) ||
      !(OS as readonly unknown[]).includes(event.os) || !(ARCH as readonly unknown[]).includes(event.arch) ||
      !(RAM as readonly unknown[]).includes(event.ram_bucket) || !(GPU as readonly unknown[]).includes(event.gpu_family) ||
      !matches(event.app_version, RELEASE) || !matches(event.build, RELEASE) || !matches(event.channel, TOKEN)) return false;

  if (kind.startsWith("engine_")) {
    if (!matches(event.engine, TOKEN)) return false;
    if (gameName !== undefined && (typeof gameName !== "string" || gameName === "." || gameName === ".." ||
        !GAME_NAME_LENGTH.test(gameName) || FORBIDDEN_GAME_NAME.test(gameName))) return false;
  }

  switch (kind) {
    case "app_start":
      return event.launch_count === 1;
    case "app_usage":
    case "engine_usage":
      return inRange(event.duration_ms, MAX_DURATION_MS) &&
        (event.fps == null || inRange(event.fps, 1_000)) &&
        (event.memory_peak_mb === undefined || inRange(event.memory_peak_mb, 1_048_576));
    case "engine_start":
      return typeof event.success === "boolean" && inRange(event.load_ms, MAX_DURATION_MS) &&
        (event.error_code === undefined || (event.success === false && matches(event.error_code, TOKEN)));
    case "engine_error":
      return matches(event.error_code, TOKEN);
    default:
      return false;
  }
}

const INVALID = Symbol("invalid telemetry");
const UTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const WHITESPACE = /[ \t\r\n]*/y;
const STRING = /"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4})){0,512}"/y;
const INTEGER = /-?(?:0|[1-9][0-9]{0,9})/y;

// The protocol has only three container levels and event fields are scalars.
// Parsing that shape directly preserves integer syntax and detects decoded duplicate keys.
class EnvelopeParser {
  private offset = 0;
  private readonly text: string;

  constructor(text: string) {
    this.text = text;
  }

  parse(): TelemetryEnvelope {
    this.expect("{");
    let version = false;
    let events: TelemetryEvent[] | undefined;
    do {
      const key = this.readString(64);
      this.expect(":");
      if (key === "schema_version" && !version && this.readInteger() === 1) {
        version = true;
      } else if (key === "events" && !events) {
        events = this.readEvents();
      } else {
        throw INVALID;
      }
    } while (this.take(","));
    this.expect("}");
    this.skipWhitespace();
    if (!version || !events || this.offset !== this.text.length) throw INVALID;
    return { schema_version: 1, events };
  }

  private readEvents(): TelemetryEvent[] {
    this.expect("[");
    const events: TelemetryEvent[] = [];
    do {
      if (events.length === MAX_EVENTS) throw INVALID;
      this.expect("{");
      const event: EventFields = {};
      let count = 0;
      do {
        if (++count > MAX_EVENT_FIELDS) throw INVALID;
        const key = this.readString(64);
        if (!EVENT_FIELDS.has(key) || Object.prototype.hasOwnProperty.call(event, key)) throw INVALID;
        this.expect(":");
        event[key] = this.readScalar();
      } while (this.take(","));
      this.expect("}");
      if (!isTelemetryEvent(event)) throw INVALID;
      events.push(event);
    } while (this.take(","));
    this.expect("]");
    return events;
  }

  private readScalar(): Scalar {
    this.skipWhitespace();
    switch (this.text[this.offset]) {
      case '"': return this.readString(512);
      case "t": return this.readLiteral("true", true);
      case "f": return this.readLiteral("false", false);
      case "n": return this.readLiteral("null", null);
      default: return this.readInteger();
    }
  }

  private readLiteral(literal: string, value: boolean | null): boolean | null {
    if (!this.text.startsWith(literal, this.offset)) throw INVALID;
    this.offset += literal.length;
    return value;
  }

  private readString(maxLength: number): string {
    this.skipWhitespace();
    const token = this.match(STRING);
    // JSON.parse is only used on bounded, lexed string tokens to decode escapes.
    const value: string = token.includes("\\") ? JSON.parse(token) : token.slice(1, -1);
    if (value.length > maxLength) throw INVALID;
    return value;
  }

  private readInteger(): number {
    this.skipWhitespace();
    // Any decimal, exponent, or leading-zero suffix fails the next delimiter check.
    const value = Number(this.match(INTEGER));
    if (value < -2_147_483_648 || value > 2_147_483_647) throw INVALID;
    return value === 0 ? 0 : value;
  }

  private match(pattern: RegExp): string {
    pattern.lastIndex = this.offset;
    const token = pattern.exec(this.text);
    if (!token) throw INVALID;
    this.offset = pattern.lastIndex;
    return token[0];
  }

  private skipWhitespace(): void {
    WHITESPACE.lastIndex = this.offset;
    WHITESPACE.test(this.text);
    this.offset = WHITESPACE.lastIndex;
  }

  private take(character: string): boolean {
    this.skipWhitespace();
    if (this.text[this.offset] !== character) return false;
    this.offset++;
    return true;
  }

  private expect(character: string): void {
    if (!this.take(character)) throw INVALID;
  }
}

export function validateEvents(body: Uint8Array): TelemetryEnvelope | null {
  if (body.byteLength > MAX_BODY_BYTES) return null;
  let text: string;
  try {
    // Keep any BOM in the decoded input so the parser rejects it.
    text = UTF8.decode(body);
  } catch {
    return null;
  }
  try {
    return new EnvelopeParser(text).parse();
  } catch (error) {
    if (error === INVALID) return null;
    throw error;
  }
}
