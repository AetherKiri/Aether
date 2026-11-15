package org.aether.mobile;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.ComponentName;
import android.content.pm.PackageManager;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.util.Log;
import java.util.Arrays;

/** Swap only launcher aliases; never disable the running Godot activity. */
public final class AppIcon {
    private AppIcon() {}
    private static final String ASTRYX = "com.godot.game.GodotAppLauncher";
    private static final String CLASSIC = "com.godot.game.AetherClassicLauncher";

    public static void apply(Activity activity, boolean astryx) {
        if (activity == null) return;
        activity.runOnUiThread(() -> {
            if (activity.isFinishing() || activity.isDestroyed()) return;
            try {
                PackageManager manager = activity.getPackageManager();
                ComponentName wanted = new ComponentName(activity.getPackageName(), astryx ? ASTRYX : CLASSIC);
                ComponentName other = new ComponentName(activity.getPackageName(), astryx ? CLASSIC : ASTRYX);
                // Validate both before changing either, so an older / incomplete
                // package cannot lose its only working home-screen entry.
                manager.getActivityInfo(wanted, PackageManager.MATCH_DISABLED_COMPONENTS);
                manager.getActivityInfo(other, PackageManager.MATCH_DISABLED_COMPONENTS);
                if (!isEnabled(manager, wanted) || isEnabled(manager, other)) {
                    if (Build.VERSION.SDK_INT >= 33) {
                        manager.setComponentEnabledSettings(Arrays.asList(
                            new PackageManager.ComponentEnabledSetting(wanted,
                                PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP),
                            new PackageManager.ComponentEnabledSetting(other,
                                PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)));
                    } else {
                        // Older Android lacks the atomic API. Enable first so a
                        // process interruption never leaves both aliases hidden.
                        manager.setComponentEnabledSetting(wanted,
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP);
                        manager.setComponentEnabledSetting(other,
                            PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP);
                    }
                }
                // Recents uses the running task's icon rather than its alias.
                int resource = activity.getResources().getIdentifier(
                    astryx ? "aether_astryx_task" : "aether_classic_task", "drawable", activity.getPackageName());
                if (resource != 0) {
                    activity.setTaskDescription(new ActivityManager.TaskDescription(
                        manager.getApplicationLabel(activity.getApplicationInfo()).toString(),
                        BitmapFactory.decodeResource(activity.getResources(), resource), 0xfff1f1f1));
                }
            } catch (PackageManager.NameNotFoundException | RuntimeException error) {
                Log.w("AetherAppIcon", "Could not switch the launcher icon", error);
            }
        });
    }

    private static boolean isEnabled(PackageManager manager, ComponentName component)
            throws PackageManager.NameNotFoundException {
        int state = manager.getComponentEnabledSetting(component);
        if (state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT) {
            return manager.getActivityInfo(component, PackageManager.MATCH_DISABLED_COMPONENTS).enabled;
        }
        return state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED;
    }
}
