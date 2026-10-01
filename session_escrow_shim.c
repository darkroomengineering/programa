#include "session_escrow_shim.h"

#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

ssize_t session_escrow_send(int socket_fd, int fd, const void *payload, size_t payload_len) {
    struct iovec iov;
    iov.iov_base = (void *)payload;
    iov.iov_len = payload_len;

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    /* Only touched when fd >= 0; must outlive the sendmsg call below, so
     * it lives in this function's stack frame, not a nested scope. */
    char control[CMSG_SPACE(sizeof(int))];

    if (fd >= 0) {
        memset(control, 0, sizeof(control));
        msg.msg_control = control;
        msg.msg_controllen = sizeof(control);

        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
        cmsg->cmsg_len = CMSG_LEN(sizeof(int));
        cmsg->cmsg_level = SOL_SOCKET;
        cmsg->cmsg_type = SCM_RIGHTS;
        memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));
    }

    return sendmsg(socket_fd, &msg, 0);
}

/* The protocol carries at most one fd, but the buffer has room for many: on
 * Darwin a truncated SCM_RIGHTS message still installs every right in this
 * process, and the ones that did not fit in the buffer cannot be found to
 * close. A generous buffer keeps that out of reach of a misbehaving peer
 * (which must already be the same uid); every fd beyond the first is closed
 * below. */
#define SESSION_ESCROW_MAX_RECV_FDS 16

static void session_escrow_close_received(struct msghdr *msg, int keep_first, int *out_fd) {
    int kept = 0;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(msg); cmsg != NULL; cmsg = CMSG_NXTHDR(msg, cmsg)) {
        if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS
            || cmsg->cmsg_len < CMSG_LEN(sizeof(int))) {
            continue;
        }
        unsigned char *data = CMSG_DATA(cmsg);
        /* After MSG_CTRUNC, cmsg_len still reports every right sent; only
         * read the ints that actually landed inside the control buffer. */
        unsigned char *control_end = (unsigned char *)msg->msg_control + msg->msg_controllen;
        if (data >= control_end) {
            continue;
        }
        size_t reported = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        size_t available = (size_t)(control_end - data) / sizeof(int);
        size_t count = reported < available ? reported : available;
        for (size_t i = 0; i < count; i++) {
            int fd;
            memcpy(&fd, data + i * sizeof(int), sizeof(int));
            if (fd < 0) {
                continue;
            }
            /* macOS has no MSG_CMSG_CLOEXEC: mark close-on-exec right away so
             * a concurrent fork/exec (shell spawn, git probe) cannot inherit
             * the PTY master. */
            (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
            if (keep_first && !kept) {
                kept = 1;
                *out_fd = fd;
            } else {
                close(fd);
            }
        }
    }
}

ssize_t session_escrow_recv(int socket_fd, void *payload, size_t payload_len, int *out_fd) {
    struct iovec iov;
    iov.iov_base = payload;
    iov.iov_len = payload_len;

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    char control[CMSG_SPACE(sizeof(int) * SESSION_ESCROW_MAX_RECV_FDS)];
    memset(control, 0, sizeof(control));
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);

    if (out_fd != NULL) {
        *out_fd = -1;
    }

    ssize_t n = recvmsg(socket_fd, &msg, 0);
    if (n <= 0) {
        return n;
    }

    if (msg.msg_controllen < sizeof(struct cmsghdr)) {
        return n;
    }

    if (msg.msg_flags & MSG_CTRUNC) {
        /* Close whatever rights did fit and fail the read: a truncated
         * control message means the frame cannot be trusted. */
        int ignored = -1;
        session_escrow_close_received(&msg, 0, &ignored);
        errno = EMSGSIZE;
        return -1;
    }

    int received = -1;
    session_escrow_close_received(&msg, out_fd != NULL, &received);
    if (out_fd != NULL) {
        *out_fd = received;
    }

    return n;
}
