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
#import <AppKit/AppKit.h>
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
#include <errno.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/stat.h>
#include <time.h>

// Upper bound on any accepted fps target. A target this high already degenerates
// to "no cap" in practice; the clamp just keeps a fat-fingered value from flowing
// into the pacer unchecked.
#define FL_MAX_FPS 1000

// ---- configuration (atomics are written by the watcher thread / signal handlers) ----
static atomic_int  g_target_fps = 0;   // desired cap in fps; <= 0 disables pacing
static atomic_int  g_refresh    = 60;  // assumed display refresh (Hz); see FRAME_LIMIT_REFRESH
static int         g_log        = 0;   // periodic fps logging
static int         g_qos        = 1;   // pin the render thread to user-interactive QoS
static int         g_vsync      = -1;  // -1 = auto, 0 = force off, 1 = force on; see FRAME_LIMIT_VSYNC
static char        g_ctrl_path[1024];
static atomic_int  g_background  = 0;   // 1 while the app is occluded / not the active app
static int         g_bg_fps      = 10;  // cap applied while backgrounded; <= 0 disables the whole feature
static int         g_nap_suppression = 0; // 1 if we hold an App Nap assertion in the foreground
static int         g_refresh_auto    = 0;  // 1 = track the display refresh (FRAME_LIMIT_REFRESH unset)

static mach_timebase_info_data_t g_tb;
static IMP g_orig_next_drawable = NULL;
static id  g_activity = nil;   // App Nap assertion so paced sleeps aren't throttled

static char g_log_file_path[1024] = {0};
static char g_status_path[1024]   = {0};   // heartbeat file; read by flctl / the menu-bar app

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
    if (fps <= 0) return;   // defend the division below regardless of the call site
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

// ---- Status heartbeat ----
// Written atomically (temp + rename) about once per second from the census tick.
// A reader treats the file as "live" when its ts is within a few seconds of now;
// a stale or absent file means no game is currently injected/capping. This is the
// single source of truth behind `flctl status` and the menu-bar app's live display.
static void write_status_file(double measured_fps) {
    if (g_status_path[0] == '\0') return;
    char tmp[1100];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", g_status_path, (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    int fg      = atomic_load_explicit(&g_target_fps, memory_order_relaxed);
    int bg      = atomic_load_explicit(&g_background, memory_order_relaxed);
    int refresh = atomic_load_explicit(&g_refresh, memory_order_relaxed);
    int eff     = (g_bg_fps > 0 && bg) ? g_bg_fps : fg;
    fprintf(f,
            "pid=%d\ntarget=%d\nfg_target=%d\nmeasured_fps=%.1f\n"
            "background=%d\nbg_fps=%d\nrefresh=%d\nvsync_mode=%d\nts=%ld\n",
            (int)getpid(), eff, fg, measured_fps,
            bg, g_bg_fps, refresh, g_vsync, (long)time(NULL));
    fclose(f);
    rename(tmp, g_status_path);   // atomic replace; partial readers never see a torn file
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
    int do_status = 0;          // a census tick fired this call → refresh the heartbeat
    double st_measured = 0.0;   // measured primary-layer fps for the heartbeat

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

        do_status = 1;
        st_measured = (double)max_calls * 1e9 / (double)elapsed_ns;

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

        // Evict entries not called in the last interval (call_count == 0) so the fixed
        // table can't be permanently exhausted by layer/thread churn (fullscreen
        // toggles, resolution changes, window recreation). The entry for the current
        // call has count >= 1 so it is never evicted; all pointers into g_census are
        // read before this point, so compacting here invalidates nothing in use.
        int w = 0;
        for (int i = 0; i < g_census_count; i++) {
            if (g_census[i].call_count > 0) {
                if (w != i) g_census[w] = g_census[i];
                g_census[w].call_count = 0;
                w++;
            }
        }
        int evicted = g_census_count - w;
        g_census_count = w;
        if (evicted > 0 && g_log)
            log_line("census: evicted %d stale entr%s", evicted, evicted == 1 ? "y" : "ies");
        g_last_census_time = now;
    }

    pthread_mutex_unlock(&g_census_mutex);

    if (do_status) write_status_file(st_measured);

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

    int fg_target = atomic_load_explicit(&g_target_fps, memory_order_relaxed);
    int target = (g_bg_fps > 0 && atomic_load_explicit(&g_background, memory_order_relaxed))
                 ? g_bg_fps : fg_target;
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
    if (nv > FL_MAX_FPS) nv = FL_MAX_FPS;
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
                    if (v > FL_MAX_FPS) v = FL_MAX_FPS;
                    atomic_store_explicit(&g_target_fps, v, memory_order_relaxed);
                    log_line("live reload target=%d", v);
                }
                fclose(f);
            } else {
                static int warned = 0;
                if (!warned) {
                    warned = 1;
                    log_line("watcher: cannot open control file %s (errno=%d); live reload paused",
                             g_ctrl_path, errno);
                }
            }
        }
        usleep(250000);  // 250 ms
    }
    return NULL;
}

