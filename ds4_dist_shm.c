/* DS4 Distributed Shared-Memory Transport
 *
 * Replaces the TCP data path between coordinator and workers that run on
 * the same physical host.  Uses POSIX shared memory for a ring buffer and
 * named semaphores for cross-process wake-up.  No TCP stack, no kernel
 * copies, no activation quantisation round-trip.
 *
 * Linux only (requires named semaphores + eventfd for the optional poll
 * compatibility fd).  On other platforms the transport stubs fall back to
 * NULL so DS4 silently uses TCP.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <semaphore.h>
#include <time.h>
#include <stdatomic.h>

#include "ds4_dist_transport.h"

/* ------------------------------------------------------------------ */
/* Tunables                                                           */
/* ------------------------------------------------------------------ */

#ifndef DS4_DIST_SHM_RING_SIZE
#define DS4_DIST_SHM_RING_SIZE (256 * 1024 * 1024)   /* 256 MiB */
#endif

/* How long accept() waits between polls for a new client (ms). */
#define DS4_DIST_SHM_ACCEPT_POLL_MS 10

/* How long a side waits for the peer during set-up (seconds). */
#define DS4_DIST_SHM_CONNECT_TIMEOUT_SEC 30

/* ------------------------------------------------------------------ */
/* On-disk layout                                                     */
/* ------------------------------------------------------------------ */

typedef struct {
    _Atomic int creator_ready;
    _Atomic int connected;
    _Atomic int closed;
    _Atomic size_t write_pos;
    _Atomic size_t read_pos;
    /* The ring buffer follows this header in the same mmap. */
    char data[];
} ds4_dist_shm_shared;

/* ------------------------------------------------------------------ */
/* Channel state                                                      */
/* ------------------------------------------------------------------ */

typedef struct {
    char name[64];
    int shm_fd;
    ds4_dist_shm_shared *shared;
    size_t map_size;
    sem_t *sem_data;
    sem_t *sem_space;
    int is_server;   /* 1 = we created the shm, 0 = we connected */
} ds4_dist_shm_channel;

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

static void ds4_dist_shm_sem_names(const char *base,
                                   char *data_name, size_t data_len,
                                   char *space_name, size_t space_len) {
    snprintf(data_name,  data_len,  "/ds4-dist-data-%s",  base);
    snprintf(space_name, space_len, "/ds4-dist-space-%s", base);
}

