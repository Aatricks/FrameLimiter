#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <limits.h>
#include <string.h>
#include <mach-o/dyld.h>

// Detection marker: install-lsenv.sh greps the on-disk executable for this string to
// tell whether the file is already our wrapper (vs. a real game binary, e.g. after a
// Steam update overwrote the wrapper). `used` keeps it in the binary under -O2 even
// though nothing references it. Bump the version suffix if the wrapper ABI changes.
__attribute__((used)) static const char kFLWrapperMarker[] = "FRAMELIMITER_WRAPPER_v1";

int main(int argc, char *argv[]) {
    (void)argc;
    const char *home = getenv("HOME");
    char fps_file[PATH_MAX];
    char log_file[PATH_MAX];
    char hud_file[PATH_MAX];
    char bgfps_file[PATH_MAX];
    if (home) {
        snprintf(fps_file, sizeof(fps_file), "%s/.framelimiter.fps", home);
        snprintf(log_file, sizeof(log_file), "%s/.framelimiter.log", home);
        snprintf(hud_file, sizeof(hud_file), "%s/.framelimiter.hud", home);
        snprintf(bgfps_file, sizeof(bgfps_file), "%s/.framelimiter.bgfps", home);
    } else {
        snprintf(fps_file, sizeof(fps_file), "/tmp/.framelimiter.fps");
        snprintf(log_file, sizeof(log_file), "/tmp/.framelimiter.log");
        snprintf(hud_file, sizeof(hud_file), "/tmp/.framelimiter.hud");
        snprintf(bgfps_file, sizeof(bgfps_file), "/tmp/.framelimiter.bgfps");
    }

    const char *hud_val = "1";
    FILE *hf = fopen(hud_file, "r");
    if (hf) {
        char ch = fgetc(hf);
        if (ch == '0') {
            hud_val = "0";
        }
        fclose(hf);
    }

    // Background-occlusion fps cap. Read once at launch from ~/.framelimiter.bgfps
    // (an integer >= 0; 0 disables the background throttle). Defaults to 10.
    char bgfps_val[16];
    strlcpy(bgfps_val, "10", sizeof(bgfps_val));
    FILE *bf = fopen(bgfps_file, "r");
    if (bf) {
        int v = -1;
        if (fscanf(bf, "%d", &v) == 1 && v >= 0) {
            snprintf(bgfps_val, sizeof(bgfps_val), "%d", v);
        }
        fclose(bf);
    }

    // Best-effort: bring up the menu-bar app in ephemeral mode, handing it OUR pid. After
    // execv this process becomes the game (pid preserved), so the app can watch this exact
    // pid and quit precisely when the game exits — independent of render/heartbeat timing,
    // so a slow first frame (shader compile, cold start) can't make it quit mid-load.
    // Launch by bundle id (no path baked in) BEFORE exporting DYLD_INSERT_LIBRARIES so
    // neither `open` nor the app inherits the injection. Failure is ignored.
    int mypid = (int)getpid();
    char owner_pid[16];
    snprintf(owner_pid, sizeof(owner_pid), "%d", mypid);

    char open_cmd[160];
    snprintf(open_cmd, sizeof(open_cmd),
             "open -g -b com.framelimiter.menu --args --auto --gamepid %d >/dev/null 2>&1", mypid);
    int rc_open = system(open_cmd);
    (void)rc_open;

    // Tag the main game process so the dylib's child-process guard can recognise it
    // (children the game spawns get fresh pids and the dylib stays inert in them).
    setenv("FRAME_LIMIT_OWNER_PID", owner_pid, 1);

    setenv("DYLD_INSERT_LIBRARIES", DYLIB_PATH, 1);
    setenv("FRAME_LIMIT_FPS", DEFAULT_FPS, 1);
    setenv("FRAME_LIMIT_FILE", fps_file, 1);
    setenv("FRAME_LIMIT_LOGFILE", log_file, 1);
    setenv("FRAME_LIMIT_LOG", "1", 1);
    setenv("FRAME_LIMIT_BG_FPS", bgfps_val, 1);
    setenv("MTL_HUD_ENABLED", hud_val, 0);

    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        fprintf(stderr, "Error: path buffer too small\n");
        return 1;
    }

    char abs_path[PATH_MAX];
    if (realpath(path, abs_path) == NULL) {
        strncpy(abs_path, path, sizeof(abs_path));
    }

    char target_path[PATH_MAX];
    snprintf(target_path, sizeof(target_path), "%s.real", abs_path);

    execv(target_path, argv);

    perror("execv failed");
    return 1;
}
