#include "ChecklistFileAccess.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int64_t milliseconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

// All entry points run on Core's single folder-access queue. Idle helpers have
// no store descriptors: only their anonymous channel and two lifetime pipes.
static struct { pid_t pid; int socket, death, lifetime; } helper = {0, -1, -1, -1};
static void forget_helper(void) {
    if (helper.socket >= 0) close(helper.socket);
    if (helper.death >= 0) close(helper.death);
    if (helper.lifetime >= 0) close(helper.lifetime);
    helper.pid = 0; helper.socket = helper.death = helper.lifetime = -1;
}
void checklist_reap_idle_folder_helper(void) {
    if (!helper.pid) return;
    pid_t result = waitpid(helper.pid, NULL, WNOHANG);
    if (result == helper.pid || (result < 0 && errno == ECHILD)) forget_helper();
}
static pid_t retire_helper(void) {
    pid_t child = helper.pid;
    if (child) kill(child, SIGKILL);
    forget_helper();
    pid_t result = child ? waitpid(child, NULL, WNOHANG) : 0;
    return child && (result == 0 || (result < 0 && errno != ECHILD)) ? child : 0;
}

static int walk(char *path) {
    int current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (current < 0) return -1;
    char *part = path;
    while (*part == '/') ++part;
    while (*part) {
        char *end = part;
        while (*end && *end != '/') ++end;
        int last = *end == '\0'; *end = '\0';
        int next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (next < 0) { int saved = errno; close(current); errno = saved; return -1; }
        close(current); current = next;
        if (last) break;
        part = end + 1;
    }
    return current;
}

// Datagram framing is atomic. Ancillary descriptors are accepted only in the
// exact expected count; close even malformed/truncated messages' delivered FDs.
static int received_descriptor(struct msghdr *message, int expected, int *result) {
    int count = 0, invalid = message->msg_flags & (MSG_TRUNC | MSG_CTRUNC);
    *result = -1;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(message); header; header = CMSG_NXTHDR(message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len < CMSG_LEN(0)) { invalid = 1; continue; }
        size_t bytes = header->cmsg_len - CMSG_LEN(0);
        if (bytes % sizeof(int)) invalid = 1;
        for (size_t i = 0; i < bytes / sizeof(int); ++i) {
            int fd; memcpy(&fd, (char *)CMSG_DATA(header) + i * sizeof(int), sizeof(fd));
            if (count++ == 0) *result = fd; else close(fd);
        }
    }
    if (invalid || count != expected) { if (*result >= 0) close(*result); *result = -1; return -1; }
    return 0;
}
static ssize_t send_descriptor(int socket, void *bytes, size_t length, int fd) {
    struct iovec io = {bytes, length};
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } control;
    struct msghdr message = {0}; message.msg_iov = &io; message.msg_iovlen = 1;
    if (fd >= 0) {
        message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS; header->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(header), &fd, sizeof(fd));
    }
    return sendmsg(socket, &message, 0);
}
struct request { int64_t deadline; int barrier; char path[PATH_MAX]; };
static void serve(int socket, int lifetime, int death, int maximum_fd, int64_t initial_deadline,
                  const struct sigaction *expiry, const sigset_t *expiry_signal) {
    if (sigaction(SIGALRM, expiry, NULL) || sigprocmask(SIG_UNBLOCK, expiry_signal, NULL)) _exit(1);
    const int64_t generation_deadline = milliseconds() + 60 * 1000;
    int64_t remaining = initial_deadline - milliseconds();
    if (remaining <= 0) _exit(1);
    alarm((unsigned)((remaining + 999) / 1000));
    // Do not keep the parent's SQLite, object-gate, service or retention leases
    // alive. The maximum descriptor range was obtained before fork.
    for (int fd = 0; fd < maximum_fd; ++fd) if (fd != socket && fd != lifetime && fd != death) close(fd);
    for (;;) {
        struct pollfd ready[2] = {{socket, POLLIN, 0}, {lifetime, POLLIN, 0}};
        int status = poll(ready, 2, -1);
        if (status < 0 && errno == EINTR) continue;
        if (status <= 0 || ready[1].revents || !(ready[0].revents & POLLIN)) _exit(0);
        struct request request;
        struct iovec io = {&request, sizeof(request)};
        union { struct cmsghdr alignment; char bytes[CMSG_SPACE(4 * sizeof(int))]; } control;
        struct msghdr message = {0}; message.msg_iov = &io; message.msg_iovlen = 1;
        message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
        ssize_t received = recvmsg(socket, &message, 0);
        if (received < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        int barrier = -1;
        if (received != sizeof(request) || (request.barrier != 0 && request.barrier != 1)) _exit(1);
        if (received_descriptor(&message, request.barrier, &barrier) || !memchr(request.path, 0, sizeof(request.path)) || request.path[0] != '/') _exit(1);
        remaining = (request.deadline < generation_deadline ? request.deadline : generation_deadline) - milliseconds();
        if (remaining <= 0) _exit(1);
        alarm((unsigned)((remaining + 999) / 1000));
        if (barrier >= 0) { char byte; while (read(barrier, &byte, 1) < 0 && errno == EINTR) {} close(barrier); }
        int fd = walk(request.path), failure = fd < 0 ? errno : 0;
        ssize_t sent;
        do { sent = send_descriptor(socket, &failure, sizeof(failure), fd); } while (sent < 0 && errno == EINTR);
        if (fd >= 0) close(fd);
        if (sent != sizeof(failure)) _exit(1);
        // Bound both idle orphans and retention of the parent's forked heap
        // snapshot under sustained traffic, rather than extending life per call.
        remaining = generation_deadline - milliseconds();
        if (remaining <= 0) _exit(0);
        alarm((unsigned)((remaining + 999) / 1000));
    }
}
static int start_helper(int64_t deadline) {
    int maximum_fd = 0; size_t size = sizeof(maximum_fd);
    struct rlimit limit;
    if (sysctlbyname("kern.maxfilesperproc", &maximum_fd, &size, NULL, 0) || getrlimit(RLIMIT_NOFILE, &limit)) return -1;
    if (limit.rlim_cur > (rlim_t)maximum_fd && limit.rlim_cur <= INT_MAX) maximum_fd = (int)limit.rlim_cur;
    if (maximum_fd <= 0) { errno = EIO; return -1; }
    int pair[2] = {-1,-1}, lifetime[2] = {-1,-1}, death[2] = {-1,-1}, saved;
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) || pipe(lifetime) || pipe(death)) goto fail;
    int descriptors[] = {pair[0],pair[1],lifetime[0],lifetime[1],death[0],death[1]};
    for (int i = 0; i < 6; ++i) if (fcntl(descriptors[i], F_SETFD, FD_CLOEXEC) || fcntl(descriptors[i], F_SETFL, O_NONBLOCK)) goto fail;
    int yes = 1;
    if (setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) || setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes))) goto fail;
    struct sigaction expiry = {0}; expiry.sa_handler = SIG_DFL; sigemptyset(&expiry.sa_mask);
    sigset_t expiry_signal; sigemptyset(&expiry_signal); sigaddset(&expiry_signal, SIGALRM);
    pid_t child = fork();
    if (child < 0) goto fail;
    if (!child) { serve(pair[1], lifetime[0], death[1], maximum_fd, deadline, &expiry, &expiry_signal); _exit(1); }
    close(pair[1]); close(lifetime[0]); close(death[1]);
    helper.pid = child; helper.socket = pair[0]; helper.lifetime = lifetime[1]; helper.death = death[0];
    return 0;
