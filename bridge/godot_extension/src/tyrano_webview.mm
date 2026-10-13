#include "tyrano_webview.h"
#include "tyrano_host_script.h"
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#include <cstdlib>
#include <cstring>

static NSString *const TyranoScheme = @"aether-tyrano";
static NSString *const TyranoErrorDomain = @"AetherTyrano";

@interface AetherTyranoResources : NSObject <WKURLSchemeHandler>
@property(nonatomic, strong) NSURL *root;
@end

@implementation AetherTyranoResources
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *url = task.request.URL;
    NSString *relative = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSURL *file = [[self.root URLByAppendingPathComponent:relative] URLByResolvingSymlinksInPath];
    NSString *prefix = [self.root.path stringByAppendingString:@"/"];
    BOOL directory = NO;
    BOOL inside = [url.host isEqualToString:@"game"] && [file.path hasPrefix:prefix];
    BOOL exists = inside && [NSFileManager.defaultManager fileExistsAtPath:file.path isDirectory:&directory] && !directory;
    NSString *method = task.request.HTTPMethod ?: @"GET";
    NSInteger status = exists ? 200 : (inside ? 404 : 403);
    if (![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"]) status = 405;
    NSDictionary *attributes = exists ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
    uint64_t total = [attributes fileSize], start = 0, end = total;
    NSString *range = [task.request valueForHTTPHeaderField:@"Range"];
    if (status == 200 && [range hasPrefix:@"bytes="]) {
        NSArray<NSString *> *parts = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
        if (parts.count != 2 || [range containsString:@","]) status = 416;
        else {
            NSScanner *first = [NSScanner scannerWithString:parts[0]];
            NSScanner *last = [NSScanner scannerWithString:parts[1]];
            unsigned long long a = 0, b = 0;
            BOOL hasFirst = parts[0].length && [first scanUnsignedLongLong:&a] && first.isAtEnd;
            BOOL hasLast = parts[1].length && [last scanUnsignedLongLong:&b] && last.isAtEnd;
            if ((!hasFirst && parts[0].length) || (!hasLast && parts[1].length) || (!hasFirst && !hasLast)) status = 416;
            else {
                if (hasFirst) { start = a; end = hasLast && b < UINT64_MAX ? MIN(total, b + 1) : total; }
                else { start = total > b ? total - b : 0; end = total; }
                status = start < end && start < total ? 206 : 416;
            }
        }
    }
    NSString *mime = [UTType typeWithFilenameExtension:file.pathExtension].preferredMIMEType ?: @"application/octet-stream";
    NSString *extension = file.pathExtension.lowercaseString;
    if ([@[@"ks", @"tjs", @"txt"] containsObject:extension]) mime = @"text/plain; charset=utf-8";
    else if ([extension isEqualToString:@"js"]) mime = @"application/javascript; charset=utf-8";
    else if ([extension isEqualToString:@"html"]) mime = @"text/html; charset=utf-8";
    BOOL success = status == 200 || status == 206;
    NSMutableDictionary *headers = [@{@"Content-Type":mime, @"Cache-Control":@"no-store",
        @"Access-Control-Allow-Origin":@"*", @"Accept-Ranges":@"bytes",
        @"Content-Length":[NSString stringWithFormat:@"%llu", success ? end - start : 0]} mutableCopy];
    if (status == 206) headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", start, end - 1, total];
    if (status == 416) headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%llu", total];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [task didReceiveResponse:response];
    if (success && ![method isEqualToString:@"HEAD"]) {
        NSError *error = nil;
        NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:file error:&error];
        if (!input || ![input seekToOffset:start error:&error]) { [task didFailWithError:error]; return; }
        uint64_t remaining = end - start;
        while (remaining) {
            @autoreleasepool {
                NSData *chunk = [input readDataUpToLength:MIN(remaining, uint64_t(64 * 1024)) error:&error];
                if (!chunk || chunk.length == 0) {
                    [input closeAndReturnError:nil];
                    [task didFailWithError:error ?: [NSError errorWithDomain:TyranoErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"Game resource changed while reading"}]];
                    return;
                }
                [task didReceiveData:chunk]; remaining -= chunk.length;
            }
        }
        [input closeAndReturnError:nil];
    }
    [task didFinish];
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    // Resources are streamed synchronously on the WebKit handler/UI thread.
    // No asynchronous callback can outlive a cancelled scheme task.
}
@end

@interface AetherTyranoWebHost : NSObject <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, strong) NSURL *storage;
@property(nonatomic, strong) NSString *storageJSON;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic) BOOL closed;
- (void)push:(NSString *)type value:(id)value;
- (NSString *)persist:(NSString *)json;
- (void)detach;
@end

