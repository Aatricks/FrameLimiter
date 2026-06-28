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
static int         g_vsync      = -1;  // -1 = auto, 0 = force off, 1 = force on; see FRAME_LIMIT_VSYNC
static char        g_ctrl_path[1024];

static mach_timebase_info_data_t g_tb;
static IMP g_orig_next_drawable = NULL;
static id  g_activity = nil;   // App Nap assertion so paced sleeps aren't throttled

static char g_log_file_path[1024] = {0};

static void log_line(const char *fmt, ...) {
    char buf[512];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[framelimiter] %s\n", buf);
    fflush(stderr);
    os_log(OS_LOG_DEFAULT, "[framelimiter] %{public}s", buf);

    if (g_log_file_path[0] != '\0') {
        FILE *f = fopen(g_log_file_path, "a");
        if (f) {
            fprintf(f, "[framelimiter] %s\n", buf);
            fclose(f);
        }
    }
}

static inline uint64_t ns_to_mach(uint64_t ns) {
    return ns * (uint64_t)g_tb.denom / (uint64_t)g_tb.numer;
}
static inline uint64_t mach_to_ns(uint64_t m) {
    return m * (uint64_t)g_tb.numer / (uint64_t)g_tb.denom;
}

// ---- Thread-safe frame rate pacer ----
static pthread_mutex_t g_pace_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_next_deadline = 0;  // mach units

static void pace(int fps) {
    uint64_t period = ns_to_mach(1000000000ull / (uint64_t)fps);
    uint64_t now = mach_absolute_time();
    uint64_t slot = 0;

    pthread_mutex_lock(&g_pace_mutex);
    if (g_next_deadline == 0) {
        g_next_deadline = now + period;
        slot = now;
    } else {
        if (g_next_deadline < now) {
            g_next_deadline = now;
        }
        slot = g_next_deadline;
        g_next_deadline += period;
    }
    pthread_mutex_unlock(&g_pace_mutex);

    if (slot > now) {
        mach_wait_until(slot);
    }
}

// ---- Census & primary-layer selection ----
#define MAX_CENSUS_ENTRIES 32
struct CensusEntry {
    void *layer;
    uint64_t thread_id;
    double width;
    double height;
    uint32_t call_count;
    int original_vsync; // -1 if not set, 0 or 1
    int applied_vsync;  // -1 if not set, 0 or 1
    int qos_set;
};

static struct CensusEntry g_census[MAX_CENSUS_ENTRIES];
static int g_census_count = 0;
static pthread_mutex_t g_census_mutex = PTHREAD_MUTEX_INITIALIZER;

static uint64_t g_last_census_time = 0;
static void *g_primary_layer = NULL;
static unsigned g_dbg_frames = 0;

struct UniqueLayer {
    void *layer;
    uint32_t total_calls;
    double width;
    double height;
};

