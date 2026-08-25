#include "jt_vt_int.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

enum {
    APC_KEY = 0,
    APC_KEY_IGN,
    APC_VAL,
    APC_VAL_IGN,
    APC_DATA
};

static int kv_idx(uint8_t k) {
    if (k >= 'a' && k <= 'z') return k - 'a';
    if (k >= 'A' && k <= 'Z') return 26 + (k - 'A');
    return -1;
}

typedef struct {
    uint32_t kv[52];
    uint64_t present;
    uint8_t *payload;
    size_t payload_n;
    int ok;
} apc_cmd;

static int kv_has(const apc_cmd *c, uint8_t k) {
    int i = kv_idx(k);
    if (i < 0) return 0;
    return (c->present & (1ull << i)) != 0;
}

static uint32_t kv_u(const apc_cmd *c, uint8_t k, uint32_t d) {
    int i = kv_idx(k);
    if (i < 0 || !(c->present & (1ull << i))) return d;
    return c->kv[i];
}

static int32_t kv_i(const apc_cmd *c, uint8_t k, int32_t d) {
    int i = kv_idx(k);
    if (i < 0 || !(c->present & (1ull << i))) return d;
    return (int32_t)c->kv[i];
}

static void kv_put(apc_cmd *c, uint8_t k, uint32_t v) {
    int i = kv_idx(k);
    if (i < 0) return;
    c->kv[i] = v;
    c->present |= 1ull << i;
}

static int b64_val(uint8_t c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static int b64_decode(uint8_t *p, size_t n, size_t *out_n) {
    size_t o = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = p[i];
        if (c == '=' || c == '\n' || c == '\r' || c == ' ') continue;
        int v = b64_val(c);
        if (v < 0) return -1;
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            p[o++] = (uint8_t)((acc >> bits) & 0xFF);
        }
    }
    *out_n = o;
    return 0;
}

static int parse_u32(const char *s, int n, uint32_t *out) {
    if (n <= 0 || n > 10) return -1;
    uint64_t v = 0;
    for (int i = 0; i < n; i++) {
        if (s[i] < '0' || s[i] > '9') return -1;
        v = v * 10 + (uint64_t)(s[i] - '0');
        if (v > UINT32_MAX) return -1;
    }
    *out = (uint32_t)v;
    return 0;
}

static int parse_i32(const char *s, int n, int32_t *out) {
    if (n <= 0 || n > 11) return -1;
    int i = 0, sign = 1;
    if (s[0] == '-') {
        sign = -1;
        i = 1;
        if (n == 1) return -1;
    }
    uint64_t v = 0;
    for (; i < n; i++) {
        if (s[i] < '0' || s[i] > '9') return -1;
        v = v * 10 + (uint64_t)(s[i] - '0');
        if (v > 2147483648ull) return -1;
    }
    if (sign < 0) {
        if (v > 2147483648ull) return -1;
        *out = v == 2147483648ull ? INT32_MIN : -(int32_t)v;
    } else {
        if (v > 2147483647ull) return -1;
        *out = (int32_t)v;
    }
    return 0;
}

