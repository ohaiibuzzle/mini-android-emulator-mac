#include <sys/types.h>

/// shm_open is variadic, which Swift can't call.
int mini_shm_open(const char *name, int oflag, mode_t mode);
