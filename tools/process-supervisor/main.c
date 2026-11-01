/* Noninteractive capture supervisor. No shells or privileged work.
 * stdin: private cancellation/lifetime pipe (EOF cancels).
 * stdout: NXSP1\n, then tag + big-endian u32 length + payload frames.
 * O/E carry command output; R carries "status reason errno" (see README).
 */
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#include <sys/sysctl.h>
#include <sys/proc.h>
#endif
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { EXITED, TIMED_OUT, OUTPUT_LIMIT, CANCELLED, EXEC_FAILED, INTERNAL_ERROR };
enum { CHUNK = 65536 };
static volatile sig_atomic_t interrupted;

static void on_signal(int signal_number) { interrupted = signal_number; }
static double now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) < 0) _exit(125);
    return value.tv_sec + value.tv_nsec / 1e9;
}
static void close_fd(int *fd) {
    if (*fd >= 0) { close(*fd); *fd = -1; }
}
static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
static int make_pipe(int fds[2]) {
    if (pipe(fds) < 0) return -1;
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) return -1;
    return 0;
}

static int signal_group(pid_t group, int signal_number) {
    if (kill(-group, signal_number) == 0 || errno == ESRCH) return 0;
    int signal_errno = errno;
#ifdef __APPLE__
    if (errno == EPERM) {
        /* Darwin returns EPERM for zombie-only groups too. Disambiguate with
         * one bounded, kernel-filtered group snapshot; never derive signal
         * targets from a process-table scan. The leader is still unreaped.
         * Permission failures, truncated snapshots and live members fail shut. */
        size_t size = 1024 * sizeof(struct kinfo_proc);
        struct kinfo_proc *members = malloc(size);
        if (!members) return -1;
        int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group};
        bool empty = sysctl(query, 4, members, &size, NULL, 0) == 0 &&
                     size % sizeof(*members) == 0;
        if (empty) {
            for (size_t i = 0; i < size / sizeof(*members); ++i)
                if (members[i].kp_proc.p_stat != SZOMB) { empty = false; break; }
        }
        free(members);
        if (empty) return 0;
    }
#endif
    errno = signal_errno;
    return -1;
}

struct capture {
    pid_t child;
    int output[2], exec_error, reason, status, exec_errno;
    bool stopping, killed, reaped, abandoned, final_frame;
    double stop_at, finished_at;
    size_t limit, total[2], pending_size, pending_sent;
    unsigned char pending[CHUNK + 5];
    unsigned next_stream;
};

static void queue_frame(struct capture *job, char tag, const void *data, size_t size) {
    job->pending[0] = (unsigned char)tag;
    for (unsigned i = 0; i < 4; ++i)
        job->pending[i + 1] = (unsigned char)(size >> (24 - 8 * i));
    memcpy(job->pending + 5, data, size);
    job->pending_size = size + 5;
    job->pending_sent = 0;
}

static void stop_job(struct capture *job, int reason) {
    if (reason == CANCELLED) job->abandoned = true;
    if (!job->stopping) {
        job->stopping = true;
        job->stop_at = now();
        job->reason = reason;
        /* child is deliberately not reaped until the FINAL group signal.
         * Its reserved PID prevents signalling a recycled process-group ID. */
        if (signal_group(job->child, SIGTERM) < 0) {
            job->exec_errno = errno;
            job->reason = INTERNAL_ERROR;
        }
        (void)signal_group(job->child, SIGCONT);
    } else if (job->reason == EXITED && reason != EXITED) {
        job->reason = reason;
    }
    if (job->reason != EXITED || job->abandoned) {
        close_fd(&job->output[0]);
        close_fd(&job->output[1]);
    }
    if (job->abandoned) {
        /* The receiver has gone away. Never block cleanup on protocol output. */
        job->pending_size = job->pending_sent = 0;
    }
}

static void child_error(int fd, int error_number) {
    ssize_t result;
    do { result = write(fd, &error_number, sizeof(error_number)); }
    while (result < 0 && errno == EINTR);
    _exit(127);
}

static void exec_child(char **command, int out[2], int err[2], int failure[2], bool stream_err) {
    close(out[0]);
    close(failure[0]);
    if (!stream_err) close(err[0]);
    /* No command instructions execute before joining the owned group. */
    if (setpgid(0, 0) < 0) child_error(failure[1], errno);
    sigset_t empty;
    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) < 0) child_error(failure[1], errno);
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGCHLD};
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i)
        if (sigaction(signals[i], &action, NULL) < 0) child_error(failure[1], errno);
    int input = open("/dev/null", O_RDONLY);
    if (input < 0 || dup2(input, STDIN_FILENO) < 0 || dup2(out[1], STDOUT_FILENO) < 0 ||
        (!stream_err && dup2(err[1], STDERR_FILENO) < 0)) child_error(failure[1], errno);
    close(input);
    close(out[1]);
    if (!stream_err) close(err[1]);
    /* failure[1] closes atomically on successful exec. The lifetime pipe was
     * replaced at fd 0: neither the job nor its descendants can keep it alive. */
    execvp(command[0], command);
    child_error(failure[1], errno);
}

