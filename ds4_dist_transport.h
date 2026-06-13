#ifndef DS4_DIST_TRANSPORT_H
#define DS4_DIST_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

/* =========================================================================
 * Pluggable distributed transport channel
 * =========================================================================
 *
 * DS4 distributed inference communicates between coordinator and workers
 * over TCP by default.  When all processes run on the same physical host
 * the --use-shm-transport switch replaces the data path with POSIX shared
 * memory + named semaphores, eliminating TCP stack overhead and the
 * activation quantise/de-quantise round-trip for local peers.
 *
 * The abstraction is intentionally thin: every place that previously held
 * an "int fd" now holds a ds4_dist_channel pointer.  Send/recv/close go
 * through the vtable.  A real poll-compatible fd is exposed so that the
 * small number of poll() call-sites in the control path do not need to
 * change.
 */

typedef struct ds4_dist_channel ds4_dist_channel;

typedef struct {
    /* Blocking write of exactly len bytes.  Returns 0 on success, -1 on
     * error (errno is left valid).  */
    int (*write)(ds4_dist_channel *ch, const void *buf, size_t len);

    /* Blocking read of exactly len bytes.  Returns 1 on success,
     * 0 on orderly EOF, -1 on error (errno is left valid).  */
    int (*read)(ds4_dist_channel *ch, void *buf, size_t len);

    /* Tear-down.  NULL ch is a no-op.  */
    void (*close)(ds4_dist_channel *ch);

    /* Return a real file-descriptor suitable for poll()/select().
     * For TCP this is the socket.  For SHM this is a pipe end that
     * is signalled when the channel becomes readable or hits an error,
     * so the control-path poll() loops work unchanged.  Returns -1 if
     * no fd is available.  */
    int (*get_poll_fd)(ds4_dist_channel *ch);
} ds4_dist_channel_ops;

struct ds4_dist_channel {
    const ds4_dist_channel_ops *ops;
    void *ctx;
};

/* --------------------------------------------------------------------- */
/* Inline convenience wrappers                                           */
/* --------------------------------------------------------------------- */

static inline int ds4_dist_ch_write(ds4_dist_channel *ch,
                                    const void *buf, size_t len) {
    if (!ch || !ch->ops || !ch->ops->write) return -1;
    return ch->ops->write(ch, buf, len);
}

static inline int ds4_dist_ch_read(ds4_dist_channel *ch,
                                   void *buf, size_t len) {
    if (!ch || !ch->ops || !ch->ops->read) return -1;
    return ch->ops->read(ch, buf, len);
}

static inline void ds4_dist_ch_close(ds4_dist_channel *ch) {
    if (ch && ch->ops && ch->ops->close) ch->ops->close(ch);
}

static inline int ds4_dist_ch_poll_fd(ds4_dist_channel *ch) {
    if (!ch || !ch->ops || !ch->ops->get_poll_fd) return -1;
    return ch->ops->get_poll_fd(ch);
}

/* --------------------------------------------------------------------- */
/* TCP transport                                                         */
/* --------------------------------------------------------------------- */

/* Wrap an existing socket fd in a channel.  The channel takes ownership
 * of the fd and will close() it when destroyed.  */
ds4_dist_channel *ds4_dist_tcp_channel_from_fd(int fd);

/* --------------------------------------------------------------------- */
/* SHM transport                                                         */
/* --------------------------------------------------------------------- */

/* Open a listening SHM endpoint.  The returned channel is the server
 * side; it blocks in accept() until a client connects.  */
ds4_dist_channel *ds4_dist_shm_listen(const char *name);

/* Accept a connection on an SHM listener.  Blocks until a client connects.  */
ds4_dist_channel *ds4_dist_shm_accept(ds4_dist_channel *listener);

/* Connect to an SHM endpoint created by shm_listen().  */
ds4_dist_channel *ds4_dist_shm_connect(const char *name);

/* Return the underlying SHM segment name for a channel (or NULL).  */
const char *ds4_dist_shm_channel_name(const ds4_dist_channel *ch);

/* --------------------------------------------------------------------- */
/* Helpers                                                               */
/* --------------------------------------------------------------------- */

/* Returns true if host looks like a local address (127.0.0.1, ::1,
 * localhost, or NULL/empty).  */
int ds4_dist_is_localhost(const char *host);

#endif
