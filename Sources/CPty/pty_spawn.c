#include "pty_spawn.h"
#include "../CVt/jt_version.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/ttycom.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

static void set_term_identity(void) {
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
    setenv("TERM_PROGRAM", "jetty", 1);
    setenv("TERM_PROGRAM_VERSION", JT_VERSION, 1);
}

static const char *resolve_shell(const struct passwd *pw) {
    const char *shell = getenv("SHELL");
    if (shell && shell[0])
        return shell;
    if (pw && pw->pw_shell && pw->pw_shell[0])
        return pw->pw_shell;
    return "/bin/zsh";
}

/* Finder / `open` give the .app cwd /. Darwin login -flp keeps it. */
static void chdir_home_if_root(void) {
    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof cwd) && strcmp(cwd, "/") != 0)
        return;
    const char *home = getenv("HOME");
    if (!home || !home[0]) {
        struct passwd *pw = getpwuid(getuid());
        home = (pw && pw->pw_dir && pw->pw_dir[0]) ? pw->pw_dir : NULL;
    }
    if (!home)
        return;
    if (chdir(home) != 0) {
        dprintf(STDERR_FILENO, "jetty: chdir %s: %s\n", home, strerror(errno));
    }
}

static void exec_login_shell(void) {
    set_term_identity();

    struct passwd *pw = getpwuid(getuid());
    if (!pw || !pw->pw_name || !pw->pw_name[0]) {
        const char *shell = resolve_shell(NULL);
        execl(shell, shell, "-l", (char *)NULL);
        dprintf(STDERR_FILENO, "jetty: exec shell %s failed: %s\n",
                shell, strerror(errno));
        _exit(127);
    }

    int hush = 0;
    if (pw->pw_dir && pw->pw_dir[0]) {
        char hush_path[4096];
        int n = snprintf(hush_path, sizeof(hush_path), "%s/.hushlogin", pw->pw_dir);
        if (n > 0 && (size_t)n < sizeof(hush_path) && access(hush_path, F_OK) == 0)
            hush = 1;
    }

    const char *shell = resolve_shell(pw);
    char exec_cmd[4096];
    int cn = snprintf(exec_cmd, sizeof(exec_cmd), "exec -l %s", shell);
    if (cn <= 0 || (size_t)cn >= sizeof(exec_cmd)) {
        dprintf(STDERR_FILENO, "jetty: shell path too long\n");
        _exit(127);
    }

    if (hush) {
        execl("/usr/bin/login", "login", "-q", "-flp", pw->pw_name,
              "/bin/bash", "--noprofile", "--norc", "-c", exec_cmd, (char *)NULL);
    } else {
        execl("/usr/bin/login", "login", "-flp", pw->pw_name,
              "/bin/bash", "--noprofile", "--norc", "-c", exec_cmd, (char *)NULL);
    }
    dprintf(STDERR_FILENO, "jetty: exec login -flp failed: %s\n",
            strerror(errno));
    _exit(127);
}

int jt_pty_spawn(uint16_t cols, uint16_t rows,
                 uint32_t cell_width_px, uint32_t cell_height_px,
                 pid_t *child_out) {
    return jt_pty_spawn_ex(cols, rows, cell_width_px, cell_height_px, NULL, child_out);
}

int jt_pty_spawn_ex(uint16_t cols, uint16_t rows,
                    uint32_t cell_width_px, uint32_t cell_height_px,
                    const char *cwd,
                    pid_t *child_out) {
    if (!child_out) {
        return -1;
    }

    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = (unsigned short)(cols * cell_width_px),
        .ws_ypixel = (unsigned short)(rows * cell_height_px),
    };

    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, &ws);
    if (child < 0) {
        return -1;
    }

    if (child == 0) {
        if (cwd && cwd[0]) {
            if (chdir(cwd) != 0) {
                dprintf(STDERR_FILENO, "jetty: chdir %s: %s\n", cwd, strerror(errno));
                _exit(127);
            }
        } else {
            chdir_home_if_root();
        }
        exec_login_shell();
    }

    int flags = fcntl(master, F_GETFL);
    if (flags < 0 || fcntl(master, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(master);
        return -1;
    }

    *child_out = child;
    return master;
}

int jt_pty_ttyname(int master_fd, char *out, size_t cap) {
    if (master_fd < 0 || !out || cap == 0) return -1;
#if defined(__APPLE__)
    char name[128];
    if (ioctl(master_fd, TIOCPTYGNAME, name) != 0) return -1;
    name[sizeof name - 1] = '\0';
    size_t n = strlen(name);
    if (n + 1 > cap) return -1;
    memcpy(out, name, n + 1);
    return 0;
#else
    (void)master_fd;
    return -1;
#endif
}

int jt_pty_set_winsize(int master_fd, uint16_t cols, uint16_t rows,
                       uint32_t cell_width_px, uint32_t cell_height_px) {
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = (unsigned short)(cols * cell_width_px),
        .ws_ypixel = (unsigned short)(rows * cell_height_px),
    };
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

ssize_t jt_pty_write(int master_fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(master_fd, p, left);
        if (n > 0) {
            p += (size_t)n;
            left -= (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    return (ssize_t)(len - left);
}

int32_t jt_atomic_i32_load(const int32_t *p) {
    return __atomic_load_n(p, __ATOMIC_RELAXED);
}

int32_t jt_atomic_i32_add(int32_t *p, int32_t v) {
    return __atomic_fetch_add(p, v, __ATOMIC_RELAXED);
}
