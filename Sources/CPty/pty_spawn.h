#ifndef JT_PTY_SPAWN_H
#define JT_PTY_SPAWN_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

int jt_pty_spawn(uint16_t cols, uint16_t rows,
                 uint32_t cell_width_px, uint32_t cell_height_px,
                 pid_t *child_out);

int jt_pty_spawn_ex(uint16_t cols, uint16_t rows,
                    uint32_t cell_width_px, uint32_t cell_height_px,
                    const char *cwd,
                    pid_t *child_out);

int jt_pty_ttyname(int master_fd, char *out, size_t cap);

int jt_pty_cwd(pid_t pid, char *out, size_t cap);

/* Shell cwd. Darwin `login` stays as the PTY child; the shell is its child. */
int jt_pty_session_cwd(int master_fd, pid_t child, char *out, size_t cap);

int jt_pty_set_winsize(int master_fd, uint16_t cols, uint16_t rows,
                       uint32_t cell_width_px, uint32_t cell_height_px);

/** Best-effort write; returns bytes written (may be short on EAGAIN). */
ssize_t jt_pty_write(int master_fd, const void *buf, size_t len);

int32_t jt_atomic_i32_load(const int32_t *p);
int32_t jt_atomic_i32_add(int32_t *p, int32_t v);

#ifdef __cplusplus
}
#endif

#endif