static int parse_cmd(const uint8_t *src, size_t n, apc_cmd *out) {
    memset(out, 0, sizeof *out);
    int st = APC_KEY;
    char tmp[12];
    int tn = 0;
    uint8_t key = 0;
    size_t i = 0;
    for (; i < n; i++) {
        uint8_t c = src[i];
        if (st == APC_DATA) break;
        switch (st) {
        case APC_KEY:
            if (c == '=') {
                if (tn != 1) {
                    st = APC_VAL_IGN;
                    tn = 0;
                } else {
                    key = (uint8_t)tmp[0];
                    tn = 0;
                    st = APC_VAL;
                }
            } else if (c == ';') {
                st = APC_DATA;
            } else {
                if (tn < 11) tmp[tn++] = (char)c;
                else {
                    st = APC_KEY_IGN;
                    tn = 0;
                }
            }
            break;
        case APC_KEY_IGN:
            if (c == '=') st = APC_VAL_IGN;
            else if (c == ';') st = APC_DATA;
            break;
        case APC_VAL:
            if (c == ',' || c == ';') {
                if (tn == 1 && (tmp[0] < '0' || tmp[0] > '9')) {
                    kv_put(out, key, (uint32_t)(uint8_t)tmp[0]);
                } else if (key == 'z' || key == 'H' || key == 'V') {
                    int32_t v;
                    if (parse_i32(tmp, tn, &v) != 0) return -1;
                    kv_put(out, key, (uint32_t)v);
                } else {
                    uint32_t v;
                    if (parse_u32(tmp, tn, &v) != 0) return -1;
                    kv_put(out, key, v);
                }
                tn = 0;
                st = (c == ';') ? APC_DATA : APC_KEY;
            } else {
                if (tn < 11) tmp[tn++] = (char)c;
                else {
                    st = APC_VAL_IGN;
                    tn = 0;
                }
            }
            break;
        case APC_VAL_IGN:
            if (c == ',') st = APC_KEY_IGN;
            else if (c == ';') st = APC_DATA;
            break;
        default:
            break;
        }
    }
    if (st == APC_KEY || st == APC_KEY_IGN) return -1;
    if (st == APC_VAL) {
        if (tn == 1 && (tmp[0] < '0' || tmp[0] > '9')) {
            kv_put(out, key, (uint32_t)(uint8_t)tmp[0]);
        } else if (key == 'z' || key == 'H' || key == 'V') {
            int32_t v;
            if (parse_i32(tmp, tn, &v) != 0) return -1;
            kv_put(out, key, (uint32_t)v);
        } else {
            uint32_t v;
            if (parse_u32(tmp, tn, &v) != 0) return -1;
            kv_put(out, key, v);
        }
        i = n;
        st = APC_DATA;
    }
    size_t dn = n > i ? n - i : 0;
    if (dn > 0) {
        uint8_t *buf = (uint8_t *)malloc(dn);
        if (!buf) return -1;
        memcpy(buf, src + i, dn);
        size_t out_n = 0;
        if (b64_decode(buf, dn, &out_n) != 0) {
            free(buf);
            return -1;
        }
        out->payload = buf;
        out->payload_n = out_n;
    }
    out->ok = 1;
    return 0;
}

static void reply(
    const jt_vt_host *h,
    uint32_t i,
    uint32_t I,
    uint32_t p,
    const char *msg,
    uint8_t quiet,
    int is_ok
) {
    if (!h || !h->write_pty) return;
    if (quiet >= 2) return;
    if (quiet == 1 && is_ok) return;
    if (i == 0 && I == 0) return;
    char buf[96];
    int n = 0;
    n += snprintf(buf + n, sizeof buf - (size_t)n, "\033_G");
    int prior = 0;
    if (i) {
        n += snprintf(buf + n, sizeof buf - (size_t)n, "i=%u", i);
        prior = 1;
    }
    if (I) {
        n += snprintf(buf + n, sizeof buf - (size_t)n, "%sI=%u", prior ? "," : "", I);
        prior = 1;
    }
    if (p) {
        n += snprintf(buf + n, sizeof buf - (size_t)n, "%sp=%u", prior ? "," : "", p);
    }
    n += snprintf(buf + n, sizeof buf - (size_t)n, ";%s\033\\", msg ? msg : "OK");
    if (n > 0) h->write_pty(h->ctx, (const uint8_t *)buf, (size_t)n);
}

void jt_apc_begin(jt_vt *p) {
    if (!p) return;
    p->apc_n = 0;
    p->apc_ignore = 0;
}

void jt_apc_reset(jt_vt *p) {
    if (!p) return;
    free(p->apc);
    p->apc = NULL;
    p->apc_n = 0;
    p->apc_cap = 0;
    p->apc_ignore = 0;
    p->apc_expect_g = 0;
    jt_img_abort_loading(&p->load);
}

