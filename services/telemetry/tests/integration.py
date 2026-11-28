#!/usr/bin/env python3
"""Exercise the local TypeScript Worker and emulated D1 as one service."""

import contextlib
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
WRANGLER = os.environ.get("WRANGLER", "wrangler")
DAY_MS = 86_400_000
INSTALL_ID = "041f2997-0dc3-4030-881c-6df7203e8c20"


def run(*args, env=None):
    return subprocess.run(args, cwd=ROOT, env=env, check=True, text=True, stdout=subprocess.PIPE).stdout


@contextlib.contextmanager
def server(args, env):
    with tempfile.TemporaryFile(mode="w+t") as output:
        process = subprocess.Popen(args, cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=output, stderr=output)
        try:
            yield process
        except Exception:
            output.seek(0)
            print(output.read(), end="", flush=True)
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def local_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request(port, method, path, body=None, headers=None, *, chunked=False):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=4)
    try:
        connection.request(method, path, body, headers or {}, encode_chunked=chunked)
        response = connection.getresponse()
        return response.status, {key.lower(): value for key, value in response.getheaders()}, response.read()
    finally:
        connection.close()


def ready(process, port, path, status):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and process.poll() is None:
        try:
            if request(port, "GET", path)[0] == status:
                return
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.1)
    raise AssertionError(f"Local service at port {port} failed readiness check")


def event(kind, **fields):
    return dict(event_id=str(uuid.uuid4()), install_id=INSTALL_ID, kind=kind, os="Linux", arch="x86_64",
                ram_bucket="8_15_gb", gpu_family="intel", app_version="1.2.3-beta.2", build="4c8f2ea",
                channel="development", **fields)


def body(*events):
    return json.dumps({"schema_version": 1, "events": events}, ensure_ascii=False, separators=(",", ":")).encode()


