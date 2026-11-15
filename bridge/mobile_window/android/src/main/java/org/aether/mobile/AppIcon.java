package org.aether.mobile;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.ComponentName;
import android.content.pm.PackageManager;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.util.Log;
import java.util.ArrayList;

/** Swap only launcher aliases; never disable the running Godot activity. */
public final class AppIcon {
    private AppIcon() {}
    private static final String ASTRYX = "com.godot.game.GodotAppLauncher";
    private static final String ASTRYX_DARK = "com.godot.game.AetherAstryxDarkLauncher";
    private static final String CLASSIC = "com.godot.game.AetherClassicLauncher";

    public static void apply(Activity activity, boolean astryx, boolean dark) {
        if (activity == null) return;
        activity.runOnUiThread(() -> {
            if (activity.isFinishing() || activity.isDestroyed()) return;
            try {
                PackageManager manager = activity.getPackageManager();
                ComponentName wanted = new ComponentName(activity.getPackageName(),
                    astryx ? (dark ? ASTRYX_DARK : ASTRYX) : CLASSIC);
                ComponentName[] aliases = {
                    new ComponentName(activity.getPackageName(), ASTRYX),
                    new ComponentName(activity.getPackageName(), ASTRYX_DARK),
                    new ComponentName(activity.getPackageName(), CLASSIC)
                };
                // Validate every alias before changing any, so an older / incomplete
                // package cannot lose its only working home-screen entry.
                boolean needsUpdate = false;
                for (ComponentName alias : aliases) {
                    manager.getActivityInfo(alias, PackageManager.MATCH_DISABLED_COMPONENTS);
                    needsUpdate |= isEnabled(manager, alias) != alias.equals(wanted);
                }
                if (needsUpdate) {
                    if (Build.VERSION.SDK_INT >= 33) {
                        ArrayList<PackageManager.ComponentEnabledSetting> changes = new ArrayList<>();
                        for (ComponentName alias : aliases) {
                            changes.add(new PackageManager.ComponentEnabledSetting(alias,
                                alias.equals(wanted) ? PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                                    : PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                                PackageManager.DONT_KILL_APP));
                        }
                        manager.setComponentEnabledSettings(changes);
                    } else {
                        // Older Android lacks the atomic API. Enable first so a
                        // process interruption never leaves all aliases hidden.
                        manager.setComponentEnabledSetting(wanted,
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP);
                        for (ComponentName alias : aliases) {
                            if (!alias.equals(wanted)) {
                                manager.setComponentEnabledSetting(alias,
                                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP);
                            }
                        }
                    }
                }
                // Recents uses the running task's icon rather than its alias.
                int resource = activity.getResources().getIdentifier(
                    astryx ? (dark ? "aether_astryx_dark_task" : "aether_astryx_task") : "aether_classic_task",
                    "drawable", activity.getPackageName());
                if (resource != 0) {
                    activity.setTaskDescription(new ActivityManager.TaskDescription(
                        manager.getApplicationLabel(activity.getApplicationInfo()).toString(),
                        BitmapFactory.decodeResource(activity.getResources(), resource),
                        astryx && dark ? 0xff000000 : 0xfff1f1f1));
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
