package org.aether.tyrano;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Application;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.util.AtomicFile;
import android.view.KeyEvent;
import android.view.SurfaceView;
import android.view.TextureView;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.webkit.ConsoleMessage;
import android.webkit.CookieManager;
import android.webkit.JsPromptResult;
import android.webkit.JsResult;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Iterator;

/** Invoked through Godot's JavaClassWrapper. All WebView work stays on the UI thread. */
public final class TyranoHost implements Application.ActivityLifecycleCallbacks {
    private final Activity activity;
    private final ArrayDeque<String> events = new ArrayDeque<>();
    private final ArrayList<JsResult> dialogs = new ArrayList<>();
    private final ArrayList<AlertDialog> dialogWindows = new ArrayList<>();
    private AtomicFile storage;
    private String storageJSON = "{}", controlsJSON = "{}", origin, entryURL;
    private volatile String error = "";
    private volatile boolean closed;
    private TyranoFiles files;
    private WebView web;
    private FrameLayout container;
    private View surface;
    private boolean registered, paused, inactive;
    private final double[] rect = {0, 0, 1, 1};
    private final View.OnLayoutChangeListener layout = (v, l, t, r, b, ol, ot, or, ob) -> layoutWeb();
    private final ViewTreeObserver.OnWindowFocusChangeListener focus = value -> applyState();

    public static TyranoHost create(Activity activity, String entry, String storagePath) {
        return new TyranoHost(activity, entry, storagePath);
    }

