(() => {
    "use strict";
    const post = (type, value) => {
        if (window.webkit?.messageHandlers?.aetherTyrano) {
            window.webkit.messageHandlers.aetherTyrano.postMessage({type, value});
        } else nativePrompt("__AETHER_TYRANO_EVENT__", JSON.stringify({type, value}));
    };
    // Custom-scheme pages do not have a portable Web Storage origin. Keep the
    // synchronous Storage contract, with native atomic persistence per game.
    const nativePrompt = window.prompt.bind(window);
    const currentStorage = nativePrompt("__AETHER_TYRANO_STORAGE_READ__", "");
    const values = Object.assign(Object.create(null), currentStorage === null ? __AETHER_STORAGE__ : JSON.parse(currentStorage));
    const storage = persistent => {
        const data = persistent ? values : Object.create(null);
        const publish = () => {
            if (!persistent) return;
            const error = nativePrompt("__AETHER_TYRANO_STORAGE__", JSON.stringify(data));
            if (error !== null) throw new DOMException(error, "UnknownError");
        };
        const methods = {
            getItem: key => Object.hasOwn(data, String(key)) ? data[String(key)] : null,
            setItem(key, value) {
                key = String(key); value = String(value);
                const previous = data[key]; const existed = Object.hasOwn(data, key);
                data[key] = value;
                if (Object.keys(data).length > 1024 || JSON.stringify(data).length > 16 * 1024 * 1024) {
                    if (existed) data[key] = previous; else delete data[key];
                    throw new DOMException("Game storage is full", "QuotaExceededError");
                }
                try { publish(); }
                catch (error) { if (existed) data[key] = previous; else delete data[key]; throw error; }
            },
            removeItem(key) {
                key = String(key); if (!Object.hasOwn(data, key)) return;
                const old = data[key]; delete data[key];
                try { publish(); } catch (error) { data[key] = old; throw error; }
            },
            clear() {
                const old = {...data}; for (const key of Object.keys(data)) delete data[key];
                try { publish(); } catch (error) { Object.assign(data, old); throw error; }
            },
            key: index => Object.keys(data)[Number(index)] ?? null,
        };
        return new Proxy(methods, {
            get(target, key) {
                if (key === "length") return Object.keys(data).length;
                if (key in target) return target[key];
                return typeof key === "string" && Object.hasOwn(data, key) ? data[key] : undefined;
            },
            set(_, key, value) { methods.setItem(key, value); return true; },
            deleteProperty(_, key) { methods.removeItem(key); return true; },
            ownKeys: () => Object.keys(data),
            getOwnPropertyDescriptor: (_, key) => Object.hasOwn(data, key)
                ? {value: data[key], enumerable: true, configurable: true} : undefined,
        });
    };
    Object.defineProperty(window, "localStorage", {value: storage(true)});
    Object.defineProperty(window, "sessionStorage", {value: storage(false)});

    // Electron exports select file saves in Config.tjs. Switch after config
    // loading but before init_game reads the first system variables; waiting
    // until the ready event is too late for desktop-only storage code.
    document.addEventListener("DOMContentLoaded", () => {
        const kag = window.tyrano?.plugin?.kag;
        if (typeof kag?.init_game !== "function") return;
        const initialize = kag.init_game;
        kag.init_game = function (...args) {
            this.config.configSave = "webstorage";
            return initialize.apply(this, args);
        };
    }, {once: true});

    // Pause JS timers as well as media when the app leaves the foreground.
    const nativeTimeout = window.setTimeout.bind(window);
    const nativeClear = window.clearTimeout.bind(window);
    const timers = new Map(); let nextTimer = 1; let paused = false;
    function schedule(timer, delay) {
        timer.remaining = delay; timer.due = performance.now() + delay;
        if (paused) return;
        timer.native = nativeTimeout(() => {
            if (!timers.has(timer.id)) return;
            if (!timer.interval) timers.delete(timer.id);
            try { timer.callback.apply(window, timer.args); }
            finally { if (timer.interval && timers.has(timer.id)) schedule(timer, timer.delay); }
        }, delay);
    }
    function addTimer(callback, delay, interval, args) {
        const timer = {id: nextTimer++, callback: typeof callback === "function" ? callback
            : () => (0, eval)(String(callback)), delay: Math.max(interval ? 1 : 0, Number(delay) || 0), interval, args};
        timers.set(timer.id, timer); schedule(timer, timer.delay); return timer.id;
    }
    window.setTimeout = (callback, delay, ...args) => addTimer(callback, delay, false, args);
    window.setInterval = (callback, delay, ...args) => addTimer(callback, delay, true, args);
    window.clearTimeout = window.clearInterval = id => {
        const timer = timers.get(id);
        if (timer) { nativeClear(timer.native); timers.delete(id); }
    };
    const nativeRAF = window.requestAnimationFrame.bind(window);
    const nativeCancelRAF = window.cancelAnimationFrame.bind(window);
    const frames = new Map(); let nextFrame = 1;
    const scheduleFrame = frame => {
        if (!paused) frame.native = nativeRAF(time => { frames.delete(frame.id); frame.callback(time); });
    };
    window.requestAnimationFrame = callback => {
        const frame = {id: nextFrame++, callback}; frames.set(frame.id, frame); scheduleFrame(frame); return frame.id;
    };
    window.cancelAnimationFrame = id => {
        const frame = frames.get(id); if (frame) { nativeCancelRAF(frame.native); frames.delete(id); }
    };
    const audioContexts = new Set();
    for (const name of ["AudioContext", "webkitAudioContext"]) {
        if (window[name]) window[name] = new Proxy(window[name], {
            construct(target, args, type) {
                const context = Reflect.construct(target, args, type);
                audioContexts.add(context);
                if (paused) context.suspend().catch(() => {});
                return context;
            },
        });
    }
    let animations = []; const held = new Map(); let playingMedia = []; let playingContexts = [];
    let virtualKeyDepth = 0;
    function hasLegacyTap(jq, element) {
        // Tyrano's mobile adapter aliases $.fn.click to $.fn.tap, but its
        // keyboard actions still dispatch "click". Translate only those
        // virtual-key clicks whose target actually has a legacy tap handler.
        return jq && typeof jq.fn.tap === "function" && jq.fn.click === jq.fn.tap &&
            typeof jq._data === "function" && jq._data(element, "events")?.tap;
    }
    document.addEventListener("click", event => {
        if (!virtualKeyDepth || event.isTrusted || !hasLegacyTap(window.jQuery, event.target)) return;
        event.preventDefault(); event.stopImmediatePropagation();
        window.jQuery(event.target).trigger("tap");
    }, true);
    function key(code, pressed) {
        const names = {13: "Enter", 27: "Escape", 32: " ", 17: "Control", 33: "PageUp", 34: "PageDown",
            37: "ArrowLeft", 38: "ArrowUp", 39: "ArrowRight", 40: "ArrowDown"};
        const event = new KeyboardEvent(pressed ? "keydown" : "keyup", {
            key: names[code] || String.fromCharCode(code), code: code === 32 ? "Space" : names[code],
            bubbles: true, cancelable: true, ctrlKey: code === 17 ? pressed : held.has(17),
        });
        Object.defineProperty(event, "keyCode", {get: () => code});
        Object.defineProperty(event, "which", {get: () => code});
        if (pressed) held.set(code, true); else held.delete(code);
        const jq = window.jQuery;
        const trigger = jq?.fn.trigger;
        const translate = function(type, ...args) {
            if (type !== "click") return trigger.call(this, type, ...args);
            return this.each(function() { trigger.call(jq(this), hasLegacyTap(jq, this) ? "tap" : type, ...args); });
        };
        if (jq && typeof jq.fn.tap === "function" && jq.fn.click === jq.fn.tap) jq.fn.trigger = translate;
        virtualKeyDepth++;
        try { (document.activeElement || document.body || document).dispatchEvent(event); }
        finally {
            virtualKeyDepth--;
            if (jq?.fn.trigger === translate) jq.fn.trigger = trigger;
        }
    }
    function releaseKeys() { for (const code of Array.from(held.keys())) key(code, false); }
    let panel;
    function controls(visible) {
        if (!panel) {
            panel = document.createElement("div");
            panel.id = "aether-tyrano-controls";
            panel.style.cssText = "position:fixed;inset:auto 8px 8px auto;z-index:2147483647;";
            // Mobile engines also listen for document-level touch gestures.
            // A virtual key must not become a second game tap or swipe.
            for (const name of ["touchstart", "touchmove", "touchend", "touchcancel", "mousedown", "mouseup", "click", "contextmenu", "wheel"]) {
                panel.addEventListener(name, event => { event.preventDefault(); event.stopPropagation(); }, {passive: false});
            }
            const shadow = panel.attachShadow({mode: "closed"});
            shadow.innerHTML = `<style>:host{font:16px sans-serif}div{display:flex;gap:6px;flex-wrap:wrap;max-width:340px}
                button{touch-action:none;min-width:44px;min-height:44px;background:#242833d9;color:white;border:1px solid #aab0c0;border-radius:24px}
                button:active{background:#465bca}</style><div></div>`;
            const row = shadow.querySelector("div");
            for (const [label, code] of [["Esc",27],["Ctrl",17],["↑",38],["↓",40],["←",37],["→",39],["PgUp",33],["PgDn",34],["Space",32],["Enter",13]]) {
                const button = document.createElement("button"); button.textContent = label;
                button.addEventListener("pointerdown", event => {
                    event.preventDefault(); event.stopPropagation(); button.setPointerCapture(event.pointerId); key(code, true);
                });
                for (const name of ["pointerup", "pointercancel", "lostpointercapture"]) {
                    button.addEventListener(name, event => { event.preventDefault(); event.stopPropagation(); if (held.has(code)) key(code, false); });
                }
                row.append(button);
            }
            document.documentElement.append(panel);
        }
        panel.style.display = visible ? "block" : "none";
        if (!visible) releaseKeys();
    }
    window.AetherTyranoHost = Object.freeze({
        controls, key,
        pause(value) {
            value = !!value; if (paused === value) return;
            paused = value; releaseKeys();
            if (value) {
                for (const frame of frames.values()) nativeCancelRAF(frame.native);
                for (const timer of timers.values()) {
                    nativeClear(timer.native); timer.remaining = Math.max(0, timer.due - performance.now());
                }
                animations = document.getAnimations().filter(animation => animation.playState === "running");
                for (const animation of animations) animation.pause();
                playingMedia = Array.from(document.querySelectorAll("audio,video")).filter(media => !media.paused);
                for (const media of playingMedia) media.pause();
                playingContexts = Array.from(audioContexts).filter(context => context.state === "running");
                for (const context of playingContexts) context.suspend().catch(() => {});
            } else {
                for (const frame of frames.values()) scheduleFrame(frame);
                for (const timer of timers.values()) schedule(timer, timer.remaining);
                for (const animation of animations) animation.play();
                animations = [];
                for (const media of playingMedia) media.play().catch(() => {});
                playingMedia = [];
                for (const context of playingContexts) context.resume().catch(() => {});
                playingContexts = [];
            }
        },
    });
    window.close = () => post("close", "");
    window.addEventListener("blur", releaseKeys);
    window.addEventListener("error", event => {
        if (event.message) post("log", `${event.message} (${event.filename}:${event.lineno})`);
    });
    function ready() {
        const kag = window.TYRANO && TYRANO.kag;
        if (kag && kag.config && kag.config.projectID && kag.ftag && kag.ftag.array_tag && kag.ftag.array_tag.length) {
            // Desktop exports may request Node-backed saves. Browser hosting
            // always uses the persistent Storage adapter, without rewriting files.
            kag.config.configSave = "webstorage";
            post("ready", kag.config["System.title"] || document.title);
        } else nativeTimeout(ready, 50);
    }
    window.addEventListener("DOMContentLoaded", () => nativeTimeout(ready, 50), {once: true});
})();
