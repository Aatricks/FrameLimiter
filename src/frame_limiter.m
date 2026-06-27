// frame_limiter — a DYLD-injected frame-rate limiter for native Metal games on macOS.
//
// It swizzles -[CAMetalLayer nextDrawable] and paces the render loop with
// mach_wait_until, capping the frame rate to a configurable, live-tunable target.
// Because pacing nextDrawable applies back-pressure (the in-flight drawable pool
// drains and the render thread stalls), it cuts real GPU work rather than merely
// delaying display.
//
// When the target is above the display refresh, vsync is forced off so the engine
// can actually produce >refresh frames (this causes tearing on a fixed panel — the
// accepted price of the lower input latency). At or below refresh the layer's
// original vsync setting is restored.
//
// Configuration is entirely via environment variables and a control file; with no
// FRAME_LIMIT_FPS set, the library installs nothing and is a clean no-op.
//
// Compiled without ARC: the hook neither retains nor releases anything; it forwards
// the drawable the original implementation already autoreleased.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/log.h>

#include <stdatomic.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/stat.h>

// ---- configuration (atomics are written by the watcher thread / signal handlers) ----
static atomic_int  g_target_fps = 0;   // desired cap in fps; <= 0 disables pacing
static atomic_int  g_refresh    = 60;  // assumed display refresh (Hz); see FRAME_LIMIT_REFRESH
static int         g_log        = 0;   // periodic fps logging
static int         g_qos        = 1;   // pin the render thread to user-interactive QoS
static char        g_ctrl_path[1024];

static mach_timebase_info_data_t g_tb;
static IMP g_orig_next_drawable = NULL;
static id  g_activity = nil;   // App Nap assertion so paced sleeps aren't throttled

// ---- render-thread-only state (one render thread assumed) ----
static uint64_t g_next_deadline   = 0;  // mach units
static uint64_t g_fps_win_start   = 0;
static unsigned g_fps_win_count   = 0;

// ---- primary-layer selection (pace only the largest layer; pass overlays through) ----
static void   *g_primary_layer = NULL;
static double  g_primary_area  = 0.0;
static int     g_vsync_original = -1;   // captured displaySyncEnabled of the primary layer
static int     g_vsync_applied  = -1;
static int     g_logged_first   = 0;
static unsigned g_dbg_frames    = 0;

static void log_line(const char *fmt, ...) {
    char buf[512];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[framelimiter] %s\n", buf);
    fflush(stderr);
    // Also to os_log, so it's visible when the host is launched by Steam (which
    // discards stderr). Watch with:
    //   log stream --style compact --predicate 'eventMessage CONTAINS "framelimiter"'
    os_log(OS_LOG_DEFAULT, "[framelimiter] %{public}s", buf);
}

static inline uint64_t ns_to_mach(uint64_t ns) {
    return ns * (uint64_t)g_tb.denom / (uint64_t)g_tb.numer;
}
static inline uint64_t mach_to_ns(uint64_t m) {
    return m * (uint64_t)g_tb.numer / (uint64_t)g_tb.denom;
}

// Force displaySyncEnabled per the adaptive rule, only when it needs to change.
static void apply_vsync(CAMetalLayer *layer, int target) {
    if (g_vsync_original < 0)
        g_vsync_original = layer.displaySyncEnabled ? 1 : 0;

    int refresh = atomic_load_explicit(&g_refresh, memory_order_relaxed);
    int desired = (target > refresh) ? 0 /* off, allow >refresh */
                                     : g_vsync_original /* restore */;
    if (desired == g_vsync_applied) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.displaySyncEnabled = desired ? YES : NO;
    [CATransaction commit];
    g_vsync_applied = desired;
    log_line("displaySyncEnabled=%d (target=%d refresh=%d original=%d)",
             desired, target, refresh, g_vsync_original);
}

// Sleep so consecutive paced calls are >= one period apart. Deadlines accumulate
// (no per-frame drift) but never build up debt after a stall.
static void pace(int fps) {
    uint64_t period = ns_to_mach(1000000000ull / (uint64_t)fps);
    uint64_t now = mach_absolute_time();

    if (g_next_deadline == 0) {            // first paced frame: render immediately, seed schedule
        g_next_deadline = now + period;
        return;
    }
    if (g_next_deadline > now) {
        mach_wait_until(g_next_deadline);  // no busy-wait: power is the whole point
        now = mach_absolute_time();
    }
    uint64_t next = g_next_deadline + period;
    if (next < now) next = now + period;   // resync after a long stall
    g_next_deadline = next;
}

static void fps_tick(void) {
    if (!g_log) return;
    uint64_t now = mach_absolute_time();
    if (g_fps_win_start == 0) { g_fps_win_start = now; g_fps_win_count = 0; return; }
    g_fps_win_count++;
    uint64_t elapsed_ns = mach_to_ns(now - g_fps_win_start);
    if (elapsed_ns >= 1000000000ull) {
        double fps = (double)g_fps_win_count * 1e9 / (double)elapsed_ns;
        log_line("paced fps=%.1f target=%d",
                 fps, atomic_load_explicit(&g_target_fps, memory_order_relaxed));
        g_fps_win_start = now;
        g_fps_win_count = 0;
    }
}