@implementation AetherTyranoWebHost
- (void)push:(NSString *)type value:(id)value {
    if (self.closed) return;
    if (self.events.count >= 128) [self.events removeObjectAtIndex:0];
    [self.events addObject:@{@"type":type, @"value":value ?: NSNull.null}];
}
- (void)detach {
    self.closed = YES;
    [self.web stopLoading];
    [self.web.configuration.userContentController removeScriptMessageHandlerForName:@"aetherTyrano"];
    self.web.navigationDelegate = nil; self.web.UIDelegate = nil;
    [self.web removeFromSuperview]; self.web = nil;
}
- (NSString *)persist:(NSString *)json {
    NSData *data = [json isKindOfClass:NSString.class] ? [json dataUsingEncoding:NSUTF8StringEncoding] : nil;
    NSError *error = nil;
    NSDictionary *values = data.length <= 64 * 1024 * 1024 ? [NSJSONSerialization JSONObjectWithData:data ?: NSData.data options:0 error:&error] : nil;
    BOOL valid = [values isKindOfClass:NSDictionary.class] && values.count <= 1024;
    for (id key in valid ? values : @{}) {
        if (![key isKindOfClass:NSString.class] || ![values[key] isKindOfClass:NSString.class]) { valid = NO; break; }
    }
    if (!valid || ![data writeToURL:self.storage options:NSDataWritingAtomic error:&error])
        return error.localizedDescription ?: @"Could not persist game storage";
    self.storageJSON = json;
    [self push:@"storage_saved" value:@YES];
    return nil;
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (self.closed || !message.frameInfo.isMainFrame || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    NSString *type = body[@"type"];
    if (![type isKindOfClass:NSString.class]) return;
    if ([@[@"ready", @"log", @"close"] containsObject:type]) {
        [self push:type value:[body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @""];
    }
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self push:@"document_loaded" value:@YES];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled) [self push:@"error" value:error.localizedDescription];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self push:@"error" value:@"The TyranoScript web process stopped"];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSURL *url = action.request.URL;
    BOOL local = [url.scheme isEqualToString:TyranoScheme] && [url.host isEqualToString:@"game"];
    handler(local ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
    if (!local) [self push:@"log" value:@"External page navigation is unavailable in this prototype"];
}
- (void)dialog:(NSString *)message text:(NSString *)text cancel:(BOOL)cancel completion:(void (^)(BOOL, NSString *))completion {
#if TARGET_OS_IPHONE
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TyranoScript" message:message preferredStyle:UIAlertControllerStyleAlert];
    if (text) [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = text; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { completion(YES, alert.textFields.firstObject.text); }]];
    if (cancel) [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { completion(NO, nil); }]];
    UIViewController *presenter = self.web.window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (presenter) [presenter presentViewController:alert animated:YES completion:nil];
    else completion(NO, nil);
#else
    NSAlert *alert = [NSAlert new]; alert.messageText = message ?: @"";
    [alert addButtonWithTitle:@"OK"]; if (cancel) [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = nil;
    if (text) { field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 28)]; field.stringValue = text; alert.accessoryView = field; }
    if (self.web.window) [alert beginSheetModalForWindow:self.web.window completionHandler:^(NSModalResponse response) { completion(response == NSAlertFirstButtonReturn, field.stringValue); }];
    else completion(NO, nil);
#endif
}
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completion {
    [self dialog:message text:nil cancel:NO completion:^(BOOL ok, NSString *text) { completion(); }];
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completion {
    [self dialog:message text:nil cancel:YES completion:^(BOOL ok, NSString *text) { completion(ok); }];
}
- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)text initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completion {
    if ([prompt isEqualToString:@"__AETHER_TYRANO_STORAGE_READ__"] && frame.isMainFrame) {
        // Read the current snapshot on every document creation, including an
        // in-game location.reload(); the original user-script seed is stale.
        completion(self.storageJSON); return;
    }
    if ([prompt isEqualToString:@"__AETHER_TYRANO_STORAGE__"] && frame.isMainFrame) {
        // A Storage write must finish (or throw) before the engine reports a
        // successful save. The UI delegate provides a synchronous JS boundary
        // without showing a dialog, including immediately before app teardown.
        completion([self persist:text]); return;
    }
    [self dialog:prompt text:text ?: @"" cancel:YES completion:^(BOOL ok, NSString *value) { completion(ok ? value : nil); }];
}
@end

