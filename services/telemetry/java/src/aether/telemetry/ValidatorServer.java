package aether.telemetry;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.regex.Pattern;

public final class ValidatorServer {
    private static final String VALIDATE_PATH = "/internal/v1/validate";
    private static final Pattern SECRET = Pattern.compile("[A-Za-z0-9_-]{32,128}");
    private static final Pattern JSON_CONTENT_TYPE = Pattern.compile("application/json(?:\\s*;\\s*charset\\s*=\\s*(?:utf-8|\"utf-8\"))?", Pattern.CASE_INSENSITIVE);
    private static final byte[] EMPTY = new byte[0];
    private final Semaphore inFlight = new Semaphore(64);
    private final byte[] expectedAuthorization;

    private ValidatorServer(String secret) {
        expectedAuthorization = ascii("Bearer " + secret);
    }

    public static void main(String[] args) throws IOException {
        Map<String, String> env = System.getenv();
        String secret = env.getOrDefault("TELEMETRY_ORIGIN_SECRET", "");
        if (!SECRET.matcher(secret).matches()) {
            throw new IllegalArgumentException("Set TELEMETRY_ORIGIN_SECRET to a 32-128 character base64url token");
        }

        // The JDK server otherwise permits request/response I/O to hang indefinitely.
        System.setProperty("sun.net.httpserver.maxReqTime", "10");
        System.setProperty("sun.net.httpserver.maxRspTime", "10");
        System.setProperty("sun.net.httpserver.idleInterval", "15");
        System.setProperty("jdk.httpserver.maxConnections", "256");
        HttpServer server = HttpServer.create(new InetSocketAddress(
                env.getOrDefault("TELEMETRY_BIND", "127.0.0.1"),
                Integer.parseInt(env.getOrDefault("TELEMETRY_PORT", "8080"))), 64);
        var executor = Executors.newVirtualThreadPerTaskExecutor();
        server.setExecutor(executor);
        server.createContext("/", new ValidatorServer(secret)::handle);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            server.stop(2);
            executor.shutdownNow();
        }));
        server.start();
    }

    private void handle(HttpExchange exchange) throws IOException {
        try (exchange) {
            String path = exchange.getRequestURI().getRawPath();
            if (exchange.getRequestURI().getRawQuery() != null) {
                reply(exchange, 404, EMPTY);
            } else if ("/health".equals(path) && "GET".equals(exchange.getRequestMethod())) {
                reply(exchange, 204, EMPTY);
            } else if (!VALIDATE_PATH.equals(path)) {
                reply(exchange, 404, EMPTY);
            } else if (!"POST".equals(exchange.getRequestMethod())) {
                exchange.getResponseHeaders().set("Allow", "POST");
                reply(exchange, 405, EMPTY);
            } else if (!authorized(exchange)) {
                reply(exchange, 401, EMPTY);
            } else if (!inFlight.tryAcquire()) {
                reply(exchange, 503, EMPTY);
            } else {
                try {
                    validate(exchange);
                } finally {
                    inFlight.release();
                }
            }
        }
    }

    private boolean authorized(HttpExchange exchange) {
        List<String> values = exchange.getRequestHeaders().get("Authorization");
        return values != null && values.size() == 1 && values.getFirst().length() <= 135 &&
                MessageDigest.isEqual(expectedAuthorization, ascii(values.getFirst()));
    }

    private static void validate(HttpExchange exchange) throws IOException {
        var headers = exchange.getRequestHeaders();
        List<String> types = headers.get("Content-Type");
        if (types == null || types.size() != 1 || !JSON_CONTENT_TYPE.matcher(types.getFirst()).matches() ||
                headers.containsKey("Content-Encoding")) {
            reply(exchange, 415, EMPTY);
            return;
        }

        byte[] input = exchange.getRequestBody().readNBytes(Events.MAX_BODY_BYTES + 1);
        if (input.length > Events.MAX_BODY_BYTES) {
            reply(exchange, 413, EMPTY);
            return;
        }
        byte[] output;
        try {
            output = Events.validate(input);
        } catch (Events.InvalidEvent | IOException invalid) {
            reply(exchange, 400, EMPTY);
            return;
        }
        reply(exchange, 200, output);
    }

    private static void reply(HttpExchange exchange, int status, byte[] body) throws IOException {
        exchange.getResponseHeaders().set("Cache-Control", "no-store");
        if (body.length != 0) {
            exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
            exchange.sendResponseHeaders(status, body.length);
            exchange.getResponseBody().write(body);
        } else {
            exchange.sendResponseHeaders(status, -1);
        }
    }

    private static byte[] ascii(String text) {
        return text.getBytes(StandardCharsets.US_ASCII);
    }

}
