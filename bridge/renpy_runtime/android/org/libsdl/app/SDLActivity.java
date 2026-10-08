package org.libsdl.app;

import android.app.Activity;
import android.app.UiModeManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.SparseArray;
import android.view.InputDevice;
import android.view.PointerIcon;
import android.view.Surface;
import android.view.View;
import android.widget.Toast;

import java.lang.ref.WeakReference;

/**
 * SDL 2.0.20 JNI callbacks delegated to Godot's existing Activity.
 * The patched native payload uses SDL's offscreen EGL pbuffer driver.
 * These callbacks never acquire Godot's SurfaceView or start an Activity.
 * CPU frames come from Ren'Py's GL screenshot.
 */
public final class SDLActivity {
    public static final String AETHERKIRI_HOST_SHIM = "renpy-sdl-host-shim-v1";
    private static WeakReference<Activity> hostActivity = new WeakReference<>(null);
    private static final Handler uiHandler = new Handler(Looper.getMainLooper());
    private static final SparseArray<PointerIcon> cursors = new SparseArray<>();
    public static volatile boolean mHasFocus;
    private static boolean initialized;
    private static volatile boolean textInputActive;
    private static int nextCursor = 1;

    private SDLActivity() {}

    public static void bindHostActivity(Activity activity) {
        hostActivity = new WeakReference<>(activity);
        SDL.setContext(activity);
        mHasFocus = true;
    }

    public static void clearHostActivity() {
        releaseRenderTarget();
        mHasFocus = false;
        textInputActive = false;
        hostActivity = new WeakReference<>(null);
        SDL.setContext(null);
    }

    public static Activity getHostActivity() { return hostActivity.get(); }
    public static Context getContext() { return SDL.getContext(); }
    public static View getContentView() {
        Activity activity = getHostActivity();
        return activity == null ? null : activity.getWindow().getDecorView();
    }

    /** Must run before Python/pygame initializes SDL video/audio. */
    public static synchronized void prepareRuntime(int width, int height) {
        if (getHostActivity() == null) throw new IllegalStateException("Ren'Py host Activity is unavailable");
        if (width <= 0 || height <= 0) throw new IllegalArgumentException("invalid Ren'Py render size");
        if (!initialized) {
            // dlopen does not invoke JNI_OnLoad. Java loading is required to
            // bind SDL's JavaVM, then all three callback tables make SDL ready.
            System.loadLibrary("renpython");
            SDLAudioManager.initialize();
            SDLControllerManager.initialize();
            SDL.setupJNI();
            initialized = true;
        }
        mHasFocus = true;
        nativeFocusChanged(true);
    }

