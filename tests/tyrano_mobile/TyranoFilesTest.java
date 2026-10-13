import org.aether.tyrano.TyranoFiles;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public final class TyranoFilesTest {
    private static final String ORIGIN = "https://test.tyrano.aether.invalid";
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private static String body(TyranoFiles.Response response) throws IOException {
        try (java.io.InputStream input = response.body) {
            return new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
    public static void main(String[] args) throws Exception {
        Path temp = Files.createTempDirectory("aether-tyrano-files-");
        try {
            Path game = Files.createDirectory(temp.resolve("game"));
            Path entry = game.resolve("index.html");
            String html = "<!DOCTYPE html><html><head><meta charset='utf-8'><script>engine()</script></head></html>";
            Files.writeString(entry, html);
            Files.writeString(game.resolve("中文.txt"), "abcdef");
            Files.writeString(temp.resolve("secret.txt"), "not a game resource");
            Files.createSymbolicLink(game.resolve("outside.txt"), temp.resolve("secret.txt"));
            TyranoFiles files = new TyranoFiles(entry.toString(), ORIGIN, "window.host='</script>';");
            TyranoFiles.Response response = files.read(ORIGIN + "/index.html", "GET", null);
            String injected = body(response);
            check(response.status == 200 && injected.startsWith("<!DOCTYPE html>"), "Injection preserves standards mode");
            check(injected.indexOf("window.host") < injected.indexOf("engine()"), "The host runs before the engine");
            check(injected.contains("<\\/script>"), "Injected script cannot close its own element");
            check(html.equals(Files.readString(entry)), "Game HTML remains unchanged");
            response = files.read(ORIGIN + "/%E4%B8%AD%E6%96%87.txt?v=1", "GET", "bytes=1-3");
            check(response.status == 206 && body(response).equals("bcd"), "UTF-8 paths, query strings and exact ranges");
            response = files.read(ORIGIN + "/中文.txt", "GET", "bytes=-2");
            check(response.status == 206 && body(response).equals("ef"), "Suffix byte ranges");
            response = files.read(ORIGIN + "/中文.txt", "GET", "bytes=2-");
            check(response.body.skip(100) == 4 && response.body.read() == -1, "Skipping cannot pass the range boundary");
            response.body.close();
            response = files.read(ORIGIN + "/中文.txt", "HEAD", null);
            check(response.status == 200 && response.headers.get("Content-Length").equals("6") && body(response).isEmpty(), "HEAD retains length without a body");
            for (String range : new String[]{"bytes=99-", "bytes=4-2", "bytes=-0", "bytes=0-1,3-4", "bytes=", "bytes=999999999999999999999-"}) {
                check(files.read(ORIGIN + "/中文.txt", "GET", range).status == 416, "Invalid range: " + range);
            }
            for (String relative : new String[]{"outside.txt", "../secret.txt", "%2e%2e/secret.txt", "%2e%2e%2fsecret.txt"}) {
                check(files.read(ORIGIN + "/" + relative, "GET", null).status == 403, "Resource root: " + relative);
            }
            check(files.read("https://remote.invalid/index.html", "GET", null).status == 403, "Remote resources are not exposed");
            check(files.read(ORIGIN + "/index.html", "POST", null).status == 405, "The game directory is read-only");
            check(files.read(ORIGIN + "/missing.txt", "GET", null).status == 404, "Missing files");
            System.out.println("TYRANO_ANDROID_FILES_OK");
        } finally {
            try (java.util.stream.Stream<Path> paths = Files.walk(temp)) {
                for (Path path : paths.sorted(java.util.Comparator.reverseOrder()).toArray(Path[]::new)) Files.delete(path);
            }
        }
    }
}
