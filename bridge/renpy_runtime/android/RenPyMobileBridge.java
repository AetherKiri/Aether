package org.github.krkr2.aetherkiri;

import android.app.Activity;
import android.content.Context;
import android.content.res.AssetManager;

import org.libsdl.app.SDLActivity;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * Host-owned handoff point for the staged Ren'Py Android support package.
 *
 * The Godot Activity remains the only Activity. The provider binds that host,
 * extracts the private Python runtime and initializes SDL's JNI callbacks.
 * The native fork renders into an offscreen EGL pbuffer.
 */
public final class RenPyMobileBridge {
    private static boolean nativeBridgeLoaded;

    static {
        nativeBridgeLoaded = tryLoadNativeBridge();
    }

    private RenPyMobileBridge() {
    }

    /** Bind the already-running Godot Activity; never constructs an Activity. */
    public static void bindHostActivity(Activity activity) {
        if (activity == null) {
            throw new IllegalArgumentException("host Activity must not be null");
        }
        ensureNativeBridge();
        SDLActivity.bindHostActivity(activity);
        nativeSetHostActivity(activity);
    }

    /** Clear the host Activity during destruction/configuration teardown. */
    public static void clearHostActivity() {
        if (nativeBridgeLoaded || tryLoadNativeBridge()) {
            nativeSetHostActivity(null);
        }
        SDLActivity.clearHostActivity();
    }

    /** Load/retry through Java so JNI_OnLoad records the real host JavaVM. */
    public static boolean isNativeBridgeLoaded() {
        return nativeBridgeLoaded || tryLoadNativeBridge();
    }

    /**
     * Package inspection helper. It checks the staged arm64 payload exists;
     * it does not verify lifecycle exports or gameplay.
     */
    public static boolean hasBundledRenPy(Context context) {
        if (context == null || context.getApplicationInfo() == null) {
            return false;
        }
        String nativeDir = context.getApplicationInfo().nativeLibraryDir;
        return nativeDir != null && new File(nativeDir, "librenpython.so").isFile();
    }

    /** Extract the bundled Python tree, separate from imported game files. */
    public static synchronized String preparePrivateRoot() throws IOException {
        Context context = SDLActivity.getContext();
        if (context == null) throw new IOException("Ren'Py host Context is unavailable");
        long version;
        try { version = context.getPackageManager().getPackageInfo(context.getPackageName(), 0).lastUpdateTime; }
        catch (android.content.pm.PackageManager.NameNotFoundException e) { throw new IOException(e); }
        File root = new File(context.getFilesDir(), "renpy_mobile/" + version);
        File ready = new File(root, ".ready");
        if (!ready.isFile()) {
            copyAssets(context.getAssets(), "renpy_mobile/private", root, root.getCanonicalPath());
            if (!new File(root, "main.py").isFile() || !new File(root, "renpy/aether_mobile.py").isFile()) {
                throw new IOException("Ren'Py APK lacks the patched Python private payload (main.py and renpy/aether_mobile.py)");
            }
            if (!ready.createNewFile() && !ready.isFile()) throw new IOException("could not mark Ren'Py payload extraction complete");
        }
        return root.getCanonicalPath();
    }

    private static void copyAssets(AssetManager assets, String source, File target, String root) throws IOException {
        if (!target.getCanonicalPath().startsWith(root + File.separator) && !target.getCanonicalPath().equals(root)) {
            throw new IOException("Ren'Py asset escapes its extraction directory");
        }
        String[] children = assets.list(source);
        if (children != null && children.length > 0) {
            if (!target.isDirectory() && !target.mkdirs()) throw new IOException("could not create " + target);
            for (String child : children) copyAssets(assets, source + "/" + child, new File(target, child), root);
        } else {
            File parent = target.getParentFile();
            if (!parent.isDirectory() && !parent.mkdirs()) throw new IOException("could not create " + parent);
            try (InputStream input = assets.open(source); FileOutputStream output = new FileOutputStream(target)) {
                byte[] buffer = new byte[65536];
                int count;
                while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                output.getFD().sync();
            }
        }
    }

    public static String getApkPath() {
        Context context = SDLActivity.getContext();
        return context == null ? "" : context.getApplicationInfo().sourceDir;
    }

    public static void prepareRuntime(int width, int height) {
        SDLActivity.prepareRuntime(width, height);
    }

    public static void stopRuntime() {
        // cooperative_stop destroys the offscreen window first. Clear the
        // IME request while preserving the host Activity and JNI callback tables.
        SDLActivity.releaseRenderTarget();
    }

    private static void ensureNativeBridge() {
        if (!nativeBridgeLoaded && !tryLoadNativeBridge()) {
            throw new IllegalStateException("AetherKiri engine_api JNI bridge is unavailable");
        }
    }

    private static synchronized boolean tryLoadNativeBridge() {
        if (nativeBridgeLoaded) {
            return true;
        }
        try {
            System.loadLibrary("engine_api");
            nativeBridgeLoaded = true;
        } catch (LinkageError ignored) {
            // Godot may load this class before the extension. Retry from
            // ensureNativeBridge once the host has finished loading libraries.
        }
        return nativeBridgeLoaded;
    }

    private static native void nativeSetHostActivity(Activity activity);
}
