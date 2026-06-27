// minimal_metal_app — a tiny native-Metal harness for exercising frame_limiter.
//
// It drives -[CAMetalLayer nextDrawable] in a tight loop (clear + present) and logs
// the achieved frame rate to stderr once per second, so the limiter can be validated
// without reading an on-screen HUD.
//
//   RUN_SECONDS=N   run for N seconds then exit        (default 5)
//   WINDOWED=1      show an on-screen window           (default: offscreen layer)
//
// Built with ARC.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>
#include <stdatomic.h>
#include <pthread/qos.h>

#if __has_feature(objc_arc)
#else
#error "build minimal_metal_app with -fobjc-arc"
#endif

static id<MTLDevice>        gDevice;
static id<MTLCommandQueue>  gQueue;
static CAMetalLayer        *gLayer;
static int                  gRunSeconds = 5;
static mach_timebase_info_data_t gTb;

static double seconds_since(uint64_t startMach) {
    uint64_t d = mach_absolute_time() - startMach;
    return (double)(d * gTb.numer / gTb.denom) / 1e9;
}

static void render_loop(void) {
    uint64_t start = mach_absolute_time();
    uint64_t winStart = start;
    unsigned winCount = 0;
    unsigned long total = 0;
    unsigned long nilDrawables = 0;

    while (1) {
        @autoreleasepool {
            id<CAMetalDrawable> d = [gLayer nextDrawable];
            if (d) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = d.texture;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0.10, 0.20, 0.32, 1.0);
                id<MTLCommandBuffer> cb = [gQueue commandBuffer];
                id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                [e endEncoding];
                [cb presentDrawable:d];
                [cb commit];
            } else {
                nilDrawables++;
            }

            total++;
            winCount++;
            double win = seconds_since(winStart);
            if (win >= 1.0) {
                fprintf(stderr, "[minimal] fps=%.1f (frames=%lu nil=%lu)\n",
                        winCount / win, total, nilDrawables);
                fflush(stderr);
                winStart = mach_absolute_time();
                winCount = 0;
            }
            if (gRunSeconds > 0 && seconds_since(start) >= gRunSeconds) break;
        }
    }
    fprintf(stderr, "[minimal] done frames=%lu nil=%lu\n", total, nilDrawables);
    fflush(stderr);
}

static void setup_metal(CGSize size) {
    gDevice = MTLCreateSystemDefaultDevice();
    gQueue  = [gDevice newCommandQueue];
    gLayer.device = gDevice;
    gLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    gLayer.framebufferOnly = NO;
    gLayer.maximumDrawableCount = 3;
    gLayer.displaySyncEnabled = NO;       // free-run; the limiter overrides this as needed
    gLayer.drawableSize = size;
}

// ---- windowed mode ----
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSRect frame = NSMakeRect(0, 0, 640, 400);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"frame_limiter test";
    NSView *v = w.contentView;
    v.wantsLayer = YES;
    gLayer = (CAMetalLayer *)[CAMetalLayer layer];
    v.layer = gLayer;
    CGFloat scale = w.backingScaleFactor ?: 1.0;
    setup_metal(CGSizeMake(frame.size.width * scale, frame.size.height * scale));
    [w center];
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [NSThread detachNewThreadWithBlock:^{
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        render_loop();
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    }];
}
@end

static id<NSObject> gActivity;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        mach_timebase_info(&gTb);
        if (getenv("RUN_SECONDS")) gRunSeconds = atoi(getenv("RUN_SECONDS"));

        // Keep this measurement process out of App Nap / timer throttling so the
        // limiter's sleeps are not coalesced (a real foreground game isn't napped).
        gActivity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
                              reason:@"frame_limiter test"];

        if (getenv("WINDOWED")) {
            NSApplication *app = [NSApplication sharedApplication];
            app.activationPolicy = NSApplicationActivationPolicyRegular;
            AppDelegate *del = [AppDelegate new];
            app.delegate = del;
            [app run];
        } else {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            gLayer = (CAMetalLayer *)[CAMetalLayer layer];
            setup_metal(CGSizeMake(1280, 800));
            render_loop();
        }
    }
    return 0;
}
