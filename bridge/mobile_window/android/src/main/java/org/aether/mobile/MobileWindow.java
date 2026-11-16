package org.aether.mobile;

import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Log;
import android.util.Rational;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;

/** Godot owns PiP entry and lifecycle; Aether gates it on an open game. */
public final class MobileWindow {
    private MobileWindow() {}

    public static boolean isSupported(Activity activity) {
        return activity instanceof GodotActivity && Build.VERSION.SDK_INT >= 26
            && activity.getPackageManager().hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE);
    }

    public static boolean isInPictureInPicture(Activity activity) {
        return Build.VERSION.SDK_INT >= 26 && activity != null && activity.isInPictureInPictureMode();
    }

    public static void configure(Activity activity, boolean gameActive, boolean enabled, String background) {
        if (!(activity instanceof GodotActivity)) return;
        activity.runOnUiThread(() -> {
            if (activity.isFinishing() || activity.isDestroyed()) return;
            Godot godot = ((GodotActivity) activity).getGodot();
            if (godot != null) {
                // Update Godot's own state so its onResume does not re-enter
                // immersive mode while the library or settings are visible.
                godot.enableImmersiveMode(gameActive);
                godot.setWindowColor(background);
                if (!gameActive) {
                    // SDL/fullscreen activity themes can retain this legacy
                    // flag, even after Godot stops requesting immersive mode.
                    Window window = activity.getWindow();
                    window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                    WindowCompat.getInsetsController(window, window.getDecorView())
                        .show(WindowInsetsCompat.Type.statusBars());
                }
            }
            // System bars must work even on devices without PiP support.
            if (!isSupported(activity)) return;
            View content = activity.findViewById(android.R.id.content);
            int width = content == null ? 0 : content.getWidth();
            int height = content == null ? 0 : content.getHeight();
            Rational aspect = width > 0 && height > 0 ? new Rational(width, height) : new Rational(16, 9);
            try {
                ((GodotActivity) activity).updatePiPParams(gameActive && enabled, aspect);
            } catch (IllegalArgumentException | IllegalStateException error) {
                Log.w("AetherPiP", "Picture in Picture is unavailable", error);
            }
        });
    }
}
