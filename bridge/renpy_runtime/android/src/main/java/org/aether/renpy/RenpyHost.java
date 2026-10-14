package org.aether.renpy;

import android.app.Activity;
import android.view.View;
import android.view.ViewGroup;
import android.view.SurfaceView;
import android.view.TextureView;
import android.widget.FrameLayout;
import org.renpy.android.PythonSDLActivity;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipEntry;

/** Native SDL Surface hosted below Aether's toolbar; no WebView or new Activity. */
public final class RenpyHost {
    private final PythonSDLActivity activity;
    private FrameLayout root;
    private View content, godot;
    private volatile boolean closed, embedded;
    private volatile String error = "";
    private final double[] rect = {0, 0, 1, 1};
    private final View.OnLayoutChangeListener layout = (v,l,t,r,b,ol,ot,or,ob) -> applyRect();
    private static volatile String preparationError = "";
    private static native String nativeOpen(String sdk, String manifest, String bootstrap);
    private static native void nativeClose();
    private static native void nativeInput(String event);
    private static native String nativeError();
    public static native void nativeShutdown();

    public static boolean isSupported(Activity activity) { return activity instanceof PythonSDLActivity; }
    public static synchronized String prepareRuntime(Activity activity) {
        preparationError = "";
        try {
            String digest;
            try (BufferedReader input = new BufferedReader(new InputStreamReader(activity.getAssets().open("aether_renpy_runtime.sha256"), StandardCharsets.UTF_8))) {
                digest = input.readLine();
            }
            if (digest == null || !digest.matches("[a-f0-9]{64}")) throw new IOException("Invalid packaged runtime identity");
            File runtime = new File(activity.getFilesDir(), "aether-renpy/runtime-8.5.3-" + digest.substring(0,16));
            if (new File(runtime, ".complete").isFile()) return runtime.getCanonicalPath();
            File pending = new File(runtime.getParentFile(), runtime.getName() + ".pending");
            remove(pending);
            if (!pending.mkdirs()) throw new IOException("Cannot create the Ren'Py runtime folder");
            String prefix = pending.getCanonicalPath() + File.separator;
            try (ZipInputStream archive = new ZipInputStream(activity.getAssets().open("aether_renpy_runtime.zip"))) {
                ZipEntry entry;
                byte[] buffer = new byte[65536];
                while ((entry = archive.getNextEntry()) != null) {
                    File target = new File(pending, entry.getName()).getCanonicalFile();
                    if (!target.getPath().startsWith(prefix)) throw new IOException("Invalid runtime archive path");
                    if (entry.isDirectory()) { target.mkdirs(); continue; }
                    if (!target.getParentFile().isDirectory() && !target.getParentFile().mkdirs()) throw new IOException("Cannot create a runtime subfolder");
                    try (FileOutputStream output = new FileOutputStream(target)) {
                        int size;
                        while ((size = archive.read(buffer)) != -1) output.write(buffer, 0, size);
                    }
                }
            }
            if (!new File(pending, "renpy.py").isFile()) throw new IOException("The packaged Ren'Py runtime is incomplete");
            try (FileOutputStream marker = new FileOutputStream(new File(pending, ".complete"))) {
                marker.write(digest.getBytes(StandardCharsets.UTF_8));
            }
            remove(runtime);
            if (!pending.renameTo(runtime)) throw new IOException("Cannot install the Ren'Py runtime");
            return runtime.getCanonicalPath();
        } catch (Exception failure) { preparationError = failure.toString(); return ""; }
    }
    public static String getPreparationError() { return preparationError; }
    private static void remove(File file) throws IOException {
        if (!file.exists()) return;
        File[] children = Files.isSymbolicLink(file.toPath()) ? null : file.listFiles();
        if (children != null) for (File child : children) remove(child);
        if (!file.delete()) throw new IOException("Cannot replace an incomplete runtime: " + file.getName());
    }
    public static RenpyHost create(Activity activity, String sdk, String manifest, String bootstrap) {
        return new RenpyHost(activity, sdk, manifest, bootstrap);
    }
    private RenpyHost(Activity value, String sdk, String manifest, String bootstrap) {
        if (!(value instanceof PythonSDLActivity)) { activity = null; error = "The native Ren'Py Activity was not packaged"; return; }
        activity = (PythonSDLActivity)value;
        error = nativeOpen(sdk, manifest, bootstrap);
        if (error.isEmpty()) activity.runOnUiThread(this::attach);
    }
    private static View surface(View view) {
        if (view instanceof SurfaceView || view instanceof TextureView) return view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)view;
            for (int i=0; i<group.getChildCount(); i++) {
                View found = surface(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }
    private void attach() {
        if (closed) return;
        try {
            root = activity.findViewById(android.R.id.content);
            godot = surface(root);
            content = activity.getRenpyContent();
            if (content == null) throw new IOException("The native SDL Surface is unavailable");
            if (content.getParent() instanceof ViewGroup) ((ViewGroup)content.getParent()).removeView(content);
            root.addView(content, new FrameLayout.LayoutParams(1, 1));
            root.addOnLayoutChangeListener(layout);
            if (godot != null) godot.addOnLayoutChangeListener(layout);
            applyRect(); content.requestFocus();
            activity.pauseRenpy(false);
        } catch (Exception failure) { error = failure.toString(); nativeClose(); }
    }
    private void applyRect() {
        if (closed || content == null || root == null) return;
        View source = godot == null ? root : godot;
        int[] origin = new int[2], parent = new int[2];
        source.getLocationInWindow(origin); root.getLocationInWindow(parent);
        FrameLayout.LayoutParams size;
        synchronized (rect) {
            size = new FrameLayout.LayoutParams(Math.max(1,(int)Math.round(source.getWidth()*rect[2])),Math.max(1,(int)Math.round(source.getHeight()*rect[3])));
            size.leftMargin = origin[0]-parent[0]+(int)Math.round(source.getWidth()*rect[0]);
            size.topMargin = origin[1]-parent[1]+(int)Math.round(source.getHeight()*rect[1]);
        }
        android.view.ViewGroup.LayoutParams previous = content.getLayoutParams();
        if (!(previous instanceof FrameLayout.LayoutParams) || previous.width != size.width || previous.height != size.height
            || ((FrameLayout.LayoutParams)previous).leftMargin != size.leftMargin || ((FrameLayout.LayoutParams)previous).topMargin != size.topMargin)
            content.setLayoutParams(size);
        embedded = content.isAttachedToWindow() && content.getRootView() == activity.getWindow().getDecorView().getRootView();
    }
    public void setRect(double x, double y, double w, double h) {
        synchronized (rect) {
            if (rect[0]==x && rect[1]==y && rect[2]==w && rect[3]==h) return;
            rect[0]=x; rect[1]=y; rect[2]=w; rect[3]=h;
        }
        if (activity != null) activity.runOnUiThread(this::applyRect);
    }
    public String getError() { String engine = nativeError(); return error.isEmpty() ? engine : error; }
    public boolean isEmbedded() { return embedded && !closed; }
    public void sendInput(String event) { if (!closed) nativeInput(event); }
    public void setPaused(boolean value) { if (activity != null) activity.runOnUiThread(() -> { if (!closed) activity.pauseRenpy(value); }); }
    public void close() {
        if (closed) return;
        closed = true; embedded = false; nativeClose();
        if (activity != null) activity.runOnUiThread(() -> {
            if (root != null) root.removeOnLayoutChangeListener(layout);
            if (godot != null) godot.removeOnLayoutChangeListener(layout);
            if (content != null && content.getParent() instanceof ViewGroup) ((ViewGroup)content.getParent()).removeView(content);
            if (godot != null) godot.requestFocus();
        });
    }
}