// ---- Occlusion / background-state detection ----
// While the game is on another Space, hidden, or not the active app, we (a) cap to a
// low background fps and (b) drop the App Nap assertion so macOS can throttle the
// process. These observers run on the main queue; the hook only reads g_background.
static BOOL g_obs_app_active  = YES;
static BOOL g_obs_win_visible = YES;
static id   g_obs_tokens[3]   = { nil, nil, nil };

static BOOL any_window_visible(void) {
    NSArray *wins = [NSApp windows];
    if (wins.count == 0) return YES;  // no windows yet: assume visible (don't false-background)
    for (NSWindow *w in wins) {
        if ([w occlusionState] & NSWindowOcclusionStateVisible) return YES;
    }
    return NO;
}

// Recompute background state from the two signals and, on a transition, toggle the
// App Nap assertion. Called only on the main queue, so g_activity needs no lock.
static void apply_background_state(void) {
    BOOL bg  = (!g_obs_app_active) || (!g_obs_win_visible);
    int  was = atomic_load_explicit(&g_background, memory_order_relaxed);
    atomic_store_explicit(&g_background, bg ? 1 : 0, memory_order_relaxed);
    if ((bg ? 1 : 0) == was) return;  // no transition

    if (g_nap_suppression) {
        if (bg) {
            if (g_activity) {
                [[NSProcessInfo processInfo] endActivity:g_activity];
                [g_activity release];
                g_activity = nil;
            }
        } else if (!g_activity) {
            g_activity = [[[NSProcessInfo processInfo]
                beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
                                  reason:@"frame_limiter pacing"] retain];
        }
    }
    log_line("background=%d (app_active=%d win_visible=%d bg_fps=%d)",
             bg, g_obs_app_active, g_obs_win_visible, g_bg_fps);
}

static void install_occlusion_observers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *mq = [NSOperationQueue mainQueue];

    g_obs_app_active  = [NSApp isActive] ? YES : NO;
    g_obs_win_visible = any_window_visible();
    atomic_store_explicit(&g_background,
        ((!g_obs_app_active) || (!g_obs_win_visible)) ? 1 : 0, memory_order_relaxed);

    id t1 = [nc addObserverForName:NSApplicationDidResignActiveNotification
                            object:nil queue:mq usingBlock:^(NSNotification *n) {
        (void)n; g_obs_app_active = NO; apply_background_state();
    }];
    id t2 = [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                            object:nil queue:mq usingBlock:^(NSNotification *n) {
        (void)n; g_obs_app_active = YES; apply_background_state();
    }];
    id t3 = [nc addObserverForName:NSWindowDidChangeOcclusionStateNotification
                            object:nil queue:mq usingBlock:^(NSNotification *n) {
        (void)n; g_obs_win_visible = any_window_visible(); apply_background_state();
    }];
    g_obs_tokens[0] = [t1 retain];
    g_obs_tokens[1] = [t2 retain];
    g_obs_tokens[2] = [t3 retain];

    log_line("occlusion observers installed (bg_fps=%d app_active=%d win_visible=%d)",
             g_bg_fps, g_obs_app_active, g_obs_win_visible);
}

// ---- Display refresh tracking ----
// The adaptive-vsync decision (target > refresh ? off : on) needs the real panel
// refresh. When FRAME_LIMIT_REFRESH is not pinned, detect it from the main screen and
// re-detect on screen-parameter changes (refresh-rate switch, monitor hotplug, moving
// the window to a 120 Hz external display). AppKit-only — no CoreGraphics dependency.
static id g_screen_obs = nil;

static int detect_refresh_hz(void) {
    NSScreen *s = [NSScreen mainScreen];
    // maximumFramesPerSecond reports the panel max reliably (built-in panels return 0
    // from the CoreGraphics mode API); guard with respondsToSelector for old SDKs.
    if (s && [s respondsToSelector:@selector(maximumFramesPerSecond)]) {
        NSInteger m = [s maximumFramesPerSecond];
        if (m > 0) return (int)m;
    }
    return 0;  // unknown — keep the current value
}