    private TyranoHost(Activity activity, String entry, String storagePath) {
        this.activity = activity;
        try {
            if (activity == null) throw new IOException("The Android activity is unavailable");
            File save = new File(storagePath).getCanonicalFile();
            if (!save.getParentFile().isDirectory() && !save.getParentFile().mkdirs()) throw new IOException("Cannot create the game save folder");
            storage = new AtomicFile(save);
            File backup = new File(storagePath + ".bak");
            if (Math.max(save.length(), backup.length()) > 64 * 1024 * 1024) throw new IOException("Game storage is too large; the original file was preserved");
            if (save.exists() || backup.exists()) storageJSON = validStorage(new String(storage.readFully(), StandardCharsets.UTF_8));
            byte[] identity = MessageDigest.getInstance("SHA-256").digest(storagePath.getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder();
            for (byte value : identity) hex.append(String.format("%02x", value & 255));
            origin = "https://" + hex + ".tyrano.aether.invalid";
            String script;
            try (java.io.InputStream input = activity.getAssets().open("aether_tyrano_host.js")) {
                java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
                byte[] buffer = new byte[8192]; int read;
                while ((read = input.read(buffer)) != -1) bytes.write(buffer, 0, read);
                script = bytes.toString("UTF-8").replace("__AETHER_STORAGE__", "{}");
            }
            files = new TyranoFiles(entry, origin, script);
            entryURL = origin + "/" + Uri.encode(new File(entry).getName());
            activity.runOnUiThread(this::attach);
        } catch (Exception failure) { error = failure.getMessage() == null ? failure.toString() : failure.getMessage(); }
    }

    public String getError() { return error; }
    private synchronized void push(String type, Object value) {
        if (closed) return;
        try {
            if (events.size() >= 128) events.removeFirst();
            events.addLast(new JSONObject().put("type", type).put("value", value).toString());
        } catch (Exception ignored) { }
    }
    public synchronized String poll() { return events.isEmpty() ? "" : events.removeFirst(); }

    private static String validStorage(String json) throws Exception {
        if (json.getBytes(StandardCharsets.UTF_8).length > 64 * 1024 * 1024) throw new IOException("Game storage is too large; the original file was preserved");
        JSONObject values = new JSONObject(json);
        if (values.length() > 1024) throw new IOException("Game storage has too many keys; the original file was preserved");
        for (Iterator<String> keys = values.keys(); keys.hasNext();) {
            if (!(values.get(keys.next()) instanceof String)) throw new IOException("Game storage has invalid values; the original file was preserved");
        }
        return json;
    }

    private String persist(String json) {
        FileOutputStream output = null;
        try {
            validStorage(json);
            output = storage.startWrite();
            output.write(json.getBytes(StandardCharsets.UTF_8));
            storage.finishWrite(output);
            output = null;
            if (!new String(storage.readFully(), StandardCharsets.UTF_8).equals(json)) throw new IOException("Game storage write could not be verified");
            storageJSON = json;
            push("storage_saved", true);
            return null;
        } catch (Exception failure) {
            if (output != null) storage.failWrite(output);
            return failure.getMessage() == null ? "Cannot persist game storage" : failure.getMessage();
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private void attach() {
        if (closed) return;
        try {
            container = activity.findViewById(android.R.id.content);
            if (container == null) throw new IOException("The Android content view is unavailable");
            surface = findSurface(container);
            web = new WebView(activity);
            web.setBackgroundColor(Color.BLACK);
            WebSettings settings = web.getSettings();
            settings.setJavaScriptEnabled(true);
            settings.setAllowFileAccess(false);
            settings.setAllowContentAccess(false);
            settings.setDomStorageEnabled(false); // The injected Storage adapter owns saves.
            settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
            settings.setMediaPlaybackRequiresUserGesture(false);
            settings.setSupportMultipleWindows(false);
            CookieManager.getInstance().setAcceptThirdPartyCookies(web, false);
            web.setWebViewClient(new WebViewClient() {
                @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                    String range = null;
                    for (java.util.Map.Entry<String, String> header : request.getRequestHeaders().entrySet()) {
                        if (header.getKey().equalsIgnoreCase("Range")) range = header.getValue();
                    }
                    TyranoFiles.Response response = files.read(request.getUrl().toString(), request.getMethod(), range);
                    return new WebResourceResponse(response.mime, "UTF-8", response.status, reason(response.status), response.headers, response.body);
                }
                @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                    return !request.getUrl().toString().startsWith(origin + "/");
                }
                @Override public void onPageFinished(WebView view, String url) { push("document_loaded", true); }
                @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError failure) {
                    if (request.isForMainFrame()) push("error", failure.getDescription().toString());
                }
                @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                    push("error", "The TyranoScript web process stopped");
                    if (view.getParent() instanceof ViewGroup) ((ViewGroup)view.getParent()).removeView(view);
                    view.destroy(); web = null;
                    return true;
                }
            });
            web.setWebChromeClient(new WebChromeClient() {
                @Override public boolean onJsPrompt(WebView view, String url, String message, String text, JsPromptResult result) {
                    if (url.startsWith(origin + "/")) {
                        if (message.equals("__AETHER_TYRANO_STORAGE_READ__")) { result.confirm(storageJSON); return true; }
                        if (message.equals("__AETHER_TYRANO_STORAGE__")) {
                            String failure = persist(text);
                            if (failure == null) result.cancel(); else result.confirm(failure);
                            return true;
                        }
                        if (message.equals("__AETHER_TYRANO_EVENT__")) {
                            try {
                                JSONObject event = new JSONObject(text);
                                String type = event.getString("type");
                                if (type.equals("ready") || type.equals("log") || type.equals("close") || type.equals("controls_input")) push(type, event.optString("value"));
                                if (type.equals("ready")) view.post(() -> applyState());
                            } catch (Exception ignored) { }
                            result.cancel(); return true;
                        }
                    }
                    dialog(message, text, true, result); return true;
                }
                @Override public boolean onJsAlert(WebView view, String url, String message, JsResult result) { dialog(message, null, false, result); return true; }
                @Override public boolean onJsConfirm(WebView view, String url, String message, JsResult result) { dialog(message, null, true, result); return true; }
                @Override public boolean onConsoleMessage(ConsoleMessage message) {
                    if (message.messageLevel() == ConsoleMessage.MessageLevel.ERROR) push("log", message.message());
                    return true;
                }
            });
            web.setOnKeyListener((view, key, event) -> {
                if (key != KeyEvent.KEYCODE_BACK) return false;
                if (event.getAction() == KeyEvent.ACTION_UP) push("close", "");
                return true;
            });
            container.addView(web, new FrameLayout.LayoutParams(1, 1));
            container.addOnLayoutChangeListener(layout);
            container.getViewTreeObserver().addOnWindowFocusChangeListener(focus);
            if (surface != null) surface.addOnLayoutChangeListener(layout);
            activity.getApplication().registerActivityLifecycleCallbacks(this);
            registered = true;
            layoutWeb();
            web.loadUrl(entryURL);
        } catch (Exception failure) { push("error", failure.toString()); }
    }

    private static View findSurface(View view) {
        if (view instanceof SurfaceView || view instanceof TextureView) return view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)view;
            for (int i = 0; i < group.getChildCount(); i++) {
                View found = findSurface(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }
    private static String reason(int status) {
        switch (status) {
            case 200: return "OK"; case 206: return "Partial Content";
            case 403: return "Forbidden"; case 405: return "Method Not Allowed";
            case 416: return "Range Not Satisfiable"; default: return "Not Found";
        }
    }
    private void dialog(String message, String text, boolean cancel, JsResult result) {
        if (closed || activity.isFinishing()) { result.cancel(); return; }
        dialogs.add(result);
        EditText field = text == null ? null : new EditText(activity);
        if (field != null) field.setText(text);
        AlertDialog.Builder alert = new AlertDialog.Builder(activity).setTitle("TyranoScript").setMessage(message)
            .setPositiveButton(android.R.string.ok, (dialog, which) -> {
                dialogs.remove(result);
                if (result instanceof JsPromptResult) ((JsPromptResult)result).confirm(field.getText().toString());
                else result.confirm();
            }).setOnCancelListener(dialog -> { dialogs.remove(result); result.cancel(); });
        if (field != null) alert.setView(field);
        if (cancel) alert.setNegativeButton(android.R.string.cancel, (dialog, which) -> { dialogs.remove(result); result.cancel(); });
        AlertDialog window = alert.create();
        dialogWindows.add(window);
        window.setOnDismissListener(dialog -> dialogWindows.remove(window));
        window.show();
    }

    public void setRect(double x, double y, double width, double height) {
        synchronized (rect) {
            if (rect[0] == x && rect[1] == y && rect[2] == width && rect[3] == height) return;
            rect[0] = x; rect[1] = y; rect[2] = width; rect[3] = height;
        }
        activity.runOnUiThread(this::layoutWeb);
    }
    private void layoutWeb() {
        if (closed || web == null || container == null) return;
        View viewport = surface == null ? container : surface;
        int[] contentAt = new int[2], viewportAt = new int[2];
        container.getLocationInWindow(contentAt); viewport.getLocationInWindow(viewportAt);
        synchronized (rect) {
            FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(Math.max(1, (int)Math.round(rect[2] * viewport.getWidth())), Math.max(1, (int)Math.round(rect[3] * viewport.getHeight())));
            params.leftMargin = viewportAt[0] - contentAt[0] + (int)Math.round(rect[0] * viewport.getWidth());
            params.topMargin = viewportAt[1] - contentAt[1] + (int)Math.round(rect[1] * viewport.getHeight());
            web.setLayoutParams(params);
        }
    }
    public void setPaused(boolean value) { activity.runOnUiThread(() -> { paused = value; applyState(); }); }
    public void sendInput(String event) {
        activity.runOnUiThread(() -> {
            if (web != null && !closed) web.evaluateJavascript("window.AetherTyranoHost?.input(" + event + ")", null);
        });
    }
    public void setControlsFrame(String frame) {
        activity.runOnUiThread(() -> {
            controlsJSON = frame;
            if (web != null && !closed) web.evaluateJavascript("window.AetherTyranoHost?.controls(" + frame + ")", null);
        });
    }
    private void applyState() {
        if (closed || web == null) return;
        boolean suspended = paused || inactive || !activity.hasWindowFocus();
        if (!suspended) web.onResume();
        web.evaluateJavascript("window.AetherTyranoHost?.controls(" + controlsJSON + ");window.AetherTyranoHost?.pause(" + suspended + ")", ignored -> {
            if (!closed && web != null && (paused || inactive || !activity.hasWindowFocus())) web.onPause();
        });
    }
    public void evaluate(String script) {
        activity.runOnUiThread(() -> {
            if (closed || web == null) return;
            web.evaluateJavascript(script, result -> {
                try { push("evaluation", new org.json.JSONTokener(result).nextValue()); }
                catch (Exception failure) { push("evaluation_error", failure.toString()); }
            });
        });
    }
    public void close() {
        closed = true;
        if (activity == null) return;
        activity.runOnUiThread(() -> {
            if (registered) { activity.getApplication().unregisterActivityLifecycleCallbacks(this); registered = false; }
            if (container != null) {
                container.removeOnLayoutChangeListener(layout);
                if (container.getViewTreeObserver().isAlive()) container.getViewTreeObserver().removeOnWindowFocusChangeListener(focus);
            }
            if (surface != null) surface.removeOnLayoutChangeListener(layout);
            for (JsResult result : dialogs) result.cancel();
            dialogs.clear();
            for (AlertDialog window : new ArrayList<>(dialogWindows)) window.dismiss();
            dialogWindows.clear();
            if (web != null) {
                if (web.getParent() instanceof ViewGroup) ((ViewGroup)web.getParent()).removeView(web);
                web.stopLoading(); web.setWebChromeClient(null); web.setWebViewClient(null); web.destroy(); web = null;
            }
        });
    }
    @Override public void onActivityPaused(Activity value) { if (value == activity) { inactive = true; applyState(); } }
    @Override public void onActivityResumed(Activity value) { if (value == activity) { inactive = false; applyState(); } }
    @Override public void onActivityDestroyed(Activity value) { if (value == activity) close(); }
    @Override public void onActivityCreated(Activity value, Bundle state) { }
    @Override public void onActivityStarted(Activity value) { }
    @Override public void onActivityStopped(Activity value) { }
    @Override public void onActivitySaveInstanceState(Activity value, Bundle state) { }
}
