#include <sys/mman.h>
#include "cshm.h"

int mini_shm_open(const char *name, int oflag, mode_t mode) { return shm_open(name, oflag, mode); }