void jt_apc_feed(jt_vt *p, const uint8_t *b, size_t n) {
    if (!p || !b || n == 0) return;
    if (p->apc_ignore) return;
    if (p->apc_n + (int)n > JT_IMG_MAX_APC) {
        p->apc_ignore = 1;
        p->apc_n = 0;
        static int once;
        if (!once) {
            once = 1;
            fputs("jetty: kitty-graphics: apc-overflow\n", stderr);
        }
        return;
    }
    int need = p->apc_n + (int)n;
    if (need > p->apc_cap) {
        int cap = p->apc_cap < 256 ? 256 : p->apc_cap * 2;
        while (cap < need) cap *= 2;
        if (cap > JT_IMG_MAX_APC) cap = JT_IMG_MAX_APC;
        uint8_t *q = (uint8_t *)realloc(p->apc, (size_t)cap);
        if (!q) {
            p->apc_ignore = 1;
            return;
        }
        p->apc = q;
        p->apc_cap = cap;
    }
    memcpy(p->apc + p->apc_n, b, n);
    p->apc_n += (int)n;
}

static int inflate_buf(const uint8_t *in, size_t in_n, uint8_t **out, size_t *out_n) {
    if (!in || in_n == 0) return -1;
    size_t cap = in_n * 4;
    if (cap < 4096) cap = 4096;
    if (cap > JT_IMG_MAX_BYTES) cap = JT_IMG_MAX_BYTES;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) return -1;
    z_stream zs;
    memset(&zs, 0, sizeof zs);
    zs.next_in = (Bytef *)in;
    zs.avail_in = (uInt)in_n;
    if (inflateInit(&zs) != Z_OK) {
        free(buf);
        return -1;
    }
    size_t n = 0;
    int ret;
    do {
        if (n >= cap) {
            size_t ncap = cap * 2;
            if (ncap > JT_IMG_MAX_BYTES) ncap = JT_IMG_MAX_BYTES;
            if (ncap <= cap) {
                inflateEnd(&zs);
                free(buf);
                return -1;
            }
            uint8_t *nb = (uint8_t *)realloc(buf, ncap);
            if (!nb) {
                inflateEnd(&zs);
                free(buf);
                return -1;
            }
            buf = nb;
            cap = ncap;
        }
        zs.next_out = buf + n;
        zs.avail_out = (uInt)(cap - n);
        ret = inflate(&zs, Z_NO_FLUSH);
        n = zs.total_out;
        if (ret == Z_STREAM_END) break;
        if (ret != Z_OK) {
            inflateEnd(&zs);
            free(buf);
            return -1;
        }
    } while (zs.avail_in > 0 || zs.avail_out == 0);
    inflateEnd(&zs);
    *out = buf;
    *out_n = n;
    return 0;
}

static int path_ok_read(const char *path) {
    if (!path || path[0] == 0) return 0;
    if (strncmp(path, "/proc", 5) == 0 && (path[5] == 0 || path[5] == '/')) return 0;
    if (strncmp(path, "/sys", 4) == 0 && (path[4] == 0 || path[4] == '/')) return 0;
    if (strncmp(path, "/dev/", 5) == 0) return 0;
    return 1;
}

static int path_ok_unlink(const char *path) {
    if (!path) return 0;
    if (!strstr(path, "tty-graphics-protocol")) return 0;
    const char *tmpdir = getenv("TMPDIR");
    if (strncmp(path, "/tmp/", 5) == 0) return 1;
    if (strncmp(path, "/private/tmp/", 13) == 0) return 1;
    if (tmpdir && tmpdir[0] && strncmp(path, tmpdir, strlen(tmpdir)) == 0) {
        size_t n = strlen(tmpdir);
        if (path[n] == 0 || path[n] == '/') return 1;
    }
    return 0;
}

