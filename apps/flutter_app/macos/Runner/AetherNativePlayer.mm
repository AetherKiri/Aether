#import "AetherNativePlayer.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>

#include "aether/native_host/runtime_session.h"

#include <algorithm>
#include <chrono>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

FlutterError *PlayerError(NSString *message) {
    return [FlutterError errorWithCode:@"ons_player" message:message details:nil];
}

NSString *EngineError(engine_handle_t engine) {
    const char *message = engine_get_last_error(engine);
    if (message != nullptr && *message != '\0') {
        return [NSString stringWithUTF8String:message];
    }
    return @"The ONScripter session could not continue.";
}

void Complete(FlutterResult reply, id value) {
    dispatch_async(dispatch_get_main_queue(), ^{ reply(value); });
}

} // namespace

@implementation AetherNativePlayer {
    __weak NSObject<FlutterTextureRegistry> *_textures;
    FlutterMethodChannel *_channel;
    int64_t _textureId;

    // The serial queue owns the engine, clock, pool, and input dispatch.
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    aether::native_host::RuntimeSession _session;
    Clock::time_point _lastTick;
    Clock::time_point _startupDeadline;
    BOOL _active;
    BOOL _started;
    uint64_t _serial;

    uint32_t _width;
    uint32_t _height;
    CVPixelBufferPoolRef _pool;
    std::vector<uint8_t> _rgba;

    // Flutter acquires its own reference on the raster thread.
    NSLock *_frameLock;
    CVPixelBufferRef _frame;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    AetherNativePlayer *player = [[AetherNativePlayer alloc] init];
    NSObject<FlutterTextureRegistry> *textures = registrar.textures;
    player->_textures = textures;
    player->_channel = [FlutterMethodChannel methodChannelWithName:@"aether/ons_player"
                                                   binaryMessenger:registrar.messenger];
    player->_queue = dispatch_queue_create("org.github.krkr2.ons-player", DISPATCH_QUEUE_SERIAL);
    player->_frameLock = [[NSLock alloc] init];
    player->_active = NSApp.active;
    [registrar addMethodCallDelegate:player channel:player->_channel];

    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:player selector:@selector(activityChanged:)
                           name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [notifications addObserver:player selector:@selector(activityChanged:)
                           name:NSApplicationDidResignActiveNotification object:NSApp];
    [notifications addObserver:player selector:@selector(terminate:)
                           name:NSApplicationWillTerminateNotification object:NSApp];
}

- (CVPixelBufferRef)copyPixelBuffer {
    [_frameLock lock];
    CVPixelBufferRef frame = _frame ? CVPixelBufferRetain(_frame) : nullptr;
    [_frameLock unlock];
    return frame;
}