    public static Surface getNativeSurface() {
        // Fail closed if an unpatched payload accidentally selects the
        // Android window driver: the host surface must never be borrowed.
        return null;
    }
    public static synchronized void releaseRenderTarget() {
        textInputActive = false;
    }
    public static DisplayMetrics getDisplayDPI() { return getContext().getResources().getDisplayMetrics(); }
    public static boolean isAndroidTV() {
        UiModeManager manager = (UiModeManager) getContext().getSystemService(Context.UI_MODE_SERVICE);
        return manager != null && manager.getCurrentModeType() == Configuration.UI_MODE_TYPE_TELEVISION;
    }
    public static boolean isTablet() { return getContext().getResources().getConfiguration().smallestScreenWidthDp >= 600; }
    public static boolean isChromebook() { return getContext().getPackageManager().hasSystemFeature("org.chromium.arc.device_management"); }
    public static boolean isDeXMode() { return false; }
    public static boolean isScreenKeyboardShown() { return textInputActive; }
    public static boolean shouldMinimizeOnFocusLoss() { return false; }
    public static boolean supportsRelativeMouse() { return false; }
    public static boolean setRelativeMouseEnabled(boolean enabled) { return !enabled; }
    public static void setWindowStyle(boolean fullscreen) { /* Godot owns visible window styling. */ }
    public static void setOrientation(int width, int height, boolean resizable, String hint) { /* Godot owns orientation. */ }
    public static boolean setActivityTitle(String title) {
        Activity activity = getHostActivity();
        if (activity == null) return false;
        uiHandler.post(() -> activity.setTitle(title));
        return true;
    }
    public static boolean sendMessage(int command, int param) {
        // SDL's text-input hide command. Godot polls the provider's active
        // state and drives its own IME; no second EditText steals focus.
        if (command == 3) { textInputActive = false; return true; }
        return false;
    }
    public static boolean showTextInput(int x, int y, int width, int height) {
        textInputActive = true;
        return getHostActivity() != null;
    }
    public static void manualBackButton() { /* Ren'Py BACK is delivered by engine_send_input. */ }
    public static void minimizeWindow() {
        Activity activity = getHostActivity();
        if (activity != null) uiHandler.post(() -> activity.moveTaskToBack(true));
    }
    public static int openURL(String url) {
        Activity activity = getHostActivity();
        if (activity == null) return -1;
        uiHandler.post(() -> activity.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))));
        return 0;
    }
    public static void requestPermission(String permission, int requestCode) {
        Activity activity = getHostActivity();
        if (activity == null) { nativePermissionResult(requestCode, false); return; }
        if (Build.VERSION.SDK_INT < 23 || activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            nativePermissionResult(requestCode, true);
        } else {
            // The host owns permission request/results; do not create an SDL
            // Activity or claim a permission was granted.
            nativePermissionResult(requestCode, false);
        }
    }
    public static int showToast(String message, int duration, int gravity, int xOffset, int yOffset) {
        Context context = getContext();
        if (context == null) return -1;
        uiHandler.post(() -> {
            Toast toast = Toast.makeText(context, message, duration);
            toast.setGravity(gravity, xOffset, yOffset);
            toast.show();
        });
        return 0;
    }
    public static boolean getManifestEnvironmentVariables() {
        try {
            ApplicationInfo info = getContext().getPackageManager().getApplicationInfo(
                getContext().getPackageName(), PackageManager.GET_META_DATA);
            if (info.metaData != null) for (String key : info.metaData.keySet()) {
                if (key.startsWith("SDL_ENV.")) nativeSetenv(key.substring(8), String.valueOf(info.metaData.get(key)));
            }
            return true;
        } catch (PackageManager.NameNotFoundException e) { return false; }
    }
    public static void initTouch() {
        for (int id : InputDevice.getDeviceIds()) {
            InputDevice device = InputDevice.getDevice(id);
            if (device != null && (device.getSources() & InputDevice.SOURCE_TOUCHSCREEN) != 0) nativeAddTouch(id, device.getName());
        }
    }
    private static ClipboardManager clipboard() {
        return (ClipboardManager) getContext().getSystemService(Context.CLIPBOARD_SERVICE);
    }
    public static boolean clipboardHasText() { return clipboard().hasPrimaryClip(); }
    public static String clipboardGetText() {
        ClipData data = clipboard().getPrimaryClip();
        return data == null || data.getItemCount() == 0 ? "" : data.getItemAt(0).coerceToText(getContext()).toString();
    }
    public static void clipboardSetText(String text) { clipboard().setPrimaryClip(ClipData.newPlainText("Ren'Py", text)); }
    public static int createCustomCursor(int[] colors, int width, int height, int hotSpotX, int hotSpotY) {
        if (Build.VERSION.SDK_INT < 24) return 0;
        PointerIcon icon = PointerIcon.create(Bitmap.createBitmap(colors, width, height, Bitmap.Config.ARGB_8888), hotSpotX, hotSpotY);
        synchronized (cursors) { int id = nextCursor++; cursors.put(id, icon); return id; }
    }
    public static void destroyCustomCursor(int id) { synchronized (cursors) { cursors.remove(id); } }
    public static boolean setCustomCursor(int id) {
        if (Build.VERSION.SDK_INT < 24 || getContentView() == null) return false;
        PointerIcon icon;
        synchronized (cursors) { icon = cursors.get(id); }
        if (icon == null) return false;
        uiHandler.post(() -> { if (getContentView() != null) getContentView().setPointerIcon(icon); });
        return true;
    }
    public static boolean setSystemCursor(int id) {
        if (Build.VERSION.SDK_INT < 24 || getContentView() == null) return false;
        int[] types = { PointerIcon.TYPE_ARROW, PointerIcon.TYPE_TEXT, PointerIcon.TYPE_WAIT,
            PointerIcon.TYPE_CROSSHAIR, PointerIcon.TYPE_WAIT, PointerIcon.TYPE_TOP_LEFT_DIAGONAL_DOUBLE_ARROW,
            PointerIcon.TYPE_TOP_RIGHT_DIAGONAL_DOUBLE_ARROW, PointerIcon.TYPE_HORIZONTAL_DOUBLE_ARROW,
            PointerIcon.TYPE_VERTICAL_DOUBLE_ARROW, PointerIcon.TYPE_ALL_SCROLL, PointerIcon.TYPE_NO_DROP, PointerIcon.TYPE_HAND };
        if (id < 0 || id >= types.length) return false;
        PointerIcon icon = PointerIcon.getSystemIcon(getContext(), types[id]);
        uiHandler.post(() -> { if (getContentView() != null) getContentView().setPointerIcon(icon); });
        return true;
    }

    public static native int nativeSetupJNI();
    public static native int nativeRunMain(String library, String function, Object arguments);
    public static native void nativeLowMemory();
    public static native void nativeSendQuit();
    public static native void nativeQuit();
    public static native void nativePause();
    public static native void nativeResume();
    public static native void nativeFocusChanged(boolean hasFocus);
    public static native void onNativeDropFile(String filename);
    public static native void nativeSetScreenResolution(int surfaceWidth, int surfaceHeight, int deviceWidth, int deviceHeight, float rate);
    public static native void onNativeResize();
    public static native void onNativeKeyDown(int keycode);
    public static native void onNativeKeyUp(int keycode);
    public static native boolean onNativeSoftReturnKey();
    public static native void onNativeKeyboardFocusLost();
    public static native void nativeSetenv(String name, String value);
    public static native void onNativeTouch(int touchDevId, int pointerFingerId, int action, float x, float y, float pressure);
    public static native void onNativeMouse(int button, int action, float x, float y, boolean relative);
    public static native void onNativeAccel(float x, float y, float z);
    public static native void onNativeClipboardChanged();
    public static native void onNativeSurfaceCreated();
    public static native void onNativeSurfaceChanged();
    public static native void onNativeSurfaceDestroyed();
    public static native String nativeGetHint(String name);
    public static native boolean nativeGetHintBoolean(String name, boolean defaultValue);
    public static native void onNativeOrientationChanged(int orientation);
    public static native void nativeAddTouch(int touchId, String name);
    public static native void nativePermissionResult(int requestCode, boolean result);
    public static native void onNativeLocaleChanged();
}
