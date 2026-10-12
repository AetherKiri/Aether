#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "engine_api.h"
#import "MetalBridge.h"

NS_ASSUME_NONNULL_BEGIN

// Thin ObjC++ wrapper around engine_api for the Swift shell.
// M0 scope: lifecycle, software-render frame readback, platform-request drain.
// GPU bridge callbacks (Metal) and input translation arrive in M1; see
// doc/apple_host_seam_inventory.md.
@interface AetherEngineSession : NSObject

// Probes the registered runtime provider for a game root (>0 = match,
// 0 = no match, <0 = provider unavailable). Same query the Godot host uses
// before launch; no engine session is required.
+ (int32_t)probeRuntimeProvider:(NSString *)runtimeId path:(NSString *)gameRootPath
    NS_SWIFT_NAME(probeRuntimeProvider(_:path:));

- (BOOL)initializeWithWritablePath:(NSString *)writablePath
                         cachePath:(NSString *)cachePath
                             error:(NSError **)error
    NS_SWIFT_NAME(initialize(writablePath:cachePath:));

- (BOOL)setOption:(NSString *)key
            value:(NSString *)value
            error:(NSError **)error
    NS_SWIFT_NAME(setOption(_:value:));

// Borrow only; close dependent media before shutdown destroys this handle.
- (engine_handle_t _Nullable)borrowedEngineHandle;

- (uint32_t)engineAPIVersion;

// Optional local-model text translation. Availability and state are
// process-wide and mirror engine_is_text_translation_available().
- (BOOL)isTextTranslationAvailable;
// Active graphics backend string (engine_get_renderer_info); empty when the
// runtime is not active.
- (NSString *)rendererInfo;
// Runtime memory/cache snapshot (engine_get_memory_stats); nil when inactive.
- (nullable NSDictionary<NSString *, NSNumber *> *)memoryStats;
// Reports whether the last engine_tick produced a new rendered frame.
// The ABI query is score-once per tick, so call it immediately after tick:.
- (BOOL)lastTickRenderedFrame;
// ENGINE_TEXT_TRANSLATION_DISABLED/LOADING/READY/FAILED
- (uint32_t)textTranslationState;
// Process-wide resource/timing snapshot; nil when the query fails.
- (nullable NSDictionary<NSString *, NSNumber *> *)textTranslationStats;

// Focused KiriKiri text layer snapshot (engine_text_input_state_t). Mirrors the
// Godot player's get_text_input_state(): "available" is false when the query
// fails or no engine exists.
- (NSDictionary<NSString *, NSNumber *> *)textInputState;
// Backing text of the focused editor; empty when unavailable.
- (NSString *)copyTextInputText;
// One TEXT_INPUT event per Unicode scalar (NUL/CR/LF skipped), matching the
// Godot shell's composed-text path.
- (BOOL)sendTextInput:(NSString *)text error:(NSError **)error;
// IME composition via the "ime_preedit_cursor" ("start,length") and
// "ime_preedit" options; nil text clears the pending preedit.
- (BOOL)sendIMEPreedit:(nullable NSString *)text
           cursorStart:(int32_t)cursorStart
          cursorLength:(int32_t)cursorLength
                 error:(NSError **)error;

// M1 opt-in: installs Metal callbacks and selects the existing godot_native ABI backend.
- (BOOL)enableMetalRenderer:(NSError **)error NS_SWIFT_NAME(enableMetalRenderer());
- (nullable id<MTLTexture>)copyNativeFrameTexture;
- (nullable AetherMetalFrameLease *)acquireNativeFrame;
- (NSString *)metalBridgeDiagnostics;

- (BOOL)openGameAtPath:(NSString *)gamePath
                 error:(NSError **)error
    NS_SWIFT_NAME(openGame(atPath:));

// ENGINE_STARTUP_STATE_IDLE/RUNNING/SUCCEEDED/FAILED
- (uint32_t)startupState;
- (NSString *)lastError;
- (NSString *)drainStartupLogs;

- (void)tickWithDeltaMS:(uint32_t)deltaMS NS_SWIFT_NAME(tick(deltaMS:));
- (BOOL)submitPlatformResponse:(NSString *)operation argument:(NSString *)argument error:(NSError **)error
    NS_SWIFT_NAME(submitPlatformResponse(_:argument:));

- (void)pollPlatformRequests:(void (^)(NSString *operation, NSString *argument))handler
    NS_SWIFT_NAME(pollPlatformRequests(_:));

// Input (engine VK codes; coordinates in game canvas space).
- (void)sendPointerEventWithType:(uint32_t)type
                       pointerId:(int32_t)pointerId
                               x:(double)x
                               y:(double)y
                          deltaX:(double)deltaX
                          deltaY:(double)deltaY
                          button:(int32_t)button
                       modifiers:(int32_t)modifiers
    NS_SWIFT_NAME(sendPointer(type:pointerId:x:y:deltaX:deltaY:button:modifiers:));

- (void)sendKeyEvent:(BOOL)pressed
             keyCode:(int32_t)keyCode
           modifiers:(int32_t)modifiers
             unicode:(uint32_t)unicode
    NS_SWIFT_NAME(sendKey(pressed:keyCode:modifiers:unicode:));

- (BOOL)sendTextCodepoint:(uint32_t)codepoint error:(NSError **)error NS_SWIFT_NAME(sendTextCodepoint(_:));

// Size (pixels) of the most recent frame readback; .zero before first frame.
- (CGSize)framePixelSize;

// Surface size controls the presentation canvas AND the pointer coordinate
// space. Default is 1280x720; set it to the game frame size for a 1:1 "Game
// Native" canvas (mirrors the Godot host's default surface mode).
- (BOOL)setSurfaceSize:(uint32_t)width
                height:(uint32_t)height
                 error:(NSError **)error
    NS_SWIFT_NAME(setSurfaceSize(width:height:));

// Software-render baseline: RGBA8888 frame from the engine readback path.
- (nullable CGImageRef)copyFrameImage CF_RETURNS_RETAINED;

- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
