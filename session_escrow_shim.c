#include "session_escrow_shim.h"

#include <string.h>
#include <errno.h>

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

ssize_t session_escrow_recv(int socket_fd, void *payload, size_t payload_len, int *out_fd) {
    struct iovec iov;
    iov.iov_base = payload;
    iov.iov_len = payload_len;

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    char control[CMSG_SPACE(sizeof(int))];
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

    if (out_fd != NULL
        && msg.msg_controllen >= sizeof(struct cmsghdr)
        && !(msg.msg_flags & MSG_CTRUNC)) {
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
        if (cmsg != NULL
            && cmsg->cmsg_len >= CMSG_LEN(sizeof(int))
            && cmsg->cmsg_level == SOL_SOCKET
            && cmsg->cmsg_type == SCM_RIGHTS) {
            int fd;
            memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
            *out_fd = fd;
        }
    }

    return n;
}