fail:
    saved = errno;
    for (int i = 0; i < 2; ++i) { if (pair[i] >= 0) close(pair[i]); if (lifetime[i] >= 0) close(lifetime[i]); if (death[i] >= 0) close(death[i]); }
    errno = saved; return -1;
}
static int await_helper(short events, int64_t deadline) {
    for (;;) {
        int64_t remaining = deadline - milliseconds();
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd ready[2] = {{helper.socket, events, 0}, {helper.death, POLLIN, 0}};
        int status = poll(ready, 2, (int)remaining);
        if (status < 0 && errno == EINTR) continue;
        if (status == 0) { errno = ETIMEDOUT; return -1; }
        if (status < 0) return -1;
        if (ready[1].revents) { errno = EPIPE; return -1; }
        if (ready[0].revents & events) return 0;
        errno = EPIPE; return -1;
    }
}
int checklist_open_bounded(const char *path, int timeout_ms, int barrier_fd, pid_t retired[2], pid_t *worker) {
    retired[0] = retired[1] = *worker = 0;
    size_t length = strlen(path);
    if (length >= PATH_MAX || timeout_ms <= 0) { errno = EINVAL; return -1; }
    int64_t deadline = milliseconds() + timeout_ms;
    struct request request = {0}; request.deadline = deadline; request.barrier = barrier_fd >= 0;
    memcpy(request.path, path, length + 1);
    for (int attempt = 0; attempt < 2; ++attempt) {
        checklist_reap_idle_folder_helper();
        if (!helper.pid && start_helper(deadline)) return -1;
        *worker = helper.pid;
        int fd = -1, failure = 0;
        for (;;) {
            if (await_helper(POLLOUT, deadline)) { failure = errno; break; }
            ssize_t sent = send_descriptor(helper.socket, &request, sizeof(request), barrier_fd);
            if (sent == sizeof(request)) break;
            if (sent < 0 && (errno == EAGAIN || errno == EINTR)) continue;
            failure = sent < 0 ? errno : EIO; break;
        }
        while (!failure) {
            if (await_helper(POLLIN, deadline)) { failure = errno; break; }
            struct iovec io = {&failure, sizeof(failure)};
            union { struct cmsghdr alignment; char bytes[CMSG_SPACE(4 * sizeof(int))]; } control;
            struct msghdr message = {0}; message.msg_iov = &io; message.msg_iovlen = 1;
            message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
            ssize_t received = recvmsg(helper.socket, &message, 0);
            if (received < 0 && (errno == EAGAIN || errno == EINTR)) continue;
            if (received != sizeof(failure)) { if (received >= 0) received_descriptor(&message, 0, &fd); failure = EIO; break; }
            if (received_descriptor(&message, failure ? 0 : 1, &fd)) { failure = EIO; break; }
            if (fd >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC)) { failure = errno; close(fd); fd = -1; }
            break;
        }
        if (fd >= 0) return fd;
        if (!failure) failure = EIO;
        // Error replies have no outstanding operation; only broken generations
        // need retirement. Reconnect once on idle expiry, within the SAME deadline.
        if (failure != EPIPE && failure != EIO && failure != ETIMEDOUT) { errno = failure; return -1; }
        retired[attempt] = retire_helper();
        if (failure != EPIPE || attempt || milliseconds() >= deadline) { errno = failure; return -1; }
    }
    errno = EIO; return -1;
}
