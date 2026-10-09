package org.renpy.android;

import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.WindowManager;

import org.libsdl.app.SDLActivity;

/** Ren'Py Android API delegated to the existing host, without an Activity. */
public final class PythonSDLActivity {
    public static final String AETHERKIRI_HOST_SHIM = "renpy-python-host-shim-v1";
    public static final PythonSDLActivity mActivity = new PythonSDLActivity();
    public Object mStore = null;
    public volatile boolean quitRequested;

    public Activity getActivity() {
        Activity activity = SDLActivity.getHostActivity();
        if (activity == null) throw new IllegalStateException("Ren'Py host Activity is unavailable");
        return activity;
    }
    public PackageManager getPackageManager() { return getActivity().getPackageManager(); }
    public String getPackageName() { return getActivity().getPackageName(); }
    public int getDPI() { return getActivity().getResources().getDisplayMetrics().densityDpi; }
    public static boolean isChromebook() { return SDLActivity.isChromebook(); }
    public void openUrl(String url) { SDLActivity.openURL(url); }
    public void vibrate(double seconds) {
        Vibrator vibrator = (Vibrator) getActivity().getSystemService(Context.VIBRATOR_SERVICE);
        if (vibrator == null || seconds <= 0) return;
        long duration = Math.max(1L, (long) (seconds * 1000.0));
        if (Build.VERSION.SDK_INT >= 26) vibrator.vibrate(VibrationEffect.createOneShot(duration, VibrationEffect.DEFAULT_AMPLITUDE));
        else vibrator.vibrate(duration);
    }
    public void setWakeLock(boolean active) {
        Activity activity = getActivity();
        activity.runOnUiThread(() -> {
            if (active) activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            else activity.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        });
    }
    // The host owns the visible loading UI and lifecycle. cooperative_pause
    // saves state and pauses audio instead of asking another Activity to stop.
    public void hidePresplash() {}
    public void armOnStop() {}
    public void finishOnStop() { quitRequested = true; }
    public void finishAndRemoveTask() { quitRequested = true; }
    public void createStore() { /* IAP integration is not registered by this host. */ }
    public native void nativeSetEnv(String variable, String value);
}
