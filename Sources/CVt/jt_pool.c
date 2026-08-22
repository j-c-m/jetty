#include "jt_vt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define JT_GP_CAP 4096
#define JT_GP_MAX 16
#define JT_RARE_CAP 1024

typedef struct jt_gp {
    uint32_t cps[JT_GP_CAP][JT_GP_MAX];
    uint16_t n[JT_GP_CAP];
    uint16_t refs[JT_GP_CAP];
    uint16_t used;
    uint8_t overflow;
} jt_gp;

typedef struct jt_rp {
    char *osc8_id[JT_RARE_CAP];
    char *uri[JT_RARE_CAP];
    uint32_t ul[JT_RARE_CAP];
    uint16_t refs[JT_RARE_CAP];
    uint16_t used;
    uint8_t overflow;
} jt_rp;

static jt_gp *gp_of(jt_scr *s) { return s ? (jt_gp *)s->gp : NULL; }
static const jt_gp *gp_of_c(const jt_scr *s) { return s ? (const jt_gp *)s->gp : NULL; }
static jt_rp *rp_of(jt_scr *s) { return s ? (jt_rp *)s->rp : NULL; }
static const jt_rp *rp_of_c(const jt_scr *s) { return s ? (const jt_rp *)s->rp : NULL; }

static char *dup_str(const char *s) {
    if (!s || !s[0]) return NULL;
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

void jt_pools_init(jt_scr *s) {
    if (!s) return;
    s->gp = calloc(1, sizeof(jt_gp));
    s->rp = calloc(1, sizeof(jt_rp));
}

void jt_pools_deinit(jt_scr *s) {
    if (!s) return;
    jt_rp *rp = rp_of(s);
    if (rp) {
        for (uint16_t i = 0; i < rp->used; i++) {
            free(rp->osc8_id[i]);
            free(rp->uri[i]);
        }
        free(rp);
        s->rp = NULL;
    }
    free(s->gp);
    s->gp = NULL;
    free(s->osc8_id);
    free(s->osc8_uri);
    s->osc8_id = NULL;
    s->osc8_uri = NULL;
}

static int cps_eq(const uint32_t *a, uint16_t na, const uint32_t *b, uint16_t nb) {
    if (na != nb) return 0;
    return memcmp(a, b, (size_t)na * sizeof(uint32_t)) == 0;
}

uint32_t jt_grapheme_intern(jt_scr *s, const uint32_t *cps, uint16_t n) {
    jt_gp *g = gp_of(s);
    if (!g || !cps || n == 0 || n > JT_GP_MAX) return 0;
    for (uint16_t i = 0; i < g->used; i++) {
        if (cps_eq(g->cps[i], g->n[i], cps, n)) return (uint32_t)(i + 1);
    }
    int slot = -1;
    if (g->used < JT_GP_CAP) {
        slot = (int)g->used++;
    } else {
        for (uint16_t i = 0; i < g->used; i++) {
            if (g->refs[i] == 0) {
                slot = (int)i;
                break;
            }
        }
    }
    if (slot < 0) {
        if (!g->overflow) {
            fputs("jetty: grapheme pool full\n", stderr);
            g->overflow = 1;
        }
        return 0;
    }
    memcpy(g->cps[slot], cps, (size_t)n * sizeof(uint32_t));
    if (n < JT_GP_MAX) memset(g->cps[slot] + n, 0, (size_t)(JT_GP_MAX - n) * sizeof(uint32_t));
    g->n[slot] = n;
    g->refs[slot] = 0;
    return (uint32_t)(slot + 1);
}

const uint32_t *jt_grapheme_get(const jt_scr *s, uint32_t id, uint16_t *n) {
    const jt_gp *g = gp_of_c(s);
    if (!g || id == 0 || id > g->used) {
        if (n) *n = 0;
        return NULL;
    }
    if (n) *n = g->n[id - 1];
    return g->cps[id - 1];
}

void jt_grapheme_retain(jt_scr *s, uint32_t id) {
    jt_gp *g = gp_of(s);
    if (!g || id == 0 || id > g->used) return;
    if (g->refs[id - 1] < 0xFFFFu) g->refs[id - 1]++;
}

void jt_grapheme_release(jt_scr *s, uint32_t id) {
    jt_gp *g = gp_of(s);
    if (!g || id == 0 || id > g->used) return;
    if (g->refs[id - 1] > 0) g->refs[id - 1]--;
}

static int str_eq(const char *a, const char *b) {
    if (!a || !a[0]) return !b || !b[0];
    if (!b || !b[0]) return 0;
    return strcmp(a, b) == 0;
}

uint16_t jt_rare_intern(jt_scr *s, const char *osc8_id, const char *uri, uint32_t ul) {
    jt_rp *r = rp_of(s);
    if (!r) return 0;
    for (uint16_t i = 0; i < r->used; i++) {
        if (r->ul[i] == ul && str_eq(r->osc8_id[i], osc8_id) && str_eq(r->uri[i], uri))
            return (uint16_t)(i + 1);
    }
    int slot = -1;
    if (r->used < JT_RARE_CAP) {
        slot = (int)r->used++;
    } else {
        for (uint16_t i = 0; i < r->used; i++) {
            if (r->refs[i] == 0) {
                slot = (int)i;
                break;
            }
        }
    }
    if (slot < 0) {
        if (!r->overflow) {
            fputs("jetty: rare pool full\n", stderr);
            r->overflow = 1;
        }
        return 0;
    }
    free(r->osc8_id[slot]);
    free(r->uri[slot]);
    r->osc8_id[slot] = NULL;
    r->uri[slot] = NULL;
    r->osc8_id[slot] = dup_str(osc8_id);
    r->uri[slot] = dup_str(uri);
    r->ul[slot] = ul;
    r->refs[slot] = 0;
    return (uint16_t)(slot + 1);
}

int jt_rare_get(const jt_scr *s, uint16_t id, jt_rare *out) {
    const jt_rp *r = rp_of_c(s);
    if (!r || !out || id == 0 || id > r->used) return 0;
    out->osc8_id = r->osc8_id[id - 1];
    out->uri = r->uri[id - 1];
    out->ul_color = r->ul[id - 1];
    return 1;
}

void jt_rare_retain(jt_scr *s, uint16_t id) {
    jt_rp *r = rp_of(s);
    if (!r || id == 0 || id > r->used) return;
    if (r->refs[id - 1] < 0xFFFFu) r->refs[id - 1]++;
}

void jt_rare_release(jt_scr *s, uint16_t id) {
    jt_rp *r = rp_of(s);
    if (!r || id == 0 || id > r->used) return;
    if (r->refs[id - 1] > 0) r->refs[id - 1]--;
}

void jt_pen_refresh_extra(jt_scr *s) {
    if (!s) return;
    if (s->pen.extra) jt_rare_release(s, s->pen.extra);
    s->pen.extra = 0;
    int has_ul = s->pen.ul_color != COLOR_DEFAULT && s->pen.ul_color != 0;
    int has_link = (s->osc8_uri && s->osc8_uri[0]) || (s->osc8_id && s->osc8_id[0]);
    if (!has_ul && !has_link) return;
    uint16_t id = jt_rare_intern(s, s->osc8_id, s->osc8_uri, s->pen.ul_color);
    if (!id) return;
    s->pen.extra = id;
    jt_rare_retain(s, id);
}