// Takes ownership of frame.
- (void)publishFrame:(CVPixelBufferRef)frame {
    [_frameLock lock];
    CVPixelBufferRef previous = _frame;
    _frame = frame;
    [_frameLock unlock];
    if (previous) {
        CVPixelBufferRelease(previous);
    }
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"chooseFolder"]) {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"Open ONScripter Game";
        panel.canChooseDirectories = YES;
        panel.canChooseFiles = NO;
        panel.allowsMultipleSelection = NO;
        void (^complete)(NSModalResponse) = ^(NSModalResponse response) {
            result(response == NSModalResponseOK ? panel.URL.path : nil);
        };
        if (NSWindow *window = NSApp.keyWindow) {
            [panel beginSheetModalForWindow:window completionHandler:complete];
        } else {
            [panel beginWithCompletionHandler:complete];
        }
    } else if ([call.method isEqualToString:@"open"]) {
        NSString *path = call.arguments;
        if (![path isKindOfClass:NSString.class] || path.length == 0) {
            result(PlayerError(@"Choose a game folder."));
            return;
        }
        if (_textureId == 0) {
            _textureId = [_textures registerTexture:self];
            if (_textureId == 0) {
                result(PlayerError(@"Could not register the game texture."));
                return;
            }
        }
        dispatch_async(_queue, ^{ [self open:path result:result]; });
    } else if ([call.method isEqualToString:@"close"]) {
        dispatch_async(_queue, ^{
            [self closeSession];
            Complete(result, nil);
        });
    } else if ([call.method isEqualToString:@"input"] &&
               [call.arguments isKindOfClass:NSDictionary.class]) {
        NSDictionary *input = call.arguments;
        dispatch_async(_queue, ^{
            [self sendInput:input];
            Complete(result, nil);
        });
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)open:(NSString *)path result:(FlutterResult)result {
    [self closeSession];
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [files URLsForDirectory:NSApplicationSupportDirectory
                                inDomains:NSUserDomainMask].firstObject;
    NSURL *storage = [root URLByAppendingPathComponent:@"Aether ONS Preview" isDirectory:YES];
    NSURL *cache = [storage URLByAppendingPathComponent:@"cache" isDirectory:YES];
    NSError *error = nil;
    if (![files createDirectoryAtURL:cache withIntermediateDirectories:YES
                         attributes:nil error:&error]) {
        Complete(result, PlayerError(error.localizedDescription));
        return;
    }

    NSString *storagePath = storage.path;
    NSString *cachePath = cache.path;
    NSString *font = [NSBundle.mainBundle pathForResource:@"aetherkiri-runtime-cjk" ofType:@"otf"];
    if (font.length == 0) {
        Complete(result, PlayerError(@"The bundled ONScripter font is missing."));
        return;
    }

    engine_create_desc_t description{};
    description.struct_size = sizeof(description);
    description.api_version = ENGINE_API_VERSION;
    description.writable_path_utf8 = storagePath.UTF8String;
    description.cache_path_utf8 = cachePath.UTF8String;
    if (_session.Create(description) != ENGINE_RESULT_OK) {
        Complete(result, PlayerError(EngineError(nullptr)));
        return;
    }

    auto engine = _session.handle();
    engine_option_t runtime{};
    runtime.key_utf8 = "runtime";
    runtime.value_utf8 = "onscripter";
    engine_option_t defaultFont{};
    defaultFont.key_utf8 = "default_font";
    defaultFont.value_utf8 = font.UTF8String;
    if (engine_set_option(engine, &runtime) != ENGINE_RESULT_OK ||
        engine_set_option(engine, &defaultFont) != ENGINE_RESULT_OK ||
        engine_open_game_async(engine, path.UTF8String, nullptr) != ENGINE_RESULT_OK) {
        FlutterError *failure = PlayerError(EngineError(engine));
        [self closeSession];
        Complete(result, failure);
        return;
    }

    _lastTick = Clock::now();
    _startupDeadline = _lastTick + std::chrono::seconds(30);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_MSEC);
    __weak AetherNativePlayer *player = self;
    dispatch_source_set_event_handler(_timer, ^{ [player tick]; });
    Complete(result, @{@"textureId": @(_textureId),
                       @"title": path.lastPathComponent});
    dispatch_resume(_timer);
}

- (void)closeSession {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    _session.Close();
    [self publishFrame:nullptr];
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = nullptr;
    }
    _rgba = std::vector<uint8_t>();
    _started = NO;
    _serial = 0;
    _width = 0;
    _height = 0;
}

- (void)failSession:(NSString *)message {
    [self closeSession];
    dispatch_async(dispatch_get_main_queue(), ^{ [self->_channel invokeMethod:@"ended" arguments:message]; });
}

- (void)activityChanged:(NSNotification *)notification {
    const BOOL active = [notification.name isEqualToString:NSApplicationDidBecomeActiveNotification];
    dispatch_async(_queue, ^{
        self->_active = active;
        self->_lastTick = Clock::now();
        if (self->_started) {
            if (active) {
                engine_resume(self->_session.handle());
            } else {
                engine_pause(self->_session.handle());
            }
        }
    });
}

- (void)terminate:(NSNotification *)notification {
    dispatch_sync(_queue, ^{ [self closeSession]; });
    if (_textureId != 0) {
        [_textures unregisterTexture:_textureId];
    }
}

