#import "EngineSession.h"
#include <cassert>
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        AetherEngineSession *session = [AetherEngineSession new];
        NSError *error = nil;
        assert(![session submitPlatformResponse:@"dialog" argument:@"result=1&text=" error:&error]);
        assert(error && [error.localizedDescription containsString:@"initialized"]);
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        error = nil;
        assert([session initializeWithWritablePath:root cachePath:root error:&error]);
        error = nil;
        assert(![session submitPlatformResponse:@"text_input" argument:@"result=ok\t你好" error:&error]);
        assert(error && error.localizedDescription.length);
        // The public KiriKiri/idle backend cannot accept provider-only responses.
        error = nil;
        assert(![session submitPlatformResponse:@"dialog" argument:@"result=1&text=%E4%BD%A0" error:&error]);
        assert(error && error.localizedDescription.length);
        printf("PASS: wrapper rejects missing engine and unsupported provider response (%s)\n", error.localizedDescription.UTF8String);
        [session shutdown];
        error = nil;
        assert(![session submitPlatformResponse:@"dialog" argument:@"result=0&text=" error:&error]);
        assert(error);
    }
}
