package org.aether.tyrano;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.URLConnection;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Local HTTPS resources; no HTTP server, file:// access, or writable game files. */
public final class TyranoFiles {
    public static final class Response {
        public int status;
        public String mime = "application/octet-stream";
        public final Map<String, String> headers = new LinkedHashMap<>();
        public InputStream body = new ByteArrayInputStream(new byte[0]);
    }

    private final File root;
    private final File entry;
    private final String origin;
    private final String script;

    public TyranoFiles(String entryPath, String origin, String script) throws IOException {
        File requested = new File(entryPath);
        root = requested.getParentFile().getCanonicalFile();
        entry = requested.getCanonicalFile();
        if (!inside(entry) || !entry.isFile()) throw new IOException("The game entry is missing or outside its folder");
        this.origin = origin;
        this.script = script;
    }

    private boolean inside(File file) {
        return file.getPath().startsWith(root.getPath() + File.separator);
    }

    public Response read(String url, String method, String range) {
        Response response = new Response();
        response.status = 403;
        response.headers.put("Cache-Control", "no-store");
        response.headers.put("Access-Control-Allow-Origin", origin);
        response.headers.put("Accept-Ranges", "bytes");
        try {
            URI uri = URI.create(url);
            if (!url.startsWith(origin + "/")) return response;
            File file = new File(root, uri.getPath().replaceFirst("^/+", "")).getCanonicalFile();
            if (!inside(file)) return response;
            if (!method.equals("GET") && !method.equals("HEAD")) { response.status = 405; return response; }
            if (!file.isFile()) { response.status = 404; return response; }
            String extension = file.getName().replaceFirst("^.*\\.", "").toLowerCase(Locale.ROOT);
            String mime = URLConnection.guessContentTypeFromName(file.getName());
            if (mime != null) response.mime = mime;
            if (extension.equals("js")) response.mime = "application/javascript";
            if (extension.equals("ks") || extension.equals("tjs")) response.mime = "text/plain";
            if (extension.equals("css")) response.mime = "text/css";
            if (extension.equals("json")) response.mime = "application/json";
            if (extension.equals("woff2")) response.mime = "font/woff2";
            if (extension.equals("webp")) response.mime = "image/webp";
            if (extension.equals("mp4")) response.mime = "video/mp4";
            if (extension.equals("webm")) response.mime = "video/webm";
            if (extension.equals("ogg")) response.mime = "audio/ogg";
            if (extension.equals("m4a")) response.mime = "audio/mp4";
            if (extension.equals("wasm")) response.mime = "application/wasm";
            long total = file.length(), start = 0, end = total;
            byte[] html = null;
            if (file.equals(entry)) {
                if (total > 16 * 1024 * 1024) throw new IOException("Game index.html is too large");
                String text = new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
                Matcher firstScript = Pattern.compile("<script\\b", Pattern.CASE_INSENSITIVE).matcher(text);
                int at = firstScript.find() ? firstScript.start() : text.length();
                // Inject before any game script while preserving its doctype/charset.
                String injection = "<script>" + script.replaceAll("(?i)</script", "<\\\\/script") + "</script>";
                html = (text.substring(0, at) + injection + text.substring(at)).getBytes(StandardCharsets.UTF_8);
                total = end = html.length;
                response.mime = "text/html";
            }
            response.status = 200;
            if (range != null) {
                Matcher match = Pattern.compile("bytes=(\\d*)-(\\d*)").matcher(range);
                if (!match.matches() || match.group(1).isEmpty() && match.group(2).isEmpty()) response.status = 416;
                else {
                    boolean first = !match.group(1).isEmpty(), last = !match.group(2).isEmpty();
                    long a = first ? Long.parseLong(match.group(1)) : 0;
                    long b = last ? Long.parseLong(match.group(2)) : Long.MAX_VALUE;
                    start = first ? a : Math.max(0, total - b);
                    end = first && b < Long.MAX_VALUE ? Math.min(total, b + 1) : total;
                    response.status = start < end && start < total ? 206 : 416;
                }
            }
            if (response.status == 416) {
                response.headers.put("Content-Range", "bytes */" + total);
                return response;
            }
            if (response.status == 206) response.headers.put("Content-Range", "bytes " + start + "-" + (end - 1) + "/" + total);
            response.headers.put("Content-Length", Long.toString(end - start));
            if (method.equals("HEAD")) return response;
            if (html != null) response.body = new ByteArrayInputStream(html, (int)start, (int)(end - start));
            else {
                FileInputStream input = new FileInputStream(file);
                try { input.getChannel().position(start); }
                catch (IOException error) { input.close(); throw error; }
                final long length = end - start;
                response.body = new FilterInputStream(input) {
                    private long remaining = length;
                    @Override public int read() throws IOException {
                        if (remaining == 0) return -1;
                        int value = super.read(); if (value >= 0) remaining--; return value;
                    }
                    @Override public int read(byte[] buffer, int offset, int count) throws IOException {
                        if (count == 0) return 0;
                        if (remaining == 0) return -1;
                        int read = in.read(buffer, offset, (int)Math.min(remaining, count));
                        if (read > 0) remaining -= read;
                        return read;
                    }
                    @Override public long skip(long count) throws IOException {
                        long skipped = in.skip(Math.max(0, Math.min(count, remaining)));
                        remaining -= skipped;
                        return skipped;
                    }
                    @Override public int available() throws IOException {
                        return (int)Math.min(remaining, in.available());
                    }
                };
            }
        } catch (NumberFormatException error) {
            response.status = 416;
        } catch (IOException | IllegalArgumentException error) {
            response.status = 404;
        }
        return response;
    }
}
