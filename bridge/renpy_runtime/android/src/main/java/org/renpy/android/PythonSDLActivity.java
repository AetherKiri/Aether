package org.renpy.android;

import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.view.SurfaceView;
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
    public void pauseRenpy(boolean paused) {
        if (paused) pauseNativeThread(); else resumeNativeThread();
    }
    // Android game data lives in Aether's library, not Play Asset Packs.
    public void hidePresplash() {}
    public void preparePython() {}
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
