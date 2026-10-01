#include "NetToysLockFixture.h"
#include <fcntl.h>
#include <stdint.h>
#include <sys/file.h>
#include <unistd.h>

pid_t nettoys_start_lock_holder(const char *path, int reply_descriptor) {
    pid_t child = fork();
    if (child != 0) return child;
    /* The child uses only async-signal-safe C calls after fork. */
    int descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    uint8_t won = descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0;
    write(reply_descriptor, &won, 1);
    if (won) while (1) pause();
    _exit(0);
}
