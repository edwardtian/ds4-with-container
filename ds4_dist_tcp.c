/* DS4 Distributed TCP Transport
 *
 * Thin wrapper around existing POSIX socket code so that TCP connections
 * can be treated as ds4_dist_channel instances alongside the SHM transport.
 */

#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include "ds4_dist_transport.h"

typedef struct {
    int fd;
} ds4_dist_tcp_channel;

static int ds4_dist_tcp_write_fn(ds4_dist_channel *ch,
                                 const void *buf, size_t len) {
    ds4_dist_tcp_channel *tcp = (ds4_dist_tcp_channel *)ch->ctx;
    const unsigned char *p = (const unsigned char *)buf;
    while (len > 0) {
        ssize_t n = send(tcp->fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        p += (size_t)n;
        len -= (size_t)n;
    }
    return 0;
}

static int ds4_dist_tcp_read_fn(ds4_dist_channel *ch,
                                void *buf, size_t len) {
    ds4_dist_tcp_channel *tcp = (ds4_dist_tcp_channel *)ch->ctx;
    unsigned char *p = (unsigned char *)buf;
    while (len > 0) {
        ssize_t n = recv(tcp->fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return 0;
        p += (size_t)n;
        len -= (size_t)n;
    }
    return 1;
}

static void ds4_dist_tcp_close_fn(ds4_dist_channel *ch) {
    ds4_dist_tcp_channel *tcp = (ds4_dist_tcp_channel *)ch->ctx;
    if (tcp) {
        if (tcp->fd >= 0) close(tcp->fd);
        free(tcp);
    }
    ch->ctx = NULL;
}

static int ds4_dist_tcp_poll_fd_fn(ds4_dist_channel *ch) {
    ds4_dist_tcp_channel *tcp = (ds4_dist_tcp_channel *)ch->ctx;
    return tcp ? tcp->fd : -1;
}

static const ds4_dist_channel_ops ds4_dist_tcp_ops = {
    .write       = ds4_dist_tcp_write_fn,
    .read        = ds4_dist_tcp_read_fn,
    .close       = ds4_dist_tcp_close_fn,
    .get_poll_fd = ds4_dist_tcp_poll_fd_fn,
};

ds4_dist_channel *ds4_dist_tcp_channel_from_fd(int fd) {
    ds4_dist_tcp_channel *tcp = calloc(1, sizeof(*tcp));
    if (!tcp) {
        close(fd);
        return NULL;
    }
    tcp->fd = fd;
    ds4_dist_channel *ch = calloc(1, sizeof(*ch));
    if (!ch) {
        close(fd);
        free(tcp);
        return NULL;
    }
    ch->ops = &ds4_dist_tcp_ops;
    ch->ctx = tcp;
    return ch;
}