static id hooked_next_drawable(id self, SEL _cmd) {
    CAMetalLayer *layer = (CAMetalLayer *)self;
    uint64_t tid = 0;
    pthread_threadid_np(pthread_self(), &tid);

    CGSize sz = layer.drawableSize;
    void *layer_ptr = (void *)layer;

    int orig_vsync = -1;
    int appl_vsync = -1;
    int need_qos = 0;

    pthread_mutex_lock(&g_census_mutex);

    struct CensusEntry *entry = NULL;
    BOOL seen_layer = NO;
    BOOL seen_thread = NO;

    for (int i = 0; i < g_census_count; i++) {
        if (g_census[i].layer == layer_ptr) {
            seen_layer = YES;
            if (g_census[i].thread_id == tid) {
                entry = &g_census[i];
            }
        }
        if (g_census[i].thread_id == tid) {
            seen_thread = YES;
        }
    }

    if (!seen_layer) {
        log_line("new layer observed: %p size=%.0fx%.0f drawables=%ld",
                 layer_ptr, (double)sz.width, (double)sz.height,
                 (long)layer.maximumDrawableCount);
    }
    if (!seen_thread) {
        log_line("new calling thread observed: %llu", tid);
    }

    if (entry) {
        entry->call_count++;
    } else {
        if (g_census_count < MAX_CENSUS_ENTRIES) {
            entry = &g_census[g_census_count++];
            entry->layer = layer_ptr;
            entry->thread_id = tid;
            entry->width = sz.width;
            entry->height = sz.height;
            entry->call_count = 1;
            entry->original_vsync = -1;
            entry->applied_vsync = -1;
            entry->qos_set = 0;
        }
    }

    if (entry) {
        if (!entry->qos_set) {
            entry->qos_set = 1;
            need_qos = 1;
        }
        orig_vsync = entry->original_vsync;
        appl_vsync = entry->applied_vsync;
    }

    if (g_primary_layer == NULL) {
        g_primary_layer = layer_ptr;
    }

    uint64_t now = mach_absolute_time();
    if (g_last_census_time == 0) {
        g_last_census_time = now;
    }
    uint64_t elapsed_ns = mach_to_ns(now - g_last_census_time);
    if (elapsed_ns >= 1000000000ull) {
        struct UniqueLayer unique_layers[MAX_CENSUS_ENTRIES];
        int unique_count = 0;

        for (int i = 0; i < g_census_count; i++) {
            void *l = g_census[i].layer;
            int found_idx = -1;
            for (int j = 0; j < unique_count; j++) {
                if (unique_layers[j].layer == l) {
                    found_idx = j;
                    break;
                }
            }
            if (found_idx >= 0) {
                unique_layers[found_idx].total_calls += g_census[i].call_count;
            } else {
                unique_layers[unique_count++] = (struct UniqueLayer){
                    l, g_census[i].call_count, g_census[i].width, g_census[i].height
                };
            }
        }

        void *best_layer = NULL;
        uint32_t max_calls = 0;
        for (int i = 0; i < unique_count; i++) {
            if (unique_layers[i].total_calls > max_calls) {
                max_calls = unique_layers[i].total_calls;
                best_layer = unique_layers[i].layer;
            }
        }

        if (best_layer != NULL) {
            g_primary_layer = best_layer;
        }

        if (g_log) {
            char report[2048];
            int offset = snprintf(report, sizeof(report), "census: target=%d primary=%p (fps=%.1f) layers=[",
                                 atomic_load_explicit(&g_target_fps, memory_order_relaxed),
                                 g_primary_layer,
                                 (double)max_calls * 1e9 / (double)elapsed_ns);

            for (int i = 0; i < g_census_count; i++) {
                if (offset < (int)sizeof(report) - 100) {
                    offset += snprintf(report + offset, sizeof(report) - offset,
                                       "%p(%.0fx%.0f, calls=%u, tid=%llu)%s",
                                       g_census[i].layer,
                                       g_census[i].width, g_census[i].height,
                                       g_census[i].call_count,
                                       g_census[i].thread_id,
                                       (i == g_census_count - 1) ? "" : ", ");
                }
            }
            snprintf(report + offset, sizeof(report) - offset, "]");
            log_line("%s", report);
        }

        for (int i = 0; i < g_census_count; i++) {
            g_census[i].call_count = 0;
        }
        g_last_census_time = now;
    }

    pthread_mutex_unlock(&g_census_mutex);

    if (need_qos && g_qos) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        log_line("set QoS User Interactive for thread %llu", tid);
    }

    if (orig_vsync < 0) {
        orig_vsync = layer.displaySyncEnabled ? 1 : 0;
        pthread_mutex_lock(&g_census_mutex);
        for (int i = 0; i < g_census_count; i++) {
            if (g_census[i].layer == layer_ptr) {
                g_census[i].original_vsync = orig_vsync;
            }
        }
        pthread_mutex_unlock(&g_census_mutex);
    }

    int target = atomic_load_explicit(&g_target_fps, memory_order_relaxed);
    int refresh = atomic_load_explicit(&g_refresh, memory_order_relaxed);
    int desired = orig_vsync;
    if (g_vsync == 0) {
        desired = 0;
    } else if (g_vsync == 1) {
        desired = 1;
    } else {
        desired = (target > refresh) ? 0 : orig_vsync;
    }
    if (desired != appl_vsync) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.displaySyncEnabled = desired ? YES : NO;
        [CATransaction commit];

        pthread_mutex_lock(&g_census_mutex);
        for (int i = 0; i < g_census_count; i++) {
            if (g_census[i].layer == layer_ptr) {
                g_census[i].applied_vsync = desired;
            }
        }
        pthread_mutex_unlock(&g_census_mutex);

        log_line("displaySyncEnabled=%d (target=%d refresh=%d original=%d layer=%p)",
                 desired, target, refresh, orig_vsync, layer_ptr);
    }

    if (g_primary_layer == layer_ptr) {
        uint64_t t0 = mach_absolute_time();
        if (target > 0) pace(target);
        uint64_t t1 = mach_absolute_time();

        id dr = ((id (*)(id, SEL))g_orig_next_drawable)(self, _cmd);

        uint64_t t2 = mach_absolute_time();
        if (g_log >= 2) {
            pthread_mutex_lock(&g_census_mutex);
            unsigned dbg = g_dbg_frames++;
            pthread_mutex_unlock(&g_census_mutex);
            if (dbg < 12) {
                log_line("frame %u: pace=%.1fms orig=%.1fms",
                         dbg, mach_to_ns(t1 - t0) / 1e6, mach_to_ns(t2 - t1) / 1e6);
            }
        }
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
    const char *lf = getenv("FRAME_LIMIT_LOGFILE");
    if (lf) {
        strlcpy(g_log_file_path, lf, sizeof g_log_file_path);
    }
    const char *fps = getenv("FRAME_LIMIT_FPS");
    if (!fps || atoi(fps) <= 0) return;   // clean no-op when unset/zero
    int target = atoi(fps);
    mach_timebase_info(&g_tb);
    g_log = getenv("FRAME_LIMIT_LOG") ? atoi(getenv("FRAME_LIMIT_LOG")) : 0;
    if (getenv("FRAME_LIMIT_QOS")) g_qos = atoi(getenv("FRAME_LIMIT_QOS"));
    if (getenv("FRAME_LIMIT_REFRESH"))
        atomic_store(&g_refresh, atoi(getenv("FRAME_LIMIT_REFRESH")));
    if (getenv("FRAME_LIMIT_VSYNC"))
        g_vsync = atoi(getenv("FRAME_LIMIT_VSYNC"));

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

    // Keep the host out of App Nap and prevent timer coalescing so mach_wait_until
    // isn't throttled. LatencyCritical ensures high-precision timing for pacing.
    if (!getenv("FRAME_LIMIT_NONAP") || atoi(getenv("FRAME_LIMIT_NONAP")) != 0) {
        g_activity = [[[NSProcessInfo processInfo]
            beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
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
