package org.libsdl.app;

/**
 * Registration target required by SDL 2.0.20 JNI_OnLoad. Godot owns the IME
 * view and sends committed Unicode through engine_send_input; this class
 * never adds another editor or consumes uncommitted composition text.
 */
public final class SDLInputConnection {
    private SDLInputConnection() {}
    public static native void nativeCommitText(String text, int newCursorPosition);
    public static native void nativeGenerateScancodeForUnichar(char unicode);
    public static native void nativeSetComposingText(String text, int newCursorPosition);
}