- (void)sendInput:(NSDictionary *)input {
    if (!_started || !_active) {
        return;
    }
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = [input[@"type"] unsignedIntValue];
    event.key_code = [input[@"key"] intValue];
    event.x = [input[@"x"] doubleValue];
    event.y = [input[@"y"] doubleValue];
    event.delta_y = [input[@"scroll"] doubleValue];
    event.button = [input[@"button"] intValue];
    event.pointer_id = [input[@"pointer"] intValue];
    if ([input[@"cancelled"] boolValue]) {
        event.modifiers = ENGINE_INPUT_MODIFIER_POINTER_CANCEL;
    }
    engine_send_input(_session.handle(), &event);
}

- (void)tick {
    auto engine = _session.handle();
    if (engine == nullptr) {
        return;
    }
    if (!_started) {
        uint32_t startup;
        if (engine_get_startup_state(engine, &startup) != ENGINE_RESULT_OK ||
            startup == ENGINE_STARTUP_STATE_FAILED) {
            [self failSession:EngineError(engine)];
            return;
        }
        if (startup != ENGINE_STARTUP_STATE_SUCCEEDED) {
            if (Clock::now() > _startupDeadline) {
                [self failSession:@"Opening the game took too long."];
            }
            return;
        }
        _started = YES;
        if (!_active) {
            engine_pause(engine);
        }
    }
    if (!_active) {
        return;
    }

    const auto now = Clock::now();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - _lastTick).count();
    _lastTick = now;
    if (engine_tick(engine, static_cast<uint32_t>(std::min<int64_t>(elapsed, 100))) != ENGINE_RESULT_OK) {
        [self failSession:EngineError(engine)];
        return;
    }
    [self readFrame:engine];
}

- (void)readFrame:(engine_handle_t)engine {
    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    if (engine_get_frame_desc(engine, &frame) != ENGINE_RESULT_OK ||
        frame.width == 0 || frame.height == 0 ||
        frame.pixel_format != ENGINE_PIXEL_FORMAT_RGBA8888 ||
        frame.stride_bytes < static_cast<size_t>(frame.width) * 4 ||
        (_serial && _serial == frame.frame_serial)) {
        return;
    }

    const BOOL resized = frame.width != _width || frame.height != _height;
    if (resized || _pool == nullptr) {
        if (_pool) {
            CVPixelBufferPoolRelease(_pool);
            _pool = nullptr;
        }
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferWidthKey: @(frame.width),
            (__bridge NSString *)kCVPixelBufferHeightKey: @(frame.height),
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        if (CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)attributes, &_pool) !=
            kCVReturnSuccess) {
            [self failSession:@"Could not create the game frame buffer pool."];
            return;
        }
    }

    CVPixelBufferRef pixels = nullptr;
    NSDictionary *limit = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @3};
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            nullptr, _pool, (__bridge CFDictionaryRef)limit, &pixels) != kCVReturnSuccess) {
        return;
    }
    _rgba.resize(static_cast<size_t>(frame.stride_bytes) * frame.height);
    if (engine_read_frame_rgba(engine, _rgba.data(), _rgba.size()) != ENGINE_RESULT_OK ||
        CVPixelBufferLockBaseAddress(pixels, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pixels);
        return;
    }
    auto *destination = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pixels));
    const size_t destinationStride = CVPixelBufferGetBytesPerRow(pixels);
    for (uint32_t y = 0; y < frame.height; ++y) {
        const uint8_t *src = _rgba.data() + static_cast<size_t>(y) * frame.stride_bytes;
        uint8_t *dst = destination + static_cast<size_t>(y) * destinationStride;
        for (uint32_t x = 0; x < frame.width; ++x, src += 4, dst += 4) {
            dst[0] = src[2];
            dst[1] = src[1];
            dst[2] = src[0];
            dst[3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, 0);

    _width = frame.width;
    _height = frame.height;
    _serial = frame.frame_serial;
    [self publishFrame:pixels];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_textures textureFrameAvailable:self->_textureId];
        if (resized) {
            [self->_channel invokeMethod:@"frameSize" arguments:@{
                @"width": @(frame.width), @"height": @(frame.height),
            }];
        }
    });
}

@end