static int supervise(struct capture *job, double timeout) {
    double started = now();
    memcpy(job->pending, "NXSP1\n", 6);
    job->pending_size = 6;
    while (true) {
        double instant = now();
        if (interrupted) stop_job(job, CANCELLED);
        if (!job->stopping) {
            siginfo_t info = {0};
            if (waitid(P_PID, job->child, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
                if (errno != EINTR) { job->exec_errno = errno; stop_job(job, INTERNAL_ERROR); }
            } else if (info.si_pid) {
                job->status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
                stop_job(job, EXITED);
            } else if (timeout > 0 && instant - started >= timeout) {
                stop_job(job, TIMED_OUT);
            }
        }
        if (job->stopping && !job->killed && instant - job->stop_at >= 0.1) {
            if (signal_group(job->child, SIGKILL) < 0) {
                job->exec_errno = errno; job->reason = INTERNAL_ERROR;
            }
            /* Also terminate the direct child if it changed its own group. */
            if (kill(job->child, SIGKILL) < 0 && errno != ESRCH) {
                job->exec_errno = errno; job->reason = INTERNAL_ERROR;
            }
            job->killed = true;
        }
        if (job->killed && !job->reaped) {
            int status;
            pid_t result = waitpid(job->child, &status, WNOHANG);
            if (result == job->child) {
                job->reaped = true;
                job->status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
                job->finished_at = instant;
            } else if (result < 0 && errno != EINTR) {
                /* Never signal this numeric PID/group again after reaping. */
                job->reaped = true;
                job->reason = INTERNAL_ERROR;
                job->exec_errno = errno;
                job->finished_at = instant;
            }
        }
        if (job->stopping && !job->reaped && instant - job->stop_at > 2.0) {
            /* An uninterruptible kernel task can outlast SIGKILL. Do not hang
             * Hey forever or pretend that userspace can guarantee its exit. */
            return 125;
        }
        if (job->reaped && job->abandoned) return 0;
        if (job->reaped && instant - job->finished_at > 1.0) {
            /* Bounded delivery also covers a live parent that stops reading. */
            return 125;
        }
        if (job->reaped && instant - job->finished_at > 0.25 &&
            (job->output[0] >= 0 || job->output[1] >= 0)) {
            /* An escaped daemon holding the pipe is not silently truncated. */
            stop_job(job, INTERNAL_ERROR);
        }
        if (job->reaped && job->output[0] < 0 && job->output[1] < 0 &&
            job->exec_error < 0 && job->pending_size == 0) {
            if (job->final_frame) return 0;
            char result[80];
            if (job->reason == EXITED && job->exec_errno) job->reason = EXEC_FAILED;
            int status = job->reason == TIMED_OUT ? 124 :
                         job->reason == OUTPUT_LIMIT || job->reason == INTERNAL_ERROR ? 125 :
                         job->reason == EXEC_FAILED ? 127 : job->status;
            int length = snprintf(result, sizeof(result), "%d %d %d", status, job->reason, job->exec_errno);
            queue_frame(job, 'R', result, (size_t)length);
            job->final_frame = true;
        }
        struct pollfd events[5] = {
            {.fd = job->abandoned ? -1 : STDIN_FILENO, .events = POLLIN},
            {.fd = job->pending_size ? -1 : job->output[0], .events = POLLIN},
            {.fd = job->pending_size ? -1 : job->output[1], .events = POLLIN},
            {.fd = job->exec_error, .events = POLLIN},
            {.fd = job->pending_size ? STDOUT_FILENO : -1, .events = POLLOUT}
        };
        if (poll(events, 5, 10) < 0) {
            if (errno != EINTR) stop_job(job, INTERNAL_ERROR);
            continue;
        }
        if (events[0].revents) {
            unsigned char value;
            ssize_t size = read(STDIN_FILENO, &value, 1);
            /* EOF or any byte is a cancellation request; no command data. */
            if (size >= 0 || (errno != EAGAIN && errno != EINTR)) stop_job(job, CANCELLED);
        }
        if (job->abandoned) continue;
        if (events[3].revents) {
            int error_number = 0;
            ssize_t size = read(job->exec_error, &error_number, sizeof(error_number));
            if (size == (ssize_t)sizeof(error_number)) job->exec_errno = error_number;
            else if (size == 0) close_fd(&job->exec_error);
            else if (size > 0 || (errno != EAGAIN && errno != EINTR)) stop_job(job, INTERNAL_ERROR);
        }
        if (events[4].revents && job->pending_size) {
            ssize_t size = write(STDOUT_FILENO, job->pending + job->pending_sent,
                                 job->pending_size - job->pending_sent);
            if (size > 0) {
                job->pending_sent += (size_t)size;
                if (job->pending_sent == job->pending_size) job->pending_size = job->pending_sent = 0;
            } else if (size < 0 && errno != EAGAIN && errno != EINTR) stop_job(job, CANCELLED);
        }
        for (unsigned offset = 0; !job->pending_size && offset < 2; ++offset) {
            unsigned index = (job->next_stream + offset) % 2;
            if (job->output[index] < 0 || !events[index + 1].revents) continue;
            unsigned char data[CHUNK];
            ssize_t size = read(job->output[index], data, sizeof(data));
            if (size > 0) {
                if ((size_t)size > job->limit - job->total[index]) stop_job(job, OUTPUT_LIMIT);
                else {
                    job->total[index] += (size_t)size;
                    queue_frame(job, index ? 'E' : 'O', data, (size_t)size);
                    job->next_stream = 1 - index;
                }
            } else if (size == 0) close_fd(&job->output[index]);
            else if (errno != EAGAIN && errno != EINTR) stop_job(job, INTERNAL_ERROR);
        }
    }
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--protocol-version")) { puts("1"); return 0; }
    if (argc < 6 || strcmp(argv[1], "--limit") || strcmp(argv[3], "--timeout")) return 125;
    char *end;
    errno = 0;
    unsigned long long limit = strtoull(argv[2], &end, 10);
    if (errno || *end || !*argv[2] || argv[2][0] == '-' || !limit || limit > SIZE_MAX) return 125;
    errno = 0;
    double timeout = strtod(argv[4], &end);
    if (errno || *end || !*argv[4] || !isfinite(timeout) || timeout < 0) return 125;
    int command_index = 5;
    bool stream_err = !strcmp(argv[command_index], "--inherit-stderr");
    if (stream_err) ++command_index;
    if (command_index >= argc || strcmp(argv[command_index], "--") || ++command_index >= argc) return 125;
    struct stat input;
    if (fstat(STDIN_FILENO, &input) < 0 || !S_ISFIFO(input.st_mode) ||
        fcntl(STDOUT_FILENO, F_GETFD) < 0) {
        fputs("nixi-process-supervisor requires a private control pipe on stdin\n", stderr);
        return 125;
    }
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_handler = on_signal;
    int signals[] = {SIGINT, SIGTERM, SIGHUP};
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i)
        if (sigaction(signals[i], &action, NULL) < 0) return 125;
    action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &action, NULL) < 0) return 125;
    action.sa_handler = SIG_DFL;
    if (sigaction(SIGCHLD, &action, NULL) < 0) return 125;
    sigset_t empty;
    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) < 0) return 125;
    int out[2], err[2] = {-1, -1}, failure[2];
    if (make_pipe(out) < 0 || (!stream_err && make_pipe(err) < 0) || make_pipe(failure) < 0 ||
        nonblocking(STDIN_FILENO) < 0 || nonblocking(STDOUT_FILENO) < 0 ||
        nonblocking(out[0]) < 0 || (!stream_err && nonblocking(err[0]) < 0) || nonblocking(failure[0]) < 0)
        return 125;
    /* Refuse to start work if its owner disappeared before the spawn. */
    struct pollfd control = {.fd = STDIN_FILENO, .events = POLLIN};
    if (interrupted || poll(&control, 1, 0) != 0) return 125;
    pid_t child = fork();
    if (child < 0) return 125;
    if (child == 0) exec_child(argv + command_index, out, err, failure, stream_err);
    close(out[1]);
    if (!stream_err) close(err[1]);
    close(failure[1]);
    struct capture job = {.child = child, .output = {out[0], err[0]},
                          .exec_error = failure[0], .limit = (size_t)limit};
    /* Establish the group from both sides of fork. EACCES means exec already
     * happened, after the child's successful setpgid. ESRCH permits early exit. */
    if (setpgid(child, child) < 0 && errno != EACCES && errno != ESRCH) {
        job.exec_errno = errno;
        stop_job(&job, INTERNAL_ERROR);
    }
    int status = supervise(&job, timeout);
    close_fd(&job.output[0]);
    close_fd(&job.output[1]);
    close_fd(&job.exec_error);
    return status;
}
