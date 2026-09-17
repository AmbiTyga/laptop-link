#include "ProcessSupport.h"
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>

// posix_spawn avoids running Swift/Foundation code in a forked multithreaded process.
int link_spawn(const char *executable, char *const argv[], char *const envp[],
              const char *cwd, pid_t *pid, int *out_fd, int *err_fd) {
    int out[2] = {-1, -1}, err[2] = {-1, -1};
    if (pipe(out) != 0) return errno;
    if (pipe(err) != 0) { int e = errno; close(out[0]); close(out[1]); return e; }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result) goto close_pipes;
    result = posix_spawnattr_init(&attributes);
    if (result) goto destroy_actions;
#define CHECK(call) do { result = (call); if (result) goto destroy_all; } while (0)
    CHECK(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    CHECK(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CHECK(posix_spawn_file_actions_addchdir_np(&actions, cwd));
#pragma clang diagnostic pop
    CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                 POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK));
    CHECK(posix_spawnattr_setpgroup(&attributes, 0));
    sigset_t empty, defaults;
    sigemptyset(&empty); sigfillset(&defaults);
    CHECK(posix_spawnattr_setsigmask(&attributes, &empty));
    CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
    result = posix_spawn(pid, executable, &actions, &attributes, argv, envp);
destroy_all:
    posix_spawnattr_destroy(&attributes);
destroy_actions:
    posix_spawn_file_actions_destroy(&actions);
close_pipes:
    close(out[1]); close(err[1]);
    if (result) { close(out[0]); close(err[0]); return result; }
    fcntl(out[0], F_SETFL, O_NONBLOCK);
    fcntl(err[0], F_SETFL, O_NONBLOCK);
    *out_fd = out[0]; *err_fd = err[0];
    return 0;
}

int link_exit_code(int status) { return WIFEXITED(status) ? WEXITSTATUS(status) : -1; }
int link_exit_signal(int status) { return WIFSIGNALED(status) ? WTERMSIG(status) : 0; }
