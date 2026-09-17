#include "ProcessSupport.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <libproc.h>
#include <stdlib.h>

// All allocations/Swift work happen before fork. The child only calls libc's
// async-signal-safe functions before exec; the status pipe reports exec errors.
int link_terminal_spawn(const char *executable, char *const argv[], char *const envp[],
                       const char *cwd, int cols, int rows, pid_t *pid, int *master) {
    int report[2];
    if (pipe(report)) return errno;
    fcntl(report[0], F_SETFD, FD_CLOEXEC); fcntl(report[1], F_SETFD, FD_CLOEXEC);
    int limit = getdtablesize();
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    pid_t child = forkpty(master, NULL, NULL, &size);
    if (child < 0) { int e = errno; close(report[0]); close(report[1]); return e; }
    if (child == 0) {
        close(report[0]);
        for (int fd = 3; fd < limit; fd++) if (fd != report[1]) close(fd);
        sigset_t empty; sigemptyset(&empty); sigprocmask(SIG_SETMASK, &empty, NULL);
        struct sigaction action = {.sa_handler = SIG_DFL}; sigemptyset(&action.sa_mask);
        for (int s = 1; s < NSIG; s++) sigaction(s, &action, NULL);
        if (chdir(cwd) == 0) execve(executable, argv, envp);
        int e = errno; (void)write(report[1], &e, sizeof(e)); _exit(127);
    }
    close(report[1]);
    int error = 0; ssize_t count;
    do { count = read(report[0], &error, sizeof(error)); } while (count < 0 && errno == EINTR);
    close(report[0]);
    if (count != 0) {
        if (count < 0) error = errno;
        kill(child, SIGKILL); while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        close(*master); *master = -1; return error ? error : EIO;
    }
    fcntl(*master, F_SETFD, FD_CLOEXEC);
    fcntl(*master, F_SETFL, O_NONBLOCK);
    *pid = child;
    return 0;
}

int link_terminal_resize(int fd, int cols, int rows) {
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    return ioctl(fd, TIOCSWINSZ, &size) == 0 ? 0 : errno;
}

// Call only while the unreaped session leader still owns this PID. Interactive
// job control gives each foreground/background job its own process group.
void link_terminal_kill_session(pid_t leader, int sig) {
    int capacity = proc_listallpids(NULL, 0) + 128;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (pids) {
        int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
        for (int i = 0; i < count && i < capacity; i++)
            if (pids[i] > 1 && pids[i] != leader && getsid(pids[i]) == leader) kill(pids[i], sig);
        free(pids);
    }
    kill(-leader, sig); kill(leader, sig);
}
