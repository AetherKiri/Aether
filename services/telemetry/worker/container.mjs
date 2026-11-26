import { DurableObject } from "cloudflare:workers";
import worker from "./index.mjs";
import { VALIDATOR_PATH } from "./protocol.mjs";

const PORT = 8080;
const IDLE_MS = 120_000;

export class TelemetryValidator extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    if (ctx.container?.running) {
      this.observeExit();
      void ctx.blockConcurrencyWhile(() => ctx.container.setInactivityTimeout(IDLE_MS));
    }
  }

  async fetch(request) {
    if (request.method !== "POST" || new URL(request.url).pathname !== VALIDATOR_PATH) {
      return new Response(null, { status: 404 });
    }
    try {
      this.starting ??= this.startAndWait().finally(() => { this.starting = undefined; });
      await this.starting;
      return await this.ctx.container.getTcpPort(PORT).fetch(request);
    } catch {
      return new Response(null, { status: 503 });
    }
  }

  async startAndWait() {
    const container = this.ctx.container;
    if (!container.running) {
      container.start({
        image: container.images.base,
        instance: "lite",
        enableInternet: false,
        env: {
          TELEMETRY_BIND: "0.0.0.0",
          TELEMETRY_ORIGIN_SECRET: this.env.TELEMETRY_ORIGIN_SECRET,
        },
      });
    }
    this.observeExit();
    await container.setInactivityTimeout(IDLE_MS);

    const port = container.getTcpPort(PORT);
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      try {
        const response = await port.fetch("http://container/health", { signal: AbortSignal.timeout(1_000) });
        await response.body?.cancel();
        if (response.status === 204) return;
      } catch {
        // Readiness probes may fail until Java is listening.
      }
      await scheduler.wait(200);
    }
    throw new Error("Validator failed readiness check");
  }

  observeExit() {
    this.monitoring ??= this.ctx.container.monitor()
      .catch(() => {})
      .finally(() => { this.monitoring = undefined; });
    this.ctx.waitUntil(this.monitoring);
  }
}

export default worker;
