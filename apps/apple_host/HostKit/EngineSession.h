#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

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

- (BOOL)openGameAtPath:(NSString *)gamePath
                 error:(NSError **)error
    NS_SWIFT_NAME(openGame(atPath:));

// ENGINE_STARTUP_STATE_IDLE/RUNNING/SUCCEEDED/FAILED
- (uint32_t)startupState;

- (void)tickWithDeltaMS:(uint32_t)deltaMS NS_SWIFT_NAME(tick(deltaMS:));
- (void)pollPlatformRequests:(void (^)(NSString *operation, NSString *argument))handler
    NS_SWIFT_NAME(pollPlatformRequests(_:));

// Software-render baseline: RGBA8888 frame from the engine readback path.
- (nullable CGImageRef)copyFrameImage CF_RETURNS_RETAINED;

- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