extern "C" void *aether_tyrano_open(uint64_t nativeWindow, const char *entryPath, const char *storagePath, char **outError) {
    @autoreleasepool {
        if (outError) *outError = nullptr;
        auto fail = [&](NSString *message) -> void * {
            if (outError) *outError = strdup(message.UTF8String ?: "TyranoScript initialization failed");
            return nullptr;
        };
        if (!NSThread.isMainThread || !nativeWindow || !entryPath || !storagePath) return fail(@"A native UI-thread window and game path are required");
        NSURL *requestedEntry = [NSURL fileURLWithPath:@(entryPath)];
        NSURL *root = requestedEntry.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath;
        NSURL *entry = requestedEntry.URLByResolvingSymlinksInPath;
        if (![entry.path hasPrefix:[root.path stringByAppendingString:@"/"]]) return fail(@"The game entry points outside its folder");
        if (![NSFileManager.defaultManager fileExistsAtPath:entry.path]) return fail(@"TyranoScript index.html was not found");
        NSURL *storage = [NSURL fileURLWithPath:@(storagePath)];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:storage.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]) return fail(error.localizedDescription);
        NSDictionary *values = @{};
        if ([NSFileManager.defaultManager fileExistsAtPath:storage.path]) {
            NSData *data = [NSData dataWithContentsOfURL:storage options:0 error:&error];
            if (!data || data.length > 64 * 1024 * 1024) return fail(error.localizedDescription ?: @"Game storage is too large");
            values = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (![values isKindOfClass:NSDictionary.class] || values.count > 1024) return fail(@"Game storage is invalid; the original file was preserved");
            for (id key in values) if (![values[key] isKindOfClass:NSString.class]) return fail(@"Game storage contains invalid values; the original file was preserved");
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:values options:NSJSONWritingFragmentsAllowed error:&error];
        NSString *initial = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        NSString *script = [@(kAetherTyranoHostScript) stringByReplacingOccurrencesOfString:@"__AETHER_STORAGE__" withString:initial];
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
#if TARGET_OS_IPHONE
        configuration.allowsInlineMediaPlayback = YES;
#endif
        AetherTyranoResources *resources = [AetherTyranoResources new]; resources.root = root;
        [configuration setURLSchemeHandler:resources forURLScheme:TyranoScheme];
        AetherTyranoWebHost *host = [AetherTyranoWebHost new]; host.storage = storage; host.storageJSON = initial; host.events = [NSMutableArray new];
        [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
        [configuration.userContentController addScriptMessageHandler:host name:@"aetherTyrano"];
        host.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
        host.web.navigationDelegate = host; host.web.UIDelegate = host;
#if TARGET_OS_IPHONE
        UIView *parent = (__bridge UIView *)(reinterpret_cast<void *>(nativeWindow));
        host.web.underPageBackgroundColor = UIColor.blackColor;
#else
        NSView *parent = ((__bridge NSWindow *)(reinterpret_cast<void *>(nativeWindow))).contentView;
        host.web.underPageBackgroundColor = NSColor.blackColor;
#endif
        if (!parent) { [host detach]; return fail(@"The application window is unavailable"); }
        [parent addSubview:host.web];
        NSString *escaped = [entry.lastPathComponent stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        [host.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[@"aether-tyrano://game/" stringByAppendingString:escaped]]]];
        return (__bridge_retained void *)host;
    }
}
extern "C" void aether_tyrano_close(void *handle) {
    if (!handle) return;
    AetherTyranoWebHost *host = (__bridge_transfer AetherTyranoWebHost *)handle;
    [host detach];
}
extern "C" void aether_tyrano_rect(void *handle, double x, double y, double width, double height) {
    AetherTyranoWebHost *host = (__bridge AetherTyranoWebHost *)handle;
    if (!host.web.superview) return;
    CGRect bounds = host.web.superview.bounds;
    CGRect rect = CGRectMake(x * bounds.size.width, y * bounds.size.height, width * bounds.size.width, height * bounds.size.height);
#if !TARGET_OS_IPHONE
    if (!host.web.superview.isFlipped) rect.origin.y = bounds.size.height - rect.origin.y - rect.size.height;
#endif
    if (!CGRectEqualToRect(host.web.frame, rect)) host.web.frame = rect;
}
extern "C" void aether_tyrano_evaluate(void *handle, const char *script) {
    AetherTyranoWebHost *host = (__bridge AetherTyranoWebHost *)handle;
    if (!host.web || !script) return;
    [host.web evaluateJavaScript:@(script) completionHandler:^(id result, NSError *error) {
        [host push:error ? @"evaluation_error" : @"evaluation" value:error ? error.localizedDescription : result];
    }];
}
extern "C" void aether_tyrano_pause(void *handle, bool paused) {
    AetherTyranoWebHost *host = (__bridge AetherTyranoWebHost *)handle;
    [host.web evaluateJavaScript:paused ? @"window.AetherTyranoHost?.pause(true)" : @"window.AetherTyranoHost?.pause(false)" completionHandler:nil];
    [host.web setAllMediaPlaybackSuspended:paused completionHandler:^{}];
}
extern "C" void aether_tyrano_controls(void *handle, bool visible) {
    AetherTyranoWebHost *host = (__bridge AetherTyranoWebHost *)handle;
    [host.web evaluateJavaScript:visible ? @"window.AetherTyranoHost?.controls(true)" : @"window.AetherTyranoHost?.controls(false)" completionHandler:nil];
}
extern "C" char *aether_tyrano_poll(void *handle) {
    AetherTyranoWebHost *host = (__bridge AetherTyranoWebHost *)handle;
    if (!host.events.count) return nullptr;
    NSDictionary *event = host.events.firstObject;
    [host.events removeObjectAtIndex:0];
    if (![NSJSONSerialization isValidJSONObject:event]) return nullptr;
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
extern "C" void aether_tyrano_free_string(char *value) { free(value); }
