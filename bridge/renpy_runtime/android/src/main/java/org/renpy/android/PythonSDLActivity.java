package org.renpy.android;

import android.os.Bundle;
import android.content.Intent;
import android.net.Uri;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.content.pm.PackageManager;
import android.view.View;
import android.view.ViewGroup;
import android.view.SurfaceView;
import android.view.WindowManager;
import android.widget.FrameLayout;
import org.aether.renpy.RenpyHost;
import org.aether.sdl.SDLActivity;

/** Same Activity as GodotApp. The staged SDLActivity derives from GodotActivity. */
public class PythonSDLActivity extends SDLActivity {
    public static PythonSDLActivity mActivity;
    public FrameLayout mFrameLayout;
    private View sdlContent;

    @Override public void onCreate(Bundle state) {
        mActivity = this;
        super.onCreate(state);
        if (!mBrokenLibraries) nativeSetenv("ANDROID_APK", getApplicationInfo().sourceDir);
    }
    @Override protected String[] getLibraries() { return new String[]{"renpython", "aether_renpy_android"}; }
    @Override protected String getMainSharedObject() {
        return "libaether_renpy_android.so";
    }
    @Override protected String getMainFunction() { return "aether_renpy_android_main"; }
    @Override public void setContentView(View view) {
        if (view == mLayout) {
            sdlContent = view;
            mFrameLayout = new FrameLayout(this);
            mFrameLayout.addView(view, new FrameLayout.LayoutParams(-1, -1));
            if (mSurface != null) ((SurfaceView)mSurface).setZOrderMediaOverlay(true);
        } else super.setContentView(view);
    }
    public View getRenpyContent() { return mFrameLayout; }
    public void addView(View view, int index) {
        runOnUiThread(() -> mFrameLayout.addView(view, index));
    }
    public void removeView(View view) {
        runOnUiThread(() -> mFrameLayout.removeView(view));
    }
    public void pauseRenpy(boolean paused) {
        if (paused) pauseNativeThread(); else resumeNativeThread();
    }
    // Android game data lives in Aether's library, not Play Asset Packs.
    public void hidePresplash() {}
    public void preparePython() {}
    public int getDPI() { return getResources().getDisplayMetrics().densityDpi; }
    public void setWakeLock(boolean active) {
        runOnUiThread(() -> {
            if (active) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        });
    }
    // Ren'Py's standalone host can finish on backgrounding. Aether owns the
    // Activity lifetime and resumes the same native session instead.
    public void armOnStop() {}
    public void finishOnStop() {}
    public void vibrate(double seconds) {
        if (checkSelfPermission(android.Manifest.permission.VIBRATE) != PackageManager.PERMISSION_GRANTED) return;
        Vibrator vibrator = (Vibrator)getSystemService(VIBRATOR_SERVICE);
        if (vibrator != null && vibrator.hasVibrator() && seconds > 0)
            vibrator.vibrate(VibrationEffect.createOneShot(Math.max(1,(long)(seconds*1000)), VibrationEffect.DEFAULT_AMPLITUDE));
    }
    public void openUrl(String value) {
        runOnUiThread(() -> {
            try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(value))); }
            catch (android.content.ActivityNotFoundException error) { toastError(error.toString()); }
        });
    }
    public int mActivityResultRequestCode = -1;
    public int mActivityResultResultCode = -1;
    public Intent mActivityResultResultData;
    @Override public void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        mActivityResultRequestCode = request;
        mActivityResultResultCode = result;
        mActivityResultResultData = data;
    }
    public void toastError(String message) {
        runOnUiThread(() -> android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_LONG).show());
    }
    @Override public void setOrientationBis(int width, int height, boolean resizable, String hint) {}
    @Override public void onDestroy() {
        if (!mBrokenLibraries) RenpyHost.nativeShutdown();
        super.onDestroy();
        if (mActivity == this) mActivity = null;
    }
}
