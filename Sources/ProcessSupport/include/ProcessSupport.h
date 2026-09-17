#pragma once
#include <sys/types.h>

int link_spawn(const char *executable, char *const argv[], char *const envp[],
              const char *cwd, pid_t *pid, int *out_fd, int *err_fd);
int link_exit_code(int status);
int link_exit_signal(int status);