static int read_file_window(
    const char *path,
    uint32_t S,
    uint32_t O,
    uint8_t **out,
    size_t *out_n
) {
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) return -1;
    if (!path_ok_read(resolved)) return -1;
    int fd = open(resolved, O_RDONLY);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return -1;
    }
    off_t off = (off_t)O;
    size_t want = S ? S : (size_t)st.st_size;
    if (off > st.st_size) {
        close(fd);
        return -1;
    }
    if ((size_t)off + want > (size_t)st.st_size) want = (size_t)st.st_size - (size_t)off;
    if (want > JT_IMG_MAX_BYTES) want = JT_IMG_MAX_BYTES;
    uint8_t *buf = (uint8_t *)malloc(want ? want : 1);
    if (!buf) {
        close(fd);
        return -1;
    }
    if (off && lseek(fd, off, SEEK_SET) != off) {
        free(buf);
        close(fd);
        return -1;
    }
    size_t got = 0;
    while (got < want) {
        ssize_t r = read(fd, buf + got, want - got);
        if (r < 0) {
            if (errno == EINTR) continue;
            free(buf);
            close(fd);
            return -1;
        }
        if (r == 0) break;
        got += (size_t)r;
    }
    close(fd);
    *out = buf;
    *out_n = got;
    return 0;
}

static int read_shm(const char *name, uint32_t S, uint32_t O, uint8_t **out, size_t *out_n) {
    if (!name || name[0] == 0) return -1;
    char nbuf[256];
    if (name[0] != '/') {
        snprintf(nbuf, sizeof nbuf, "/%s", name);
        name = nbuf;
    }
    int fd = shm_open(name, O_RDONLY, 0);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return -1;
    }
    size_t total = (size_t)st.st_size;
    size_t off = (size_t)O;
    size_t want = S ? S : (total > off ? total - off : 0);
    if (off > total) {
        close(fd);
        return -1;
    }
    if (off + want > total) want = total - off;
    if (want > JT_IMG_MAX_BYTES) want = JT_IMG_MAX_BYTES;
    void *map = mmap(NULL, total, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return -1;
    uint8_t *buf = (uint8_t *)malloc(want ? want : 1);
    if (!buf) {
        munmap(map, total);
        return -1;
    }
    memcpy(buf, (uint8_t *)map + off, want);
    munmap(map, total);
    shm_unlink(name);
    *out = buf;
    *out_n = want;
    return 0;
}

static int append_load(jt_img_loading *ld, const uint8_t *p, size_t n) {
    if (n == 0) return 0;
    if (ld->n + n > JT_IMG_MAX_BYTES) return -1;
    if (ld->n + n > ld->cap) {
        size_t cap = ld->cap < 4096 ? 4096 : ld->cap * 2;
        while (cap < ld->n + n) cap *= 2;
        if (cap > JT_IMG_MAX_BYTES) cap = JT_IMG_MAX_BYTES;
        uint8_t *q = (uint8_t *)realloc(ld->data, cap);
        if (!q) return -1;
        ld->data = q;
        ld->cap = cap;
    }
    memcpy(ld->data + ld->n, p, n);
    ld->n += n;
    return 0;
}

static void fill_loading_from_cmd(jt_img_loading *ld, const apc_cmd *c) {
    uint8_t a = (uint8_t)kv_u(c, 'a', 't');
    ld->action = a;
    ld->quiet = (uint8_t)kv_u(c, 'q', 0);
    uint32_t f = kv_u(c, 'f', 32);
    ld->format = f == 0 ? 32 : (uint8_t)f;
    uint32_t t = kv_u(c, 't', 'd');
    ld->medium = t ? (uint8_t)t : 'd';
    uint32_t o = kv_u(c, 'o', 0);
    ld->compress = o == 'z' ? 1 : 0;
    ld->w = kv_u(c, 's', 0);
    ld->h = kv_u(c, 'v', 0);
    ld->S = kv_u(c, 'S', 0);
    ld->O = kv_u(c, 'O', 0);
    ld->image_id = kv_u(c, 'i', 0);
    ld->number = kv_u(c, 'I', 0);
    ld->placement_id = kv_u(c, 'p', 0);
    ld->z = kv_i(c, 'z', 0);
    ld->src_x = kv_u(c, 'x', 0);
    ld->src_y = kv_u(c, 'y', 0);
    ld->src_w = kv_u(c, 'w', 0);
    ld->src_h = kv_u(c, 'h', 0);
    ld->cols = kv_u(c, 'c', 0);
    ld->rows = kv_u(c, 'r', 0);
    ld->off_x = kv_u(c, 'X', 0);
    ld->off_y = kv_u(c, 'Y', 0);
    ld->no_cursor = kv_u(c, 'C', 0) == 1;
    ld->has_display = (a == 'T' || a == 'p');
}

