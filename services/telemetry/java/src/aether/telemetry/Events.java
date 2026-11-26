package aether.telemetry;

import com.fasterxml.jackson.core.JsonEncoding;
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonGenerator;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import com.fasterxml.jackson.core.StreamReadConstraints;
import com.fasterxml.jackson.core.StreamReadFeature;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

final class Events {
    static final int MAX_BODY_BYTES = 65_536;
    static final int MAX_EVENTS = 25;
    private static final int MAX_DURATION = 86_400_000;
    private static final Pattern UUID_V4 = Pattern.compile("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");
    private static final Pattern RELEASE = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._+-]{0,63}");
    private static final Pattern TOKEN = Pattern.compile("[a-z0-9][a-z0-9_-]{0,39}");
    private static final Set<String> OS = Set.of("Windows", "macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD", "Android", "iOS", "Web", "Unknown");
    private static final Set<String> ARCH = Set.of("x86_64", "x86_32", "arm64", "arm32", "riscv64", "riscv32", "wasm64", "wasm32", "unknown");
    private static final Set<String> RAM = Set.of("lt_4_gb", "4_7_gb", "8_15_gb", "16_31_gb", "32_63_gb", "gte_64_gb", "unknown");
    private static final Set<String> GPU = Set.of(
            "geforce_rtx", "geforce_gtx", "nvidia_rtx", "nvidia", "radeon_rx", "amd",
            "intel_arc", "intel_iris", "intel_uhd", "intel", "apple", "adreno", "mali", "powervr", "software", "unknown");
    private static final Set<String> COMMON = Set.of("event_id", "install_id", "kind", "os", "arch", "ram_bucket", "gpu_family", "app_version", "build", "channel");
    private static final Map<String, Set<String>> KIND_FIELDS = Map.of(
            "app_start", Set.of("launch_count"),
            "app_usage", Set.of("duration_ms", "fps", "memory_peak_mb"),
            "engine_start", Set.of("engine", "game_name", "success", "load_ms", "error_code"),
            "engine_usage", Set.of("engine", "game_name", "duration_ms", "fps", "memory_peak_mb"),
            "engine_error", Set.of("engine", "game_name", "error_code"));
    private static final JsonFactory JSON = JsonFactory.builder()
            .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
            .disable(JsonFactory.Feature.INTERN_FIELD_NAMES)
            .disable(JsonFactory.Feature.CANONICALIZE_FIELD_NAMES)
            .streamReadConstraints(StreamReadConstraints.builder()
                    .maxNestingDepth(3).maxStringLength(512).maxNameLength(64).maxNumberLength(16).build())
            .build();

    static byte[] validate(byte[] input) throws IOException, InvalidEvent {
        String json = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(input)).toString();
        List<Map<String, Object>> events = null;
        boolean version = false;
        try (JsonParser parser = JSON.createParser(json)) {
            require(parser.nextToken() == JsonToken.START_OBJECT);
            while (parser.nextToken() == JsonToken.FIELD_NAME) {
                String field = parser.currentName();
                parser.nextToken();
                switch (field) {
                    case "schema_version" -> {
                        require(parser.currentToken() == JsonToken.VALUE_NUMBER_INT && parser.getIntValue() == 1);
                        version = true;
                    }
                    case "events" -> events = readEvents(parser);
                    default -> throw new InvalidEvent();
                }
            }
            require(parser.currentToken() == JsonToken.END_OBJECT && parser.nextToken() == null);
            require(version && events != null);
        }
        return serialize(events);
    }

    private static List<Map<String, Object>> readEvents(JsonParser parser) throws IOException, InvalidEvent {
        require(parser.currentToken() == JsonToken.START_ARRAY);
        List<Map<String, Object>> events = new ArrayList<>();
        while (parser.nextToken() == JsonToken.START_OBJECT) {
            require(events.size() < MAX_EVENTS);
            Map<String, Object> event = new HashMap<>();
            while (parser.nextToken() == JsonToken.FIELD_NAME) {
                require(event.size() < 15);
                String key = parser.currentName();
                JsonToken token = parser.nextToken();
                require(token != null);
                Object value = switch (token) {
                    case VALUE_STRING -> parser.getText();
                    case VALUE_NUMBER_INT -> parser.getIntValue();
                    case VALUE_TRUE -> true;
                    case VALUE_FALSE -> false;
                    case VALUE_NULL -> null;
                    default -> throw new InvalidEvent();
                };
                event.put(key, value);
            }
            require(parser.currentToken() == JsonToken.END_OBJECT);
            validateEvent(event);
            events.add(event);
        }
        require(parser.currentToken() == JsonToken.END_ARRAY && !events.isEmpty());
        return events;
    }

    private static void validateEvent(Map<String, Object> event) throws InvalidEvent {
        String kind = string(event, "kind");
        Set<String> fields = KIND_FIELDS.get(kind);
        require(fields != null && event.keySet().stream().allMatch(key -> COMMON.contains(key) || fields.contains(key)));
        pattern(event, "event_id", UUID_V4);
        pattern(event, "install_id", UUID_V4);
        require(OS.contains(string(event, "os")));
        require(ARCH.contains(string(event, "arch")));
        require(RAM.contains(string(event, "ram_bucket")));
        require(GPU.contains(string(event, "gpu_family")));
        pattern(event, "app_version", RELEASE);
        pattern(event, "build", RELEASE);
        pattern(event, "channel", TOKEN);

        if (kind.startsWith("engine_")) {
            pattern(event, "engine", TOKEN);
            if (event.containsKey("game_name")) validateGameName(string(event, "game_name"));
        }
        switch (kind) {
            case "app_start" -> integer(event, "launch_count", 1, 1);
            case "app_usage", "engine_usage" -> {
                integer(event, "duration_ms", 0, MAX_DURATION);
                if (event.get("fps") != null) integer(event, "fps", 0, 1_000);
                if (event.containsKey("memory_peak_mb")) integer(event, "memory_peak_mb", 0, 1_048_576);
            }
            case "engine_start" -> {
                require(event.get("success") instanceof Boolean);
                integer(event, "load_ms", 0, MAX_DURATION);
                if (event.containsKey("error_code")) {
                    require(Boolean.FALSE.equals(event.get("success")));
                    pattern(event, "error_code", TOKEN);
                }
            }
            case "engine_error" -> pattern(event, "error_code", TOKEN);
            default -> throw new InvalidEvent();
        }
    }

    private static void validateGameName(String name) throws InvalidEvent {
        require(!name.isEmpty() && name.codePointCount(0, name.length()) <= 120);
        require(!space(name.codePointAt(0)) && !space(name.codePointBefore(name.length())));
        require(!name.equals(".") && !name.equals("..") && name.codePoints().allMatch(cp -> switch (Character.getType(cp)) {
            case Character.CONTROL, Character.FORMAT, Character.SURROGATE,
                 Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> false;
            default -> cp != '/' && cp != '\\' && cp != ':';
        }));
    }

    private static boolean space(int codePoint) {
        return Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint);
    }

    private static String string(Map<String, Object> event, String key) throws InvalidEvent {
        if (event.get(key) instanceof String text) return text;
        throw new InvalidEvent();
    }

    private static void pattern(Map<String, Object> event, String key, Pattern pattern) throws InvalidEvent {
        require(pattern.matcher(string(event, key)).matches());
    }

    private static void integer(Map<String, Object> event, String key, int min, int max) throws InvalidEvent {
        require(event.get(key) instanceof Integer number && number >= min && number <= max);
    }

    private static void require(boolean valid) throws InvalidEvent {
        if (!valid) throw new InvalidEvent();
    }

    private static byte[] serialize(List<Map<String, Object>> events) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (JsonGenerator writer = JSON.createGenerator(output, JsonEncoding.UTF8)) {
            writer.writeStartObject();
            writer.writeNumberField("schema_version", 1);
            writer.writeArrayFieldStart("events");
            for (var event : events) {
                writer.writeStartObject();
                for (var field : event.entrySet()) {
                    String key = field.getKey();
                    switch (field.getValue()) {
                        case String value -> writer.writeStringField(key, value);
                        case Integer value -> writer.writeNumberField(key, value);
                        case Boolean value -> writer.writeBooleanField(key, value);
                        case null -> writer.writeNullField(key);
                        default -> throw new IllegalStateException();
                    }
                }
                writer.writeEndObject();
            }
            writer.writeEndArray();
            writer.writeEndObject();
        }
        return output.toByteArray();
    }

    static final class InvalidEvent extends Exception {}

    private Events() {}
}
