#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int blocked(int fd) {
    const char *root = getenv("BARKVISOR_PROOF_BACKUP_DIRECTORY");
    if (!root) return 0;
    char link[64];
    char path[PATH_MAX];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t size = readlink(link, path, sizeof(path) - 1);
    if (size < 0) return 0;
    path[size] = 0;
    size_t length = strlen(root);
    return strncmp(path, root, length) == 0 && path[length] == '/'
        && (strstr(path, ".backup-pending") || strstr(path, "db-"));
}

ssize_t pwrite(int fd, const void *buffer, size_t count, off_t offset) {
    static ssize_t (*next)(int, const void *, size_t, off_t);
    if (!next) next = dlsym(RTLD_NEXT, "pwrite");
    if (blocked(fd)) { errno = ENOSPC; return -1; }
    return next(fd, buffer, count, offset);
}

ssize_t pwrite64(int fd, const void *buffer, size_t count, off64_t offset) {
    static ssize_t (*next)(int, const void *, size_t, off64_t);
    if (!next) next = dlsym(RTLD_NEXT, "pwrite64");
    if (blocked(fd)) { errno = ENOSPC; return -1; }
    return next(fd, buffer, count, offset);
}

ssize_t write(int fd, const void *buffer, size_t count) {
    static ssize_t (*next)(int, const void *, size_t);
    if (!next) next = dlsym(RTLD_NEXT, "write");
    if (blocked(fd)) { errno = ENOSPC; return -1; }
    return next(fd, buffer, count);
}