static int pixels_from_raw(jt_img_loading *ld, uint8_t **rgba, uint32_t *w, uint32_t *h) {
    uint32_t W = ld->w, H = ld->h;
    if (W == 0 || H == 0 || W > JT_IMG_MAX_DIM || H > JT_IMG_MAX_DIM) return -1;
    size_t bpp = ld->format == 24 ? 3 : 4;
    if (ld->n != (size_t)W * (size_t)H * bpp) return -1;
    if ((size_t)W * (size_t)H * 4 > JT_IMG_MAX_BYTES) return -1;
    if (ld->format == 24) {
        uint8_t *out = jt_img_rgb_to_rgba(ld->data, W, H);
        if (!out) return -1;
        *rgba = out;
    } else {
        uint8_t *out = (uint8_t *)malloc(ld->n);
        if (!out) return -1;
        memcpy(out, ld->data, ld->n);
        *rgba = out;
    }
    *w = W;
    *h = H;
    return 0;
}

static int complete_transmit(
    jt_vt *p,
    jt_scr *scr,
    const jt_vt_host *h,
    int query_only
) {
    jt_img_loading *ld = &p->load;
    uint8_t quiet = ld->quiet;
    uint32_t echo_i = ld->image_id;
    uint32_t echo_I = ld->number;
    uint32_t echo_p = ld->placement_id;

    if (ld->image_id && ld->number) {
        jt_img_abort_loading(ld);
        reply(h, echo_i, echo_I, echo_p, "EINVAL", quiet, 0);
        return -1;
    }

    uint8_t *bytes = ld->data;
    size_t nbytes = ld->n;
    uint8_t *owned = NULL;
    int hopped = 0;

    int need_io = ld->medium == 'f' || ld->medium == 't' || ld->medium == 's'
        || ld->format == 100 || (ld->compress && nbytes > 64 * 1024);
    if (need_io && h && h->unlock_for_io) {
        h->unlock_for_io(h->ctx);
        hopped = 1;
    }

    int io_err = 0;
    if (ld->medium == 'f' || ld->medium == 't') {
        char path[PATH_MAX];
        if (nbytes >= sizeof path) io_err = 1;
        else {
            memcpy(path, bytes, nbytes);
            path[nbytes] = 0;
            if (path[0] != '/') {
                char cwd[PATH_MAX];
                if (!getcwd(cwd, sizeof cwd)) io_err = 1;
                else {
                    char joined[PATH_MAX];
                    snprintf(joined, sizeof joined, "%s/%s", cwd, path);
                    strncpy(path, joined, sizeof path - 1);
                    path[sizeof path - 1] = 0;
                }
            }
            uint8_t *file = NULL;
            size_t fn = 0;
            if (!io_err && read_file_window(path, ld->S, ld->O, &file, &fn) != 0) io_err = 1;
            else if (!io_err) {
                owned = file;
                bytes = file;
                nbytes = fn;
            }
            if (!io_err && ld->medium == 't') {
                char resolved[PATH_MAX];
                if (realpath(path, resolved) && path_ok_unlink(resolved)) unlink(resolved);
            }
        }
    } else if (ld->medium == 's') {
        char name[256];
        if (nbytes >= sizeof name) io_err = 1;
        else {
            memcpy(name, bytes, nbytes);
            name[nbytes] = 0;
            uint8_t *shm = NULL;
            size_t sn = 0;
            if (read_shm(name, ld->S, ld->O, &shm, &sn) != 0) io_err = 1;
            else {
                owned = shm;
                bytes = shm;
                nbytes = sn;
            }
        }
    }

    if (!io_err && ld->compress) {
        uint8_t *inf = NULL;
        size_t inf_n = 0;
        if (inflate_buf(bytes, nbytes, &inf, &inf_n) != 0) io_err = 1;
        else {
            if (owned) free(owned);
            owned = inf;
            bytes = inf;
            nbytes = inf_n;
        }
    }

    uint8_t *rgba = NULL;
    uint32_t iw = 0, ih = 0;
    if (!io_err && ld->format == 100) {
        if (!h || !h->png_decode) io_err = 1;
        else if (h->png_decode(h->ctx, bytes, nbytes, &rgba, &iw, &ih) != 0) io_err = 1;
    } else if (!io_err && (ld->format == 24 || ld->format == 32)) {
        /* temporarily point loading data at decoded bytes */
        uint8_t *saved = ld->data;
        size_t saved_n = ld->n;
        ld->data = bytes;
        ld->n = nbytes;
        if (pixels_from_raw(ld, &rgba, &iw, &ih) != 0) io_err = 1;
        ld->data = saved;
        ld->n = saved_n;
    } else if (!io_err) {
        io_err = 1;
    }

    if (hopped && h && h->relock) h->relock(h->ctx);

    if (owned && owned != ld->data) free(owned);

    if (io_err || !rgba) {
        free(rgba);
        jt_img_abort_loading(ld);
        reply(h, echo_i, echo_I, echo_p, "EINVAL", quiet, 0);
        return -1;
    }
    if (iw > JT_IMG_MAX_DIM || ih > JT_IMG_MAX_DIM || (size_t)iw * (size_t)ih * 4 > JT_IMG_MAX_BYTES) {
        free(rgba);
        jt_img_abort_loading(ld);
        reply(h, echo_i, echo_I, echo_p, "EINVAL", quiet, 0);
        return -1;
    }

    if (query_only) {
        free(rgba);
        jt_img_abort_loading(ld);
        if (echo_i == 0 && echo_I == 0) {
            /* no reply */
        } else {
            reply(h, echo_i, echo_I, echo_p, "OK", quiet, 1);
        }
        return 0;
    }

    uint32_t id = ld->image_id;
    if (id == 0 && ld->number == 0) id = 0;
    int rc = jt_img_add(scr, &id, ld->number, rgba, iw, ih);
    if (rc != 0) {
        jt_img_abort_loading(ld);
        reply(h, echo_i ? echo_i : id, echo_I, echo_p, rc == -2 ? "ENOSPC" : "EINVAL", quiet, 0);
        return -1;
    }
    ld->image_id = id;
    echo_i = id;
    if (ld->action == 'T') {
        if (jt_img_put(scr, ld) != 0) {
            jt_img_abort_loading(ld);
            reply(h, echo_i, echo_I, echo_p, "EINVAL", quiet, 0);
            return -1;
        }
    }
    jt_img_abort_loading(ld);
    reply(h, echo_i, echo_I, echo_p, "OK", quiet, 1);
    return 0;
}