def run_cases(edge_port, sql, report):
    json_headers = {"Content-Type": "application/json; charset=UTF-8"}
    path = "/v1/events"
    start = event("app_start", launch_count=1)
    app_usage = event("app_usage", duration_ms=500, fps=None)
    engine_start = event("engine_start", engine="kirikiri", success=True, load_ms=1, game_name="星空 ★ 🌙")
    failure = event("engine_start", engine="kirikiri", success=False, load_ms=0, error_code="entry_missing")
    engine_usage = event("engine_usage", engine="kirikiri", duration_ms=100, fps=59, memory_peak_mb=527)
    engine_error = event("engine_error", engine="kirikiri", error_code="tick_neg_10")

    def post(payload, status, headers=None):
        result = request(edge_port, "POST", path, payload, json_headers if headers is None else headers)
        assert result[0] == status, (status, result)
        assert result[1]["access-control-allow-origin"] == "*"
        assert "access-control-allow-credentials" not in result[1]
        if status == 204:
            assert result[2] == b""
        return result

    assert request(edge_port, "POST", path + "?extra=1", body(start), json_headers)[0] == 404
    assert request(edge_port, "POST", "/internal/v1/validate", body(start), json_headers)[0] == 404
    assert request(edge_port, "GET", path)[0] == 405
    preflight = {"Origin": "https://test.example", "Access-Control-Request-Method": "POST",
                 "Access-Control-Request-Headers": "content-type"}
    status, headers, _ = request(edge_port, "OPTIONS", path, headers=preflight)
    assert status == 204 and headers["access-control-allow-origin"] == "*"
    assert headers["access-control-allow-headers"] == "Content-Type"
    assert request(edge_port, "OPTIONS", path, headers={**preflight, "Access-Control-Request-Headers": "authorization"})[0] == 400

    post(body(start), 415, {"Content-Type": "text/plain"})
    post(body(start), 415, {**json_headers, "Content-Encoding": "gzip"})
    post(b" " * 65_537, 413)
    chunks = [b" " * 16_384] * 4 + [b" "]
    assert request(edge_port, "POST", path, iter(chunks), json_headers, chunked=True)[0] == 413

    malformed = [
        b"{", b"[]", b"{}", b'{"schema_version":1,"events":[]}', b"\xef\xbb\xbf" + body(start),
        b'{"schema_version":2,"events":[{}]}', b'{"schema_version":1.0,"events":[{}]}',
        b'{"schema_version":1,"schema_version":1,"events":[{}]}',
        b'{"schema_version":1,"events":[{"kind":"app_start","k\\u0069nd":"app_usage"}]}',
        body(start) + b" {}", body(start).replace(b"Linux", b"Linu\xff"),
        body(start).replace(b'"Linux"', b'"\\ud800"'),
        body({**start, "event_id": "041F2997-0DC3-4030-881C-6DF7203E8C20"}),
        body({**start, "event_id": "041f2997-0dc3-1030-881c-6df7203e8c20"}),
        body({**start, "install_id": "041f2997-0dc3-4030-081c-6df7203e8c20"}),
        body({**start, "engine": "kirikiri"}), body({**start, "ip": "192.0.2.1"}),
        body({**start, "gpu_family": "GeForce RTX"}), body({**start, "os": "Ubuntu"}),
        body({**start, "launch_count": 2}), body({**start, "launch_count": True}),
        body({key: value for key, value in start.items() if key != "install_id"}),
        body({**app_usage, "duration_ms": -1}), body({**app_usage, "fps": 59.5}),
        body({**engine_usage, "memory_peak_mb": None}), body({**engine_usage, "duration_ms": 10**12}),
        body({**engine_start, "success": 1}), body({**engine_start, "error_code": "open_failed"}),
        body({**engine_start, "game_name": "C:\\Users\\private"}),
        body({**engine_start, "game_name": "file:///private"}), body({**engine_start, "game_name": "A\u200bZ"}),
        body({**engine_start, "game_name": " " + "x" * 120}), body({**engine_start, "game_name": "x" * 121}),
        body({**engine_start, "game_name": "x\x00"}), body({**engine_error, "error_code": "Couldn't open file"}),
        body(*([start] * 26)), body(start, {**engine_error, "error_code": None}),
    ]
    for index, payload in enumerate(malformed):
        try:
            post(payload, 400)
        except AssertionError as error:
            raise AssertionError(f"Malformed case {index}: {error}") from error
    assert sql("SELECT COUNT(*) AS total FROM telemetry_events")[0]["total"] == 0

    sent_after = int(time.time() * 1_000)
    post(body(start, app_usage, engine_start, failure, engine_usage, engine_error, start), 204,
         {**json_headers, "Origin": "https://test.example", "Authorization": "Bearer client-supplied"})
    rows = sql("SELECT * FROM telemetry_events")
    assert len(rows) == 6
    saved = {row["event_id"]: row for row in rows}
    assert saved[start["event_id"]]["received_at_ms"] >= sent_after
    assert saved[app_usage["event_id"]]["fps"] is None
    assert saved[engine_start["event_id"]]["game_name"] == engine_start["game_name"]
    assert saved[failure["event_id"]]["success"] == 0
    assert saved[failure["event_id"]]["error_code"] == "entry_missing"
    assert saved[engine_usage["event_id"]]["fps"] == 59
    assert saved[engine_usage["event_id"]]["memory_peak_mb"] == 527
    assert saved[engine_error["event_id"]]["game_name"] is None

    post(body({**start, "channel": "changed"}), 204)
    assert {row["event_id"]: row for row in sql("SELECT * FROM telemetry_events")} == saved

    usage, = report("daily_usage")
    assert (usage["reporting_installs"], usage["installs_reporting_launches"], usage["launches"]) == (1, 1, 1)
    assert (usage["app_duration_ms"], usage["engine_duration_ms"]) == (500, 100)
    startups = {row["game_name"]: row for row in report("engine_startup")}
    assert startups[engine_start["game_name"]]["success_percent"] == 100
    assert startups[None]["success_percent"] == 0
    performance = {row["kind"]: row for row in report("performance")}
    assert performance["app_usage"]["duration_weighted_fps"] is None
    assert performance["engine_usage"]["duration_weighted_fps"] == 59
    assert performance["engine_usage"]["peak_memory_mb"] == 527
    errors = {row["error_code"]: row for row in report("engine_errors")}
    assert (errors["entry_missing"]["failed_starts"], errors["entry_missing"]["reported_errors"]) == (1, 0)
    assert (errors["tick_neg_10"]["failed_starts"], errors["tick_neg_10"]["reported_errors"]) == (0, 1)

    # A database error on the second statement must roll back the earlier insert.
    sql("""CREATE TRIGGER test_reject BEFORE INSERT ON telemetry_events
           WHEN NEW.channel = 'forced_failure' BEGIN SELECT RAISE(ABORT, 'test rejection'); END""")
    post(body(event("app_start", launch_count=1),
              {**event("app_start", launch_count=1), "channel": "forced_failure"}), 503)
    assert {row["event_id"]: row for row in sql("SELECT * FROM telemetry_events")} == saved
    sql("DROP TRIGGER test_reject")

    old = int(time.time() * 1_000) - 91 * DAY_MS
    sql(f"UPDATE telemetry_events SET received_at_ms = {old} WHERE event_id = '{start['event_id']}'")
    assert request(edge_port, "GET", "/__scheduled")[0] == 200
    assert {row["event_id"] for row in sql("SELECT event_id FROM telemetry_events")} == set(saved) - {start["event_id"]}

    sql("DROP TABLE telemetry_events")
    post(body(start), 503)


def main():
    with tempfile.TemporaryDirectory(prefix="aether-telemetry-test-") as scratch:
        env = {**os.environ, "WRANGLER_SEND_METRICS": "false", "WRANGLER_LOG_PATH": f"{scratch}/wrangler.log"}
        edge_port = local_port()
        cfg = ("--config", "wrangler.local.toml")
        db = ("TELEMETRY_DB", *cfg, "--local", "--persist-to", f"{scratch}/d1")
        run(WRANGLER, "d1", "migrations", "apply", *db, env=env)

        def execute(*options):
            result, = json.loads(run(WRANGLER, "d1", "execute", *db, "--json", *options, env=env))
            assert result["success"], result
            return result["results"]

        def sql(query):
            return execute("--command", query)

        def report(name):
            return execute("--file", f"queries/{name}.sql")

        args = (WRANGLER, "dev", *cfg, "--local", "--persist-to", f"{scratch}/d1",
                "--ip", "127.0.0.1", "--port", str(edge_port), "--test-scheduled", "--log-level", "error")
        with server(args, env) as edge:
            ready(edge, edge_port, "/v1/events", 405)
            run_cases(edge_port, sql, report)
    print("Telemetry integration passed (TypeScript Worker, D1 idempotency, 90-day pruning, and storage failure).")


if __name__ == "__main__":
    main()
