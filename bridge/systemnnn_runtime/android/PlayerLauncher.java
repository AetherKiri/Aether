package org.aether.systemnnn;

import android.app.Activity;
import android.app.Fragment;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;
import com.tyranor.runtime.systemnnn.SystemNnnHost;
import java.io.File;
import java.io.IOException;

/** Return the upstream player's Activity result to the session that launched it. */
public final class PlayerLauncher extends Fragment {
    private Runnable finished;
    private static final int REQUEST = 1;

    public static void launch(Activity activity, String path, Runnable finished, Runnable failed) {
        if (activity == null) { failed.run(); return; }
        activity.runOnUiThread(() -> {
            PlayerLauncher result = new PlayerLauncher();
            try {
                File root = new File(path);
                Intent intent = SystemNnnHost.createLaunchIntent(activity, root, root.getName());
                result.finished = finished;
                activity.getFragmentManager().beginTransaction().add(result, "aether-systemnnn").commitNow();
                result.startActivityForResult(intent, REQUEST);
            } catch (IOException | RuntimeException e) {
                Log.e("Aether", "Cannot start SystemNNN", e);
                result.remove();
                failed.run();
            }
        });
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        setRetainInstance(true);
    }

    @Override public void onActivityResult(int request, int code, Intent data) {
        super.onActivityResult(request, code, data);
        if (request != REQUEST) return;
        remove();
        if (finished != null) finished.run();
        finished = null;
    }

    private void remove() {
        if (isAdded()) getFragmentManager().beginTransaction().remove(this).commitAllowingStateLoss();
    }
}
