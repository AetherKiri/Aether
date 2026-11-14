package org.aether.mobile;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import androidx.core.content.FileProvider;
import org.json.JSONObject;
import java.io.File;
import java.nio.file.Files;
import java.util.UUID;

/** Share only an exported copy with a temporary, read-only content URI. */
public final class SaveShare {
    private static boolean busy;
    private static String result = "";
    private SaveShare() {}

    private static synchronized void finish(String status, String error) {
        JSONObject payload = new JSONObject();
        try { payload.put("status", status); payload.put("error", error); }
        catch (Exception ignored) {}
        result = payload.toString();
        busy = false;
    }

    public static synchronized String takeResultJSON() {
        String value = result;
        result = "";
        return value;
    }

    public static synchronized boolean share(Activity activity, String path, String title) {
        if (busy || activity == null || activity.isFinishing()) return false;
        busy = true;
        result = "";
        new Thread(() -> {
            try {
                File root = new File(activity.getCacheDir(), "aether-save-share");
                if (!root.isDirectory() && !root.mkdirs()) throw new java.io.IOException("Cannot prepare shared saves");
                // A receiving app may still be reading an older export.
                File[] previous = root.listFiles();
                if (previous != null) for (File file : previous) {
                    if (file.isFile() && file.lastModified() < System.currentTimeMillis() - 86400000L) file.delete();
                }
                File source = new File(path);
                File shared = new File(root, UUID.randomUUID() + "-" + source.getName());
                Files.copy(source.toPath(), shared.toPath());
                activity.runOnUiThread(() -> {
                    try {
                        if (activity.isFinishing() || activity.isDestroyed()) throw new IllegalStateException("Sharing window is unavailable");
                        Uri uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".aether.saves", shared);
                        Intent send = new Intent(Intent.ACTION_SEND).setType("application/zip")
                            .putExtra(Intent.EXTRA_STREAM, uri).putExtra(Intent.EXTRA_SUBJECT, title)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                        send.setClipData(ClipData.newRawUri(title, uri));
                        activity.startActivity(Intent.createChooser(send, title));
                        finish("presented", "");
                    } catch (Exception error) { finish("error", error.toString()); }
                });
            } catch (Exception error) { finish("error", error.toString()); }
        }, "AetherSaveShare").start();
        return true;
    }
}
