#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Thin ObjC++ wrapper around engine_api for the Swift shell.
// M0 scope: lifecycle, software-render frame readback, platform-request drain.
// GPU bridge callbacks (Metal) and input translation arrive in M1; see
// doc/apple_host_seam_inventory.md.
@interface AetherEngineSession : NSObject

- (BOOL)initializeWithWritablePath:(NSString *)writablePath
                         cachePath:(NSString *)cachePath
                             error:(NSError **)error
    NS_SWIFT_NAME(initialize(writablePath:cachePath:));

- (BOOL)setOption:(NSString *)key
            value:(NSString *)value
            error:(NSError **)error
    NS_SWIFT_NAME(setOption(_:value:));

- (uint32_t)engineAPIVersion;

// M1 opt-in: installs Metal callbacks and selects the existing godot_native ABI backend.
- (BOOL)enableMetalRenderer:(NSError **)error NS_SWIFT_NAME(enableMetalRenderer());
- (nullable id<MTLTexture>)copyNativeFrameTexture;
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
