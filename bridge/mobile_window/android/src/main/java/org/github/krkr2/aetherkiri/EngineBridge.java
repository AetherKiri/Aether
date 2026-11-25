package org.github.krkr2.aetherkiri;

import android.app.Application;
import android.content.Context;
import android.util.Log;

/** Supplies the engine's JNI bridge before Godot starts any runtime threads. */
public final class EngineBridge extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        try {
            // Loading engine_api as a dependency of a GDExtension skips JNI_OnLoad.
            System.loadLibrary("engine_api");
            nativeSetApplicationContext(this);
        } catch (UnsatisfiedLinkError error) {
            Log.e("Aether", "Could not initialize the native engine bridge", error);
        }
    }

    private static native void nativeSetApplicationContext(Context context);
}
