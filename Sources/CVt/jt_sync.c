/* DEC 2026 synchronized output hold buffer. */
#include "jt_vt_int.h"

#include <stdlib.h>
#include <string.h>

#define JT_SYNC_BUF 0x200000
#define JT_SYNC_ESC 8

static const uint8_t JT_BSU[JT_SYNC_ESC] = {0x1B, '[', '?', '2', '0', '2', '6', 'h'};
static const uint8_t JT_ESU[JT_SYNC_ESC] = {0x1B, '[', '?', '2', '0', '2', '6', 'l'};

void jt_sync_set(jt_scr *s, int on) {
    if (!s) return;
    if (on) {
        __atomic_store_n(&s->sync_output, 1, __ATOMIC_RELEASE);
        __atomic_fetch_add(&s->sync_epoch, 1, __ATOMIC_RELEASE);
    } else {
        __atomic_store_n(&s->sync_output, 0, __ATOMIC_RELEASE);
    }
}

int jt_sync_on(const jt_scr *s) {
    return s && __atomic_load_n(&s->sync_output, __ATOMIC_ACQUIRE);
}

uint32_t jt_sync_epoch(const jt_scr *s) {
    return s ? __atomic_load_n(&s->sync_epoch, __ATOMIC_ACQUIRE) : 0;
}

void jt_sync_timeout_clear(jt_scr *s) {
    if (s) __atomic_store_n(&s->sync_output, 0, __ATOMIC_RELEASE);
}

static int sync_ensure(jt_vt *p) {
    if (p->sync_buf) return 1;
    p->sync_buf = (uint8_t *)malloc(JT_SYNC_BUF);
    if (!p->sync_buf) return 0;
    p->sync_cap = JT_SYNC_BUF;
    p->sync_n = 0;
    return 1;
}

void sync_apply(jt_vt *p, jt_scr *scr, const jt_vt_host *h, size_t off) {
    if (off > p->sync_n) off = p->sync_n;
    p->sync_applying = 1;
    p->syncing = 0;
    if (off > 0 && p->sync_buf)
        jt_vt_feed(p, p->sync_buf, off, scr, h);
    if (off < p->sync_n && p->sync_buf) {
        size_t tail = p->sync_n - off;
        memmove(p->sync_buf, p->sync_buf + off, tail);
        p->sync_n = tail;
        p->syncing = 1;
        jt_sync_set(scr, 1);
    } else {
        p->sync_n = 0;
        p->syncing = 0;
        jt_sync_set(scr, 0);
    }
    p->sync_applying = 0;
}

static void sync_scan(jt_vt *p, jt_scr *scr, const jt_vt_host *h, size_t new_n) {
    size_t buf_len = p->sync_n;
    size_t start = buf_len - new_n;
    if (start >= JT_SYNC_ESC - 1) start -= JT_SYNC_ESC - 1;
    else start = 0;
    size_t end = buf_len;
    if (end >= JT_SYNC_ESC - 1) end -= JT_SYNC_ESC - 1;
    else return;
    if (end <= start || !p->sync_buf) return;
    size_t bsu = (size_t)-1;
    size_t i = end;
    while (i > start) {
        i--;
        if (p->sync_buf[i] != 0x1B) continue;
        if (i + JT_SYNC_ESC > buf_len) continue;
        if (memcmp(p->sync_buf + i, JT_BSU, JT_SYNC_ESC) == 0) {
            jt_sync_set(scr, 1);
            bsu = i;
        } else if (memcmp(p->sync_buf + i, JT_ESU, JT_SYNC_ESC) == 0) {
            sync_apply(p, scr, h, bsu != (size_t)-1 ? bsu : buf_len);
            return;
        }
    }
}

void sync_buf_in(jt_vt *p, jt_scr *scr, const jt_vt_host *h,
                       const uint8_t *bytes, size_t n) {
    if (!bytes || n == 0) return;
    if (!sync_ensure(p) || p->sync_n + n >= p->sync_cap - 1) {
        size_t held = p->sync_n;
        sync_apply(p, scr, h, held);
        jt_vt_feed(p, bytes, n, scr, h);
        return;
    }
    memcpy(p->sync_buf + p->sync_n, bytes, n);
    p->sync_n += n;
    sync_scan(p, scr, h, n);
}

size_t jt_vt_sync_bytes(const jt_vt *p) {
    return p ? p->sync_n : 0;
}

void jt_vt_sync_timeout(jt_vt *p, jt_scr *scr, const jt_vt_host *host) {
    if (!p) return;
    if (p->syncing && p->sync_n)
        sync_apply(p, scr, host, p->sync_n);
    else {
        p->syncing = 0;
        p->sync_n = 0;
        jt_sync_set(scr, 0);
    }
}

void jt_vt_sync_drop(jt_vt *p, jt_scr *scr) {
    if (!p) return;
    p->sync_n = 0;
    p->syncing = 0;
    p->sync_applying = 0;
    jt_sync_set(scr, 0);
}
