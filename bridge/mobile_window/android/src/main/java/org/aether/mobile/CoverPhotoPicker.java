package org.aether.mobile;

import android.app.Activity;
import android.content.ContentResolver;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ImageDecoder;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.net.Uri;
import android.os.Build;
import androidx.activity.ComponentActivity;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.PickVisualMediaRequest;
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.IOException;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;

/** Imports only the selected image; the app never requests access to the whole album. */
public final class CoverPhotoPicker {
    private static final AtomicBoolean busy = new AtomicBoolean();
    private static String result = "";
    private CoverPhotoPicker() {}

    public static boolean open(Activity activity, String destination) {
        if (!(activity instanceof ComponentActivity) || destination.isEmpty()
                || !busy.compareAndSet(false, true)) return false;
        synchronized (CoverPhotoPicker.class) { result = ""; }
        activity.runOnUiThread(() -> {
            final AtomicReference<ActivityResultLauncher<PickVisualMediaRequest>> launcher = new AtomicReference<>();
            try {
                if (activity.isFinishing() || activity.isDestroyed()) {
                    complete("cancelled", "", "");
                    return;
                }
                ComponentActivity owner = (ComponentActivity) activity;
                launcher.set(owner.getActivityResultRegistry().register(
                    "aether-cover-" + UUID.randomUUID(), new PickVisualMedia(), uri -> {
                        if (launcher.get() != null) launcher.get().unregister();
                        if (uri == null) { complete("cancelled", "", ""); return; }
                        ContentResolver resolver = activity.getApplicationContext().getContentResolver();
                        new Thread(() -> importPhoto(resolver, uri, destination), "aether-cover-import").start();
                    }));
                launcher.get().launch(new PickVisualMediaRequest.Builder()
                    .setMediaType(PickVisualMedia.ImageOnly.INSTANCE).build());
            } catch (RuntimeException error) {
                if (launcher.get() != null) launcher.get().unregister();
                complete("error", "", error.toString());
            }
        });
        return true;
    }

    public static synchronized String takeResultJSON() {
        String value = result;
        result = "";
        return value;
    }

    private static synchronized void complete(String status, String path, String error) {
        try {
            JSONObject payload = new JSONObject();
            payload.put("status", status);
            payload.put("path", path);
            payload.put("error", error);
            result = payload.toString();
        } catch (Exception failure) {
            result = "{\"status\":\"error\",\"error\":\"Photo import failed\"}";
        }
        busy.set(false);
    }

    private static void importPhoto(ContentResolver resolver, Uri uri, String destination) {
        File target = null;
        Bitmap bitmap = null;
        try {
            if (Build.VERSION.SDK_INT >= 28) {
                bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri), (decoder, info, source) -> {
                    int width = info.getSize().getWidth(), height = info.getSize().getHeight();
                    double ratio = Math.min(1.0, 4096.0 / Math.max(width, height));
                    decoder.setTargetSize(Math.max(1, (int)(width * ratio)), Math.max(1, (int)(height * ratio)));
                    decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
                });
            } else {
                BitmapFactory.Options options = new BitmapFactory.Options();
                options.inJustDecodeBounds = true;
                try (InputStream stream = resolver.openInputStream(uri)) { BitmapFactory.decodeStream(stream, null, options); }
                if (options.outWidth <= 0 || options.outHeight <= 0) throw new IOException("Cannot decode photo");
                options.inSampleSize = 1;
                while (Math.max(options.outWidth, options.outHeight) / options.inSampleSize > 4096) options.inSampleSize *= 2;
                options.inJustDecodeBounds = false;
                try (InputStream stream = resolver.openInputStream(uri)) { bitmap = BitmapFactory.decodeStream(stream, null, options); }
                try (InputStream stream = resolver.openInputStream(uri)) {
                    int orientation = new ExifInterface(stream).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1);
                    Matrix matrix = new Matrix();
                    switch (orientation) {
                        case 2: matrix.setScale(-1, 1); break;
                        case 3: matrix.setRotate(180); break;
                        case 4: matrix.setScale(1, -1); break;
                        case 5: matrix.setRotate(90); matrix.postScale(-1, 1); break;
                        case 6: matrix.setRotate(90); break;
                        case 7: matrix.setRotate(-90); matrix.postScale(-1, 1); break;
                        case 8: matrix.setRotate(-90); break;
                    }
                    if (bitmap != null && !matrix.isIdentity()) {
                        Bitmap rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true);
                        if (rotated != bitmap) bitmap.recycle();
                        bitmap = rotated;
                    }
                } catch (IOException ignored) { /* Some image formats have no EXIF. */ }
            }
            if (bitmap == null) throw new IOException("Cannot decode photo");
            File directory = new File(destination);
            if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create cover directory");
            target = new File(directory, "cover-" + UUID.randomUUID() + ".png");
            try (FileOutputStream stream = new FileOutputStream(target)) {
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) throw new IOException("Cannot encode cover");
            }
            complete("selected", target.getAbsolutePath(), "");
        } catch (Exception | OutOfMemoryError error) {
            if (target != null) target.delete();
            complete("error", "", error.toString());
        } finally {
            if (bitmap != null) bitmap.recycle();
        }
    }
}
