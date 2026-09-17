#pragma once
#include <sys/types.h>

int link_spawn(const char *executable, char *const argv[], char *const envp[],
              const char *cwd, pid_t *pid, int *out_fd, int *err_fd);
int link_exit_code(int status);
int link_exit_signal(int status);
int link_terminal_spawn(const char *executable, char *const argv[], char *const envp[],
                       const char *cwd, int cols, int rows, pid_t *pid, int *master);
int link_terminal_resize(int fd, int cols, int rows);
void link_terminal_kill_session(pid_t leader, int sig);
