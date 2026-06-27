#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <limits.h>
#include <string.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
    const char *home = getenv("HOME");
    char fps_file[PATH_MAX];
    char log_file[PATH_MAX];
    char hud_file[PATH_MAX];
    if (home) {
        snprintf(fps_file, sizeof(fps_file), "%s/.framelimiter.fps", home);
        snprintf(log_file, sizeof(log_file), "%s/.framelimiter.log", home);
        snprintf(hud_file, sizeof(hud_file), "%s/.framelimiter.hud", home);
    } else {
        snprintf(fps_file, sizeof(fps_file), "/tmp/.framelimiter.fps");
        snprintf(log_file, sizeof(log_file), "/tmp/.framelimiter.log");
        snprintf(hud_file, sizeof(hud_file), "/tmp/.framelimiter.hud");
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

    setenv("DYLD_INSERT_LIBRARIES", DYLIB_PATH, 1);
    setenv("FRAME_LIMIT_FPS", DEFAULT_FPS, 1);
    setenv("FRAME_LIMIT_FILE", fps_file, 1);
    setenv("FRAME_LIMIT_LOGFILE", log_file, 1);
    setenv("FRAME_LIMIT_LOG", "1", 1);
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