// The swizzled -[CAMetalLayer nextDrawable].
static id hooked_next_drawable(id self, SEL _cmd) {
    CAMetalLayer *layer = (CAMetalLayer *)self;

    CGSize sz = layer.drawableSize;
    double area = (double)sz.width * (double)sz.height;

    // Track the largest layer as "primary"; only it is paced.
    if (g_primary_layer == NULL || area > g_primary_area) {
        if (g_primary_layer != (void *)layer)
            log_line("primary layer=%p size=%.0fx%.0f drawables=%ld",
                     (void *)layer, (double)sz.width, (double)sz.height,
                     (long)layer.maximumDrawableCount);
        g_primary_layer = (void *)layer;
        g_primary_area = area;
    }

    if (g_primary_layer == (void *)layer) {
        if (!g_logged_first) {
            g_logged_first = 1;
            if (g_qos) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            log_line("first frame: displaySyncEnabled=%d maximumDrawableCount=%ld size=%.0fx%.0f",
                     layer.displaySyncEnabled ? 1 : 0,
                     (long)layer.maximumDrawableCount,
                     (double)sz.width, (double)sz.height);
        }
        int target = atomic_load_explicit(&g_target_fps, memory_order_relaxed);
        apply_vsync(layer, target);
        uint64_t t0 = mach_absolute_time();
        if (target > 0) pace(target);
        uint64_t t1 = mach_absolute_time();
        id dr = ((id (*)(id, SEL))g_orig_next_drawable)(self, _cmd);
        uint64_t t2 = mach_absolute_time();
        if (g_log >= 2 && g_dbg_frames < 12) {
            g_dbg_frames++;
            log_line("frame %u: pace=%.1fms orig=%.1fms",
                     g_dbg_frames, mach_to_ns(t1 - t0) / 1e6, mach_to_ns(t2 - t1) / 1e6);
        }
        fps_tick();
        return dr;
    }

    return ((id (*)(id, SEL))g_orig_next_drawable)(self, _cmd);
}

// SIGUSR1 = step down, SIGUSR2 = step up. async-signal-safe: just an atomic store.
static void on_sigusr(int sig) {
    int step = 5;
    int cur = atomic_load_explicit(&g_target_fps, memory_order_relaxed);
    int nv = (sig == SIGUSR2) ? cur + step : cur - step;
    if (nv < 5) nv = 5;
    atomic_store_explicit(&g_target_fps, nv, memory_order_relaxed);
}

// Watch the control file; on change, parse an integer fps and apply it live.
static void *watcher_main(void *arg) {
    (void)arg;
    struct timespec last = {0, 0};
    for (;;) {
        struct stat st;
        if (stat(g_ctrl_path, &st) == 0 &&
            (st.st_mtimespec.tv_sec != last.tv_sec ||
             st.st_mtimespec.tv_nsec != last.tv_nsec)) {
            last = st.st_mtimespec;
            FILE *f = fopen(g_ctrl_path, "r");
            if (f) {
                int v = -1;
                if (fscanf(f, "%d", &v) == 1 && v >= 0) {
                    atomic_store_explicit(&g_target_fps, v, memory_order_relaxed);
                    log_line("live reload target=%d", v);
                }
                fclose(f);
            }
        }
        usleep(250000);  // 250 ms
    }
    return NULL;
}

__attribute__((constructor))
static void framelimiter_init(void) {
    const char *fps = getenv("FRAME_LIMIT_FPS");
    if (!fps || atoi(fps) <= 0) return;   // clean no-op when unset/zero
    int target = atoi(fps);

    mach_timebase_info(&g_tb);
    g_log = getenv("FRAME_LIMIT_LOG") ? atoi(getenv("FRAME_LIMIT_LOG")) : 0;
    if (getenv("FRAME_LIMIT_QOS")) g_qos = atoi(getenv("FRAME_LIMIT_QOS"));
    if (getenv("FRAME_LIMIT_REFRESH"))
        atomic_store(&g_refresh, atoi(getenv("FRAME_LIMIT_REFRESH")));

    const char *cf = getenv("FRAME_LIMIT_FILE");
    if (cf) {
        strlcpy(g_ctrl_path, cf, sizeof g_ctrl_path);
    } else {
        const char *t = getenv("TMPDIR");
        snprintf(g_ctrl_path, sizeof g_ctrl_path, "%sframelimiter.fps", t ? t : "/tmp/");
    }
    atomic_store(&g_target_fps, target);

    Class cls = objc_getClass("CAMetalLayer");
    if (!cls) { log_line("CAMetalLayer class not found — disabled"); return; }
    SEL sel = sel_registerName("nextDrawable");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { log_line("-[CAMetalLayer nextDrawable] not found — disabled"); return; }
    g_orig_next_drawable = method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_next_drawable);

    // Keep the host out of App Nap so mach_wait_until isn't throttled/coalesced
    // (a foreground game won't be napped anyway; this is a safety net). Light
    // assertion: prevents napping without disabling system-wide power management.
    if (!getenv("FRAME_LIMIT_NONAP") || atoi(getenv("FRAME_LIMIT_NONAP")) != 0) {
        g_activity = [[[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityUserInitiated
                              reason:@"frame_limiter pacing"] retain];
    }

    if (getenv("FRAME_LIMIT_SIGNALS")) {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = on_sigusr;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART;
        sigaction(SIGUSR1, &sa, NULL);
        sigaction(SIGUSR2, &sa, NULL);
    }

    pthread_t th;
    if (pthread_create(&th, NULL, watcher_main, NULL) == 0)
        pthread_detach(th);

    log_line("loaded target=%d refresh=%d ctrl=%s log=%d signals=%s",
             target, atomic_load(&g_refresh), g_ctrl_path, g_log,
             getenv("FRAME_LIMIT_SIGNALS") ? "on" : "off");
}