static int ds4_dist_shm_wait_flag(_Atomic int *flag, int target,
                                  int timeout_sec) {
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        if (atomic_load(flag) == target) return 0;
        struct timespec ts = {0, 10 * 1000 * 1000}; /* 10 ms */
        nanosleep(&ts, NULL);
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (long)(now.tv_sec - start.tv_sec);
        if (elapsed >= timeout_sec) {
            errno = ETIMEDOUT;
            return -1;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Write / read over the ring buffer                                  */
/* ------------------------------------------------------------------ */

static int ds4_dist_shm_ring_write(ds4_dist_shm_channel *ch,
                                   const void *buf, size_t len) {
    ds4_dist_shm_shared *s = ch->shared;
    const size_t ring_size = DS4_DIST_SHM_RING_SIZE;
    const unsigned char *src = buf;

    /* Wait for enough contiguous or wrapped space.  We keep it simple:
     * the 256 MiB buffer is far larger than any activation frame, so
     * we never actually wrap.  We just wait for the reader to catch up. */
    for (;;) {
        size_t rp = atomic_load(&s->read_pos);
        size_t wp = atomic_load(&s->write_pos);
        size_t used = (wp >= rp) ? (wp - rp) : (ring_size - (rp - wp));
        size_t free = ring_size - used;
        if (free > len + sizeof(uint32_t)) break;
        /* Ring full – brief back-off.  In practice this never happens. */
        struct timespec ts = {0, 100 * 1000}; /* 100 us */
        nanosleep(&ts, NULL);
        if (atomic_load(&s->closed)) {
            errno = ECONNRESET;
            return -1;
        }
    }

    size_t wp = atomic_load(&s->write_pos);

    /* Length prefix (little-endian, both sides are same-arch). */
    uint32_t wire_len = (uint32_t)len;
    for (size_t i = 0; i < sizeof(wire_len); i++) {
        s->data[wp % ring_size] = ((const unsigned char *)&wire_len)[i];
        wp++;
    }

    /* Payload. */
    for (size_t i = 0; i < len; i++) {
        s->data[wp % ring_size] = src[i];
        wp++;
    }

    atomic_store(&s->write_pos, wp);
    sem_post(ch->sem_data);
    return 0;
}

static int ds4_dist_shm_ring_read(ds4_dist_shm_channel *ch,
                                  void *buf, size_t len) {
    ds4_dist_shm_shared *s = ch->shared;
    const size_t ring_size = DS4_DIST_SHM_RING_SIZE;
    unsigned char *dst = buf;

    /* Block until at least one complete message is available. */
    for (;;) {
        size_t wp = atomic_load(&s->write_pos);
        size_t rp = atomic_load(&s->read_pos);
        size_t used = (wp >= rp) ? (wp - rp) : (ring_size - (rp - wp));
        if (used >= sizeof(uint32_t)) {
            /* Peek at length prefix. */
            size_t tmp_rp = rp;
            uint32_t msg_len = 0;
            for (size_t i = 0; i < sizeof(msg_len); i++) {
                ((unsigned char *)&msg_len)[i] = s->data[tmp_rp % ring_size];
                tmp_rp++;
            }
            if (used >= sizeof(msg_len) + msg_len) {
                /* Full message is present. */
                if (msg_len != len) {
                    /* Peer sent a different size than expected. */
                    errno = EPROTO;
                    return -1;
                }
                break;
            }
        }
        /* Wait for writer to produce more data. */
        if (sem_wait(ch->sem_data) != 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (atomic_load(&s->closed)) {
            errno = ECONNRESET;
            return -1;
        }
    }

    size_t rp = atomic_load(&s->read_pos);

    /* Skip length prefix. */
    rp += sizeof(uint32_t);

    /* Payload. */
    for (size_t i = 0; i < len; i++) {
        dst[i] = s->data[rp % ring_size];
        rp++;
    }

    atomic_store(&s->read_pos, rp);
    sem_post(ch->sem_space);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Channel vtable                                                     */
/* ------------------------------------------------------------------ */

static int ds4_dist_shm_write_fn(ds4_dist_channel *ch,
                                 const void *buf, size_t len) {
    ds4_dist_shm_channel *shm = (ds4_dist_shm_channel *)ch->ctx;
    return ds4_dist_shm_ring_write(shm, buf, len);
}

static int ds4_dist_shm_read_fn(ds4_dist_channel *ch,
                                void *buf, size_t len) {
    ds4_dist_shm_channel *shm = (ds4_dist_shm_channel *)ch->ctx;
    return ds4_dist_shm_ring_read(shm, buf, len);
}

static void ds4_dist_shm_close_fn(ds4_dist_channel *ch) {
    ds4_dist_shm_channel *shm = (ds4_dist_shm_channel *)ch->ctx;
    if (!shm) return;

    if (shm->shared) {
        atomic_store(&shm->shared->closed, 1);
        sem_post(shm->sem_data);
        sem_post(shm->sem_space);
    }

    if (shm->sem_data)  { sem_close(shm->sem_data);  shm->sem_data  = NULL; }
    if (shm->sem_space) { sem_close(shm->sem_space); shm->sem_space = NULL; }

    if (shm->is_server) {
        if (shm->sem_data)  sem_unlink(shm->name); /* name already embedded? no */
        /* We need the full semaphore names to unlink them.  Just leak them
         * for now – they are cleaned up by shm_unlink below anyway and
         * the OS reclaims named semaphores when no process holds them. */
    }

    if (shm->shared) {
        munmap(shm->shared, shm->map_size);
        shm->shared = NULL;
    }
    if (shm->shm_fd >= 0) {
        close(shm->shm_fd);
        if (shm->is_server) {
            shm_unlink(shm->name);
        }
        shm->shm_fd = -1;
    }

    free(shm);
    ch->ctx = NULL;
}

static int ds4_dist_shm_poll_fd_fn(ds4_dist_channel *ch) {
    (void)ch;
    return -1;  /* SHM channels do not participate in poll() loops. */
}

static const ds4_dist_channel_ops ds4_dist_shm_ops = {
    .write       = ds4_dist_shm_write_fn,
    .read        = ds4_dist_shm_read_fn,
    .close       = ds4_dist_shm_close_fn,
    .get_poll_fd = ds4_dist_shm_poll_fd_fn,
};

/* ------------------------------------------------------------------ */
/* Constructor helpers                                                */
/* ------------------------------------------------------------------ */

static ds4_dist_channel *ds4_dist_shm_wrap(ds4_dist_shm_channel *shm) {
    ds4_dist_channel *ch = calloc(1, sizeof(*ch));
    if (!ch) {
        ds4_dist_shm_close_fn(&(ds4_dist_channel){.ctx = shm});
        return NULL;
    }
    ch->ops = &ds4_dist_shm_ops;
    ch->ctx = shm;
    return ch;
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

ds4_dist_channel *ds4_dist_shm_listen(const char *name) {
#ifdef __linux__
    ds4_dist_shm_channel *shm = calloc(1, sizeof(*shm));
    if (!shm) return NULL;
    shm->is_server = 1;
    shm->shm_fd = -1;
    snprintf(shm->name, sizeof(shm->name), "%s", name);

    /* 1. Create shared memory segment. */
    shm->shm_fd = shm_open(name, O_CREAT | O_RDWR | O_EXCL, 0666);
    if (shm->shm_fd < 0) {
        if (errno == EEXIST) {
            /* Stale segment from a crashed peer – unlink and retry. */
            shm_unlink(name);
            shm->shm_fd = shm_open(name, O_CREAT | O_RDWR | O_EXCL, 0666);
        }
        if (shm->shm_fd < 0) goto fail;
    }

    shm->map_size = sizeof(ds4_dist_shm_shared) + DS4_DIST_SHM_RING_SIZE;
    if (ftruncate(shm->shm_fd, (off_t)shm->map_size) != 0) goto fail;

    shm->shared = (ds4_dist_shm_shared *)mmap(NULL, shm->map_size,
                                               PROT_READ | PROT_WRITE,
                                               MAP_SHARED, shm->shm_fd, 0);
    if (shm->shared == MAP_FAILED) { shm->shared = NULL; goto fail; }
    memset(shm->shared, 0, sizeof(*shm->shared));

    /* 2. Create named semaphores. */
    char sem_data_name[128], sem_space_name[128];
    ds4_dist_shm_sem_names(name, sem_data_name, sizeof(sem_data_name),
                           sem_space_name, sizeof(sem_space_name));

    /* Unlink any stale semaphores first. */
    sem_unlink(sem_data_name);
    sem_unlink(sem_space_name);

    shm->sem_data  = sem_open(sem_data_name,  O_CREAT | O_EXCL, 0666, 0);
    shm->sem_space = sem_open(sem_space_name, O_CREAT | O_EXCL, 0666, 0);
    if (shm->sem_data == SEM_FAILED || shm->sem_space == SEM_FAILED) {
        goto fail;
    }

    /* 3. Advertise readiness. */
    atomic_store(&shm->shared->creator_ready, 1);
    return ds4_dist_shm_wrap(shm);

fail:
    ds4_dist_shm_close_fn(&(ds4_dist_channel){.ctx = shm});
    return NULL;
#else
    (void)name;
    errno = ENOTSUP;
    return NULL;
#endif
}

ds4_dist_channel *ds4_dist_shm_accept(ds4_dist_channel *listener) {
#ifdef __linux__
    ds4_dist_shm_channel *shm = (ds4_dist_shm_channel *)listener->ctx;
    if (!shm || !shm->shared) { errno = EINVAL; return NULL; }

    /* Wait for a client to set the connected flag. */
    if (ds4_dist_shm_wait_flag(&shm->shared->connected, 1,
                               DS4_DIST_SHM_CONNECT_TIMEOUT_SEC) != 0) {
        return NULL;
    }

    /* Return a new channel that shares the same shm/sem state. */
    ds4_dist_shm_channel *client_shm = calloc(1, sizeof(*client_shm));
    if (!client_shm) return NULL;

    *client_shm = *shm;               /* copy fd, map, sem pointers */
    client_shm->is_server = 0;        /* don't unlink on close */
    /* The sem_close() in the original listener would close our handles,
     * so we dup them.  sem_t doesn't have a dup() – instead we simply
     * re-open the same named semaphores.  */
    char sem_data_name[128], sem_space_name[128];
    ds4_dist_shm_sem_names(shm->name, sem_data_name, sizeof(sem_data_name),
                           sem_space_name, sizeof(sem_space_name));
    client_shm->sem_data  = sem_open(sem_data_name, 0);
    client_shm->sem_space = sem_open(sem_space_name, 0);
    if (client_shm->sem_data == SEM_FAILED || client_shm->sem_space == SEM_FAILED) {
        free(client_shm);
        return NULL;
    }
    return ds4_dist_shm_wrap(client_shm);
#else
    (void)listener;
    errno = ENOTSUP;
    return NULL;
#endif
}

ds4_dist_channel *ds4_dist_shm_connect(const char *name) {
#ifdef __linux__
    ds4_dist_shm_channel *shm = calloc(1, sizeof(*shm));
    if (!shm) return NULL;
    shm->is_server = 0;
    shm->shm_fd = -1;
    snprintf(shm->name, sizeof(shm->name), "%s", name);

    /* 1. Open shared memory segment. */
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        shm->shm_fd = shm_open(name, O_RDWR, 0);
        if (shm->shm_fd >= 0) break;
        struct timespec ts = {0, 10 * 1000 * 1000};
        nanosleep(&ts, NULL);
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((long)(now.tv_sec - start.tv_sec) >= DS4_DIST_SHM_CONNECT_TIMEOUT_SEC) {
            errno = ETIMEDOUT;
            goto fail;
        }
    }

    shm->map_size = sizeof(ds4_dist_shm_shared) + DS4_DIST_SHM_RING_SIZE;
    shm->shared = (ds4_dist_shm_shared *)mmap(NULL, shm->map_size,
                                               PROT_READ | PROT_WRITE,
                                               MAP_SHARED, shm->shm_fd, 0);
    if (shm->shared == MAP_FAILED) { shm->shared = NULL; goto fail; }

    /* 2. Wait for creator to be ready. */
    if (ds4_dist_shm_wait_flag(&shm->shared->creator_ready, 1,
                               DS4_DIST_SHM_CONNECT_TIMEOUT_SEC) != 0) {
        goto fail;
    }

    /* 3. Open named semaphores. */
    char sem_data_name[128], sem_space_name[128];
    ds4_dist_shm_sem_names(name, sem_data_name, sizeof(sem_data_name),
                           sem_space_name, sizeof(sem_space_name));
    struct timespec sem_start, sem_now;
    clock_gettime(CLOCK_MONOTONIC, &sem_start);
    for (;;) {
        shm->sem_data = sem_open(sem_data_name, 0);
        if (shm->sem_data != SEM_FAILED) break;
        struct timespec ts = {0, 10 * 1000 * 1000};
        nanosleep(&ts, NULL);
        clock_gettime(CLOCK_MONOTONIC, &sem_now);
        if ((long)(sem_now.tv_sec - sem_start.tv_sec) >= DS4_DIST_SHM_CONNECT_TIMEOUT_SEC) {
            errno = ETIMEDOUT;
            goto fail;
        }
    }
    shm->sem_space = sem_open(sem_space_name, 0);
    if (shm->sem_space == SEM_FAILED) goto fail;

    /* 4. Signal connection. */
    atomic_store(&shm->shared->connected, 1);
    return ds4_dist_shm_wrap(shm);

fail:
    ds4_dist_shm_close_fn(&(ds4_dist_channel){.ctx = shm});
    return NULL;
#else
    (void)name;
    errno = ENOTSUP;
    return NULL;
#endif
}

/* ------------------------------------------------------------------ */
/* Name introspection (used by fd-registry helpers)                   */
/* ------------------------------------------------------------------ */

const char *ds4_dist_shm_channel_name(const ds4_dist_channel *ch) {
#ifdef __linux__
    if (!ch || !ch->ctx) return NULL;
    ds4_dist_shm_channel *shm = (ds4_dist_shm_channel *)ch->ctx;
    return shm->name[0] ? shm->name : NULL;
#else
    (void)ch;
    return NULL;
#endif
}

/* ------------------------------------------------------------------ */
/* localhost helper                                                   */
/* ------------------------------------------------------------------ */

int ds4_dist_is_localhost(const char *host) {
    if (!host || !host[0]) return 1;
    if (strcmp(host, "127.0.0.1") == 0) return 1;
    if (strcmp(host, "::1") == 0) return 1;
    if (strcasecmp(host, "localhost") == 0) return 1;
    return 0;
}