static void execute(jt_vt *p, jt_scr *scr, const jt_vt_host *h, apc_cmd *c) {
    uint8_t a;
    if (!kv_has(c, 'a') && p->load.active) a = p->load.action;
    else a = (uint8_t)kv_u(c, 'a', 't');
    uint8_t quiet = (uint8_t)kv_u(c, 'q', p->load.active ? p->load.quiet : 0);
    uint32_t i = kv_u(c, 'i', 0);
    uint32_t I = kv_u(c, 'I', 0);
    uint32_t pid = kv_u(c, 'p', 0);
    uint8_t m = (uint8_t)kv_u(c, 'm', 0);
    uint8_t t = (uint8_t)kv_u(c, 't', 'd');

    if (a == 'd') {
        jt_img_abort_loading(&p->load);
        uint8_t d = (uint8_t)kv_u(c, 'd', 'a');
        int32_t z = kv_i(c, 'z', 0);
        uint32_t x = kv_u(c, 'x', 0);
        uint32_t y = kv_u(c, 'y', 0);
        if (d == 'f' || d == 'F') {
            reply(h, i, I, pid, "ENOTSUP", quiet, 0);
            return;
        }
        int rc = jt_img_delete(scr, d, i, I, pid, x, y, z);
        if (rc == -3) reply(h, i, I, pid, "ENOTSUP", quiet, 0);
        else reply(h, i, I, pid, "OK", quiet, 1);
        return;
    }

    if (a == 'f' || a == 'a' || a == 'c') {
        if (i || I) reply(h, i, I, pid, "ENOTSUP", quiet, 0);
        jt_img_abort_loading(&p->load);
        return;
    }

    if (kv_u(c, 'U', 0) != 0 || kv_u(c, 'P', 0) != 0) {
        jt_img_abort_loading(&p->load);
        reply(h, i, I, pid, "ENOTSUP", quiet, 0);
        return;
    }

    if (a != 't' && a != 'T' && a != 'q' && a != 'p') {
        jt_img_abort_loading(&p->load);
        if (i || I) reply(h, i, I, pid, "EINVAL", quiet, 0);
        return;
    }

    if (a == 'p') {
        jt_img_abort_loading(&p->load);
        jt_img_loading tmp;
        memset(&tmp, 0, sizeof tmp);
        fill_loading_from_cmd(&tmp, c);
        if (tmp.image_id == 0 && tmp.number) {
            jt_img *im = jt_img_find_number(jt_img_active(scr), tmp.number);
            if (im) tmp.image_id = im->id;
        }
        int rc = jt_img_put(scr, &tmp);
        uint32_t echo = tmp.image_id;
        if (rc != 0) reply(h, i ? i : echo, I, pid, rc == -1 ? "ENOENT" : "EINVAL", quiet, 0);
        else reply(h, i ? i : echo, I, pid, "OK", quiet, 1);
        return;
    }

    /* transmit / query / T */
    int continuation = p->load.active && (m == 0 || m == 1) && t != 'd' ? 0 : 0;
    (void)continuation;
    if (t != 'd') m = 0; /* ignore m unless direct */

    if (p->load.active && m == 1 && a == p->load.action) {
        if (append_load(&p->load, c->payload, c->payload_n) != 0) {
            jt_img_abort_loading(&p->load);
            reply(h, i, I, pid, "ENOSPC", quiet, 0);
        }
        return;
    }
    if (p->load.active && m == 0 && a == p->load.action) {
        if (append_load(&p->load, c->payload, c->payload_n) != 0) {
            jt_img_abort_loading(&p->load);
            reply(h, i, I, pid, "ENOSPC", quiet, 0);
            return;
        }
        p->load.more = 0;
        complete_transmit(p, scr, h, p->load.action == 'q');
        return;
    }
    if (p->load.active) jt_img_abort_loading(&p->load);

    fill_loading_from_cmd(&p->load, c);
    p->load.active = 1;
    p->load.generation++;
    if (append_load(&p->load, c->payload, c->payload_n) != 0) {
        jt_img_abort_loading(&p->load);
        reply(h, i, I, pid, "ENOSPC", quiet, 0);
        return;
    }
    if (m == 1 && t == 'd') {
        p->load.more = 1;
        return;
    }
    complete_transmit(p, scr, h, a == 'q');
}

void jt_apc_finish(jt_vt *p, jt_scr *scr, const jt_vt_host *h) {
    if (!p) return;
    if (p->apc_ignore) {
        p->apc_n = 0;
        p->apc_ignore = 0;
        return;
    }
    if (!scr || !scr->kitty_graphics) {
        p->apc_n = 0;
        return;
    }
    apc_cmd c;
    if (parse_cmd(p->apc, (size_t)p->apc_n, &c) != 0) {
        p->apc_n = 0;
        return;
    }
    p->apc_n = 0;
    execute(p, scr, h, &c);
    free(c.payload);
}