static void refresh_from_main_screen(void) {
    if (!g_refresh_auto) return;
    int hz = detect_refresh_hz();
    if (hz <= 0) return;
    int prev = atomic_load_explicit(&g_refresh, memory_order_relaxed);
    if (hz != prev) {
        atomic_store_explicit(&g_refresh, hz, memory_order_relaxed);
        log_line("display refresh -> %d Hz (was %d)", hz, prev);
    }
}

static void install_display_observer(void) {
    refresh_from_main_screen();  // initial detection, now that AppKit is up
    id t = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) { (void)n; refresh_from_main_screen(); }];
    g_screen_obs = [t retain];
}

__attribute__((constructor))
static void framelimiter_init(void) {
    const char *lf = getenv("FRAME_LIMIT_LOGFILE");
    if (lf) {
        strlcpy(g_log_file_path, lf, sizeof g_log_file_path);
    }
    const char *fps = getenv("FRAME_LIMIT_FPS");
    if (!fps || atoi(fps) <= 0) return;   // clean no-op when unset/zero

    // Identify the main game process. The wrapper sets FRAME_LIMIT_OWNER_PID to the
    // game's pid before execv (the pid survives execv); children the game spawns get
    // fresh pids. Non-main processes STILL install the swizzle below — so capping is
    // never lost even if a target renders in a child — but skip the real per-process
    // costs: the App Nap assertion, the watcher thread, and the observers. Unset owner
    // (the standalone DYLD path) is treated as main, preserving the old behaviour.
    const char *owner = getenv("FRAME_LIMIT_OWNER_PID");
    int is_main = !(owner && *owner) || atoi(owner) == (int)getpid();

    int target = atoi(fps);
    if (target > FL_MAX_FPS) target = FL_MAX_FPS;
    mach_timebase_info(&g_tb);
    g_log = getenv("FRAME_LIMIT_LOG") ? atoi(getenv("FRAME_LIMIT_LOG")) : 0;
    if (getenv("FRAME_LIMIT_QOS")) g_qos = atoi(getenv("FRAME_LIMIT_QOS"));
    const char *renv = getenv("FRAME_LIMIT_REFRESH");
    if (renv) {
        atomic_store(&g_refresh, atoi(renv));   // pinned by the user; skip auto-tracking
    } else {
        g_refresh_auto = 1;                     // detected from the display on the main queue
    }
    if (getenv("FRAME_LIMIT_VSYNC"))
        g_vsync = atoi(getenv("FRAME_LIMIT_VSYNC"));
    if (getenv("FRAME_LIMIT_BG_FPS")) g_bg_fps = atoi(getenv("FRAME_LIMIT_BG_FPS"));

    const char *cf = getenv("FRAME_LIMIT_FILE");
    if (cf) {
        strlcpy(g_ctrl_path, cf, sizeof g_ctrl_path);
    } else {
        // Default to $HOME/.framelimiter.fps to match flctl and the wrapper; the old
        // $TMPDIR default meant a standalone-launched game watched a file flctl never
        // wrote, so live tuning silently did nothing.
        const char *h = getenv("HOME");
        if (h) snprintf(g_ctrl_path, sizeof g_ctrl_path, "%s/.framelimiter.fps", h);
        else   snprintf(g_ctrl_path, sizeof g_ctrl_path, "/tmp/.framelimiter.fps");
    }

    const char *sf = getenv("FRAME_LIMIT_STATUS_FILE");
    if (sf) {
        strlcpy(g_status_path, sf, sizeof g_status_path);
    } else {
        const char *h = getenv("HOME");
        if (h) snprintf(g_status_path, sizeof g_status_path, "%s/.framelimiter.status", h);
        else   snprintf(g_status_path, sizeof g_status_path, "/tmp/.framelimiter.status");
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
    if (is_main && (!getenv("FRAME_LIMIT_NONAP") || atoi(getenv("FRAME_LIMIT_NONAP")) != 0)) {
        g_nap_suppression = 1;
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

    // Live reload and the AppKit observers are main-process-only: a non-main process
    // still paces (swizzle above) but at the launch target, without a watcher/observers.
    if (is_main) {
        pthread_t th;
        int rc = pthread_create(&th, NULL, watcher_main, NULL);
        if (rc == 0) pthread_detach(th);
        else log_line("watcher thread failed to start (rc=%d); live reload disabled", rc);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_refresh_auto) install_display_observer();
            if (g_bg_fps > 0)   install_occlusion_observers();
        });
    }

    log_line("loaded target=%d refresh=%d ctrl=%s log=%d signals=%s main=%d",
             target, atomic_load(&g_refresh), g_ctrl_path, g_log,
             getenv("FRAME_LIMIT_SIGNALS") ? "on" : "off", is_main);
}
