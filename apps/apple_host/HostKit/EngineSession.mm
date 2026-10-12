#import "EngineSession.h"
#import "MetalBridge.h"

#include "engine_api.h"
#include "engine_runtime_provider.h"

#include <vector>
#include <algorithm>
#include <chrono>

namespace {

NSError *EngineError(engine_handle_t handle, NSString *fallback) {
    NSString *message = fallback;
    if (handle != nullptr) {
        const char *last = engine_get_last_error(handle);
        if (last != nullptr && last[0] != '\0') {
            message = [NSString stringWithUTF8String:last];
        }
    }
    return [NSError errorWithDomain:@"AetherEngineSession"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

}  // namespace

@implementation AetherEngineSession {
    engine_handle_t _handle;
    std::vector<uint8_t> _frameBuffer;
    CGSize _framePixelSize;
    BOOL _metalRendererEnabled;
    uint64_t _renderGeneration;
    uint64_t _nativeReadbacks;
    uint64_t _nativeCopies;
    BOOL _asyncSnapshots;
    BOOL _profileNativeStages;
    uint64_t _nativeGetCalls, _nativeSnapshotCalls;
    double _nativeGetMS, _nativeGetMaxMS, _nativeSnapshotMS, _nativeSnapshotMaxMS;
    uint64_t _nativePublishedSerial;
}

+ (int32_t)probeRuntimeProvider:(NSString *)runtimeId path:(NSString *)gameRootPath {
    return engine_probe_runtime_provider(runtimeId.UTF8String, gameRootPath.fileSystemRepresentation);
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _handle = nullptr;
        NSDictionary *env = NSProcessInfo.processInfo.environment;
        _asyncSnapshots = [env[@"AETHER_HOST_ASYNC_SNAPSHOT"] isEqualToString:@"1"];
        _profileNativeStages = [env[@"AETHER_HOST_PROFILE"] isEqualToString:@"1"];
        _nativePublishedSerial = 0;
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (BOOL)initializeWithWritablePath:(NSString *)writablePath
                         cachePath:(NSString *)cachePath
                             error:(NSError **)error {
    if (_handle != nullptr) {
        return YES;
    }
    engine_create_desc_t desc{};
    desc.struct_size = sizeof(desc);
    desc.api_version = ENGINE_API_VERSION;
    desc.writable_path_utf8 = writablePath.fileSystemRepresentation;
    desc.cache_path_utf8 = cachePath.fileSystemRepresentation;

    engine_handle_t handle = nullptr;
    const engine_result_t result = engine_create(&desc, &handle);
    if (result != ENGINE_RESULT_OK || handle == nullptr) {
        if (error != nullptr) {
            *error = EngineError(handle, @"engine_create failed");
        }
        return NO;
    }
    _handle = handle;
    return YES;
}

- (BOOL)setOption:(NSString *)key value:(NSString *)value error:(NSError **)error {
    if (_handle == nullptr) {
        if (error != nullptr) {
            *error = EngineError(nullptr, @"engine is not initialized");
        }
        return NO;
    }
    engine_option_t option{};
    option.key_utf8 = key.UTF8String;
    option.value_utf8 = value.UTF8String;
    const engine_result_t result = engine_set_option(_handle, &option);
    if (result != ENGINE_RESULT_OK) {
        if (error != nullptr) {
            NSError *detail = EngineError(_handle, @"engine_set_option failed");
            *error = [NSError errorWithDomain:@"AetherEngineOption" code:result userInfo:detail.userInfo];
        }
        return NO;
    }
    return YES;
}

- (engine_handle_t)borrowedEngineHandle { return _handle; }

- (uint32_t)engineAPIVersion {
    return ENGINE_API_VERSION;
}

- (BOOL)isTextTranslationAvailable {
    return engine_is_text_translation_available() != 0;
}

- (NSString *)rendererInfo {
    if (_handle == nullptr) return @"";
    char buffer[512] = {};
    if (engine_get_renderer_info(_handle, buffer, sizeof(buffer)) != ENGINE_RESULT_OK) return @"";
    return [NSString stringWithUTF8String:buffer] ?: @"";
}

- (nullable NSDictionary<NSString *, NSNumber *> *)memoryStats {
    if (_handle == nullptr) return nil;
    engine_memory_stats_t stats{};
    stats.struct_size = sizeof(stats);
    if (engine_get_memory_stats(_handle, &stats) != ENGINE_RESULT_OK) return nil;
    return @{
        @"selfUsedMB" : @(stats.self_used_mb),
        @"systemFreeMB" : @(stats.system_free_mb),
        @"systemTotalMB" : @(stats.system_total_mb),
        @"graphicCacheBytes" : @(stats.graphic_cache_bytes),
        @"graphicCacheLimitBytes" : @(stats.graphic_cache_limit_bytes),
        @"xp3SegmentCacheBytes" : @(stats.xp3_segment_cache_bytes),
        @"psbCacheBytes" : @(stats.psb_cache_bytes),
        @"psbCacheEntries" : @(stats.psb_cache_entries),
        @"psbCacheEntryLimit" : @(stats.psb_cache_entry_limit),
        @"psbCacheHits" : @(stats.psb_cache_hits),
        @"psbCacheMisses" : @(stats.psb_cache_misses),
        @"archiveCacheEntries" : @(stats.archive_cache_entries),
        @"archiveCacheLimit" : @(stats.archive_cache_limit),
        @"autopathCacheEntries" : @(stats.autopath_cache_entries),
        @"autopathCacheLimit" : @(stats.autopath_cache_limit),
        @"autopathTableEntries" : @(stats.autopath_table_entries),
        @"processResidentBytes" : @(stats.process_resident_bytes),
        @"processPhysicalFootprintBytes" : @(stats.process_physical_footprint_bytes),
        @"processPeakPhysicalFootprintBytes" : @(stats.process_peak_physical_footprint_bytes),
        @"processAvailableBytes" : @(stats.process_available_bytes),
    };
}

- (uint32_t)textTranslationState {
    return engine_get_text_translation_state();
}

- (nullable NSDictionary<NSString *, NSNumber *> *)textTranslationStats {
    engine_text_translation_stats_t stats{};
    stats.struct_size = sizeof(stats);
    if (engine_get_text_translation_stats(&stats) != ENGINE_RESULT_OK) {
        return nil;
    }
    return @{
        @"state" : @(stats.state),
        @"backend" : @(stats.backend),
        @"activeJobs" : @(stats.active_jobs),
        @"modelFileBytes" : @(stats.model_file_bytes),
        @"translationsCompleted" : @(stats.translations_completed),
        @"translationsFailed" : @(stats.translations_failed),
        @"cacheHits" : @(stats.cache_hits),
        @"cacheMisses" : @(stats.cache_misses),
        @"modelLoadMicroseconds" : @(stats.model_load_us),
        @"lastInferenceMicroseconds" : @(stats.last_inference_us),
        @"maxInferenceMicroseconds" : @(stats.max_inference_us),
    };
}

- (NSDictionary<NSString *, NSNumber *> *)textInputState {
    NSDictionary<NSString *, NSNumber *> *unavailable = @{
        @"available" : @NO,
        @"imeActive" : @NO,
        @"imeMode" : @0,
        @"attentionValid" : @NO,
        @"attentionX" : @0,
        @"attentionY" : @0,
        @"textAvailable" : @NO,
        @"textBytes" : @0,
        @"selectionStart" : @0,
        @"selectionEnd" : @0,
    };
    if (!_handle) return unavailable;
    engine_text_input_state_t state{};
    state.struct_size = sizeof(state);
    if (engine_get_text_input_state(_handle, &state) != ENGINE_RESULT_OK) {
        return unavailable;
    }
    return @{
        @"available" : @YES,
        @"imeActive" : @(state.ime_active != 0),
        @"imeMode" : @(state.ime_mode),
        @"attentionValid" : @(state.attention_point_valid != 0),
        @"attentionX" : @(state.attention_x),
        @"attentionY" : @(state.attention_y),
        @"textAvailable" : @(state.text_available != 0),
        @"textBytes" : @(state.text_utf8_bytes),
        @"selectionStart" : @(state.selection_start),
        @"selectionEnd" : @(state.selection_end),
    };
}

- (NSString *)copyTextInputText {
    if (!_handle) return @"";
    engine_text_input_state_t state{};
    state.struct_size = sizeof(state);
    if (engine_get_text_input_state(_handle, &state) != ENGINE_RESULT_OK ||
        state.text_available == 0 || state.text_utf8_bytes == 0) {
        return @"";
    }
    std::vector<char> buffer(static_cast<size_t>(state.text_utf8_bytes) + 1u, '\0');
    uint32_t bytes_written = 0;
    if (engine_copy_text_input_text(_handle, buffer.data(),
                                    static_cast<uint32_t>(buffer.size()),
                                    &bytes_written) != ENGINE_RESULT_OK) {
        return @"";
    }
    return [NSString stringWithUTF8String:buffer.data()] ?: @"";
}

- (BOOL)sendTextInput:(NSString *)text error:(NSError **)error {
    if (!_handle) {
        if (error) *error = EngineError(nullptr, @"engine is not initialized");
        return NO;
    }
    for (NSUInteger index = 0; index < text.length; ) {
        const uint32_t codepoint = [text characterAtIndex:index];
        if (codepoint >= 0xD800 && codepoint <= 0xDBFF && index + 1 < text.length) {
            const uint32_t low = [text characterAtIndex:index + 1];
            if (low >= 0xDC00 && low <= 0xDFFF) {
                const uint32_t scalar =
                    0x10000u + ((codepoint - 0xD800u) << 10) + (low - 0xDC00u);
                if (![self sendTextCodepoint:scalar error:error]) return NO;
                index += 2;
                continue;
            }
        }
        index += 1;
        // Host-side filter mirroring the Godot shell: NUL/CR/LF are dropped.
        if (codepoint == 0 || codepoint == '\r' || codepoint == '\n') continue;
        if (![self sendTextCodepoint:codepoint error:error]) return NO;
    }
    return YES;
}

- (BOOL)sendIMEPreedit:(nullable NSString *)text
           cursorStart:(int32_t)cursorStart
          cursorLength:(int32_t)cursorLength
                 error:(NSError **)error {
    // Option order mirrors the Godot player's send_ime_preedit().
    NSString *cursor = [NSString stringWithFormat:@"%d,%d", cursorStart, cursorLength];
    if (![self setOption:@"ime_preedit_cursor" value:cursor error:error]) return NO;
    return [self setOption:@"ime_preedit" value:(text ?: @"") error:error];
}

- (BOOL)enableMetalRenderer:(NSError **)error {
    if (!AetherMetalBridgeInitialize(error)) return NO;
    if (!_renderGeneration) {
        _renderGeneration = AetherMetalBridgeBeginSession();
        if (!_renderGeneration) {
            if (error) *error = EngineError(nullptr, @"another native render session is active");
            return NO;
        }
        _nativePublishedSerial = 0;
    }
    if (![self setOption:@"renderer" value:@"godot_native" error:error]) return NO;
    _metalRendererEnabled = YES;
    // Bootstrap Game Native dimensions from raw output. The controller sets
    // surface size to this first frame, then returns to surface publication.
    return [self setOption:@"frame_output" value:@"raw_source" error:error];
}

- (nullable id<MTLTexture>)copyNativeFrameTexture {
    if (!_handle) return nil;
    uint64_t token = 0, serial = 0;
    uint32_t width = 0, height = 0;
    auto started = _profileNativeStages ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    auto result = engine_get_godot_native_frame_texture(_handle, &token, &width, &height, &serial);
    if (_profileNativeStages) {
        double elapsed = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
        ++_nativeGetCalls; _nativeGetMS += elapsed; _nativeGetMaxMS = std::max(_nativeGetMaxMS,elapsed);
    }
    if (result != ENGINE_RESULT_OK || !token) return nil;
    if (_profileNativeStages) started = std::chrono::steady_clock::now();
    id<MTLTexture> texture = _asyncSnapshots ? AetherMetalBridgeCopyPresentationTexture(token) : AetherMetalBridgeCopyTexture(token);
    if (_profileNativeStages) {
        double elapsed = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
        ++_nativeSnapshotCalls; _nativeSnapshotMS += elapsed; _nativeSnapshotMaxMS = std::max(_nativeSnapshotMaxMS,elapsed);
    }
    if (texture) {
        _framePixelSize = CGSizeMake(width, height);
        ++_nativeCopies;
    }
    return texture;
}

- (nullable AetherMetalFrameLease *)acquireNativeFrame {
    if(!_handle || !_renderGeneration)return nil;
    AetherMetalFrameLease *frame=AetherMetalBridgeAcquirePublishedFrame(
        _renderGeneration, _nativePublishedSerial);
    if(frame) {
        _nativePublishedSerial = frame.serial;
        _framePixelSize=CGSizeMake(frame.texture.width,frame.texture.height);
    }
    return frame;
}

- (NSString *)metalBridgeDiagnostics {
    return [NSString stringWithFormat:@"%@ native_copies=%llu native_readbacks=%llu native_get_calls=%llu native_get_total_ms=%.6f native_get_max_ms=%.6f native_snapshot_calls=%llu native_snapshot_total_ms=%.6f native_snapshot_max_ms=%.6f",
        AetherMetalBridgeDiagnostics(), _nativeCopies, _nativeReadbacks,
        _nativeGetCalls,_nativeGetMS,_nativeGetMaxMS,_nativeSnapshotCalls,_nativeSnapshotMS,_nativeSnapshotMaxMS];
}

- (BOOL)openGameAtPath:(NSString *)gamePath error:(NSError **)error {
    if (_handle == nullptr) {
        if (error != nullptr) {
            *error = EngineError(nullptr, @"engine is not initialized");
        }
        return NO;
    }
    const engine_result_t result =
        engine_open_game(_handle, gamePath.fileSystemRepresentation, nullptr);
    if (result != ENGINE_RESULT_OK) {
        if (error != nullptr) {
            *error = EngineError(_handle, @"engine_open_game failed");
        }
        return NO;
    }
    return YES;
}

- (NSString *)lastError {
    const char *message = _handle ? engine_get_last_error(_handle) : nullptr;
    return message ? ([NSString stringWithUTF8String:message] ?: @"") : @"";
}

- (NSString *)drainStartupLogs {
    if (!_handle) return @"";
    char buffer[65536] = {};
    uint32_t written = 0;
    engine_drain_startup_logs(_handle, buffer, sizeof(buffer), &written);
    return [[NSString alloc] initWithBytes:buffer length:std::min(written, (uint32_t)sizeof(buffer))
                                encoding:NSUTF8StringEncoding] ?: @"";
}

- (uint32_t)startupState {
    if (_handle == nullptr) {
        return ENGINE_STARTUP_STATE_IDLE;
    }
    uint32_t state = ENGINE_STARTUP_STATE_IDLE;
    if (engine_get_startup_state(_handle, &state) != ENGINE_RESULT_OK) {
        return ENGINE_STARTUP_STATE_IDLE;
    }
    return state;
}

- (void)tickWithDeltaMS:(uint32_t)deltaMS {
    if (_handle == nullptr) {
        return;
    }
    engine_tick(_handle, deltaMS);
}

- (BOOL)lastTickRenderedFrame {
    if (_handle == nullptr) {
        return NO;
    }
    uint32_t rendered = 0;
    if (engine_get_frame_rendered_flag(_handle, &rendered) != ENGINE_RESULT_OK) {
        // Optional query: preserve frame updates for older providers.
        return YES;
    }
    return rendered != 0;
}

- (BOOL)submitPlatformResponse:(NSString *)operation argument:(NSString *)argument error:(NSError **)error {
    if (!_handle) {
        if (error) *error = EngineError(nullptr, @"engine is not initialized");
        return NO;
    }
    if (engine_submit_platform_response(_handle, operation.UTF8String, argument.UTF8String) != ENGINE_RESULT_OK) {
        if (error) *error = EngineError(_handle, @"platform response failed");
        return NO;
    }
    return YES;
}

- (void)pollPlatformRequests:(void (^)(NSString *, NSString *))handler {
    if (_handle == nullptr) {
        return;
    }
    char operation[256] = {0};
    char argument[4096] = {0};
    for (size_t count = 0; count < 256; ++count) {
        uint32_t available = 0;
        const engine_result_t result = engine_poll_platform_request(
            _handle, operation, sizeof(operation), argument, sizeof(argument),
            &available);
        if (result != ENGINE_RESULT_OK || available == 0) {
            return;
        }
        handler([NSString stringWithUTF8String:operation],
                [NSString stringWithUTF8String:argument]);
    }
}

- (nullable CGImageRef)copyFrameImage CF_RETURNS_RETAINED {
    if (_handle == nullptr) {
        return nil;
    }
    engine_frame_desc_t desc{};
    desc.struct_size = sizeof(desc);
    uint64_t nativeToken = 0, serial = 0;
    if (_metalRendererEnabled) {
        engine_get_godot_native_frame_texture(_handle, &nativeToken, &desc.width, &desc.height, &serial);
    }
    if (nativeToken) {
        desc.stride_bytes = desc.width * 4;
        desc.pixel_format = ENGINE_PIXEL_FORMAT_RGBA8888;
    } else if (engine_get_frame_desc(_handle, &desc) != ENGINE_RESULT_OK ||
               desc.width == 0 || desc.height == 0 ||
               desc.pixel_format != ENGINE_PIXEL_FORMAT_RGBA8888) {
        return nil;
    }
    _framePixelSize = CGSizeMake(desc.width, desc.height);
    const size_t byteCount =
        static_cast<size_t>(desc.stride_bytes) * desc.height;
    if (_frameBuffer.size() != byteCount) {
        _frameBuffer.resize(byteCount);
    }
    if (nativeToken) {
        if (!AetherMetalBridgeReadTexture(nativeToken, _frameBuffer.data(), _frameBuffer.size(), desc.stride_bytes)) return nil;
        ++_nativeReadbacks;
    } else if (engine_read_frame_rgba(_handle, _frameBuffer.data(), _frameBuffer.size()) != ENGINE_RESULT_OK) {
        return nil;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == nullptr) {
        return nil;
    }
    CGContextRef context = CGBitmapContextCreate(
        _frameBuffer.data(), desc.width, desc.height, 8, desc.stride_bytes,
        colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    CGColorSpaceRelease(colorSpace);
    if (context == nullptr) {
        return nil;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

- (void)sendPointerEventWithType:(uint32_t)type
                       pointerId:(int32_t)pointerId
                               x:(double)x
                               y:(double)y
                          deltaX:(double)deltaX
                          deltaY:(double)deltaY
                          button:(int32_t)button
                       modifiers:(int32_t)modifiers {
    if (_handle == nullptr) {
        return;
    }
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = type;
    event.x = x;
    event.y = y;
    event.delta_x = deltaX;
    event.delta_y = deltaY;
    event.pointer_id = pointerId;
    event.button = button;
    event.modifiers = modifiers;
    engine_send_input(_handle, &event);
}

- (void)sendKeyEvent:(BOOL)pressed
             keyCode:(int32_t)keyCode
           modifiers:(int32_t)modifiers
             unicode:(uint32_t)unicode {
    if (_handle == nullptr) {
        return;
    }
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = pressed ? ENGINE_INPUT_EVENT_KEY_DOWN : ENGINE_INPUT_EVENT_KEY_UP;
    event.key_code = keyCode;
    event.modifiers = modifiers;
    event.unicode_codepoint = pressed ? unicode : 0;
    engine_result_t result = engine_send_input(_handle, &event);
    // KAG edit controls receive printable characters through a distinct
    // text-input event (mirrors the Godot host contract).
    if (pressed && result == ENGINE_RESULT_OK && unicode > 0) {
        event.type = ENGINE_INPUT_EVENT_TEXT_INPUT;
        engine_send_input(_handle, &event);
    }
}

- (BOOL)sendTextCodepoint:(uint32_t)codepoint error:(NSError **)error {
    if (!_handle) {
        if (error) *error = EngineError(nullptr, @"engine is not initialized");
        return NO;
    }
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = ENGINE_INPUT_EVENT_TEXT_INPUT;
    event.unicode_codepoint = codepoint;
    if (engine_send_input(_handle, &event) != ENGINE_RESULT_OK) {
        if (error) *error = EngineError(_handle, @"text input failed");
        return NO;
    }
    return YES;
}

- (CGSize)framePixelSize {
    return _framePixelSize;
}

- (BOOL)setSurfaceSize:(uint32_t)width
                height:(uint32_t)height
                 error:(NSError **)error {
    if (_handle == nullptr) {
        if (error != nullptr) {
            *error = EngineError(nullptr, @"engine is not initialized");
        }
        return NO;
    }
    const engine_result_t result =
        engine_set_surface_size(_handle, width, height);
    if (result != ENGINE_RESULT_OK) {
        if (error != nullptr) {
            *error = EngineError(_handle, @"engine_set_surface_size failed");
        }
        return NO;
    }
    return YES;
}

- (void)shutdown {
    if (_handle != nullptr) {
        engine_destroy(_handle);
        _handle = nullptr;
        _nativePublishedSerial = 0;
        _metalRendererEnabled = NO;
        _framePixelSize = CGSizeZero;
    }
    if (_renderGeneration) {
        if (AetherMetalBridgeEndSession(_renderGeneration)) _renderGeneration = 0;
    }
}

@end
