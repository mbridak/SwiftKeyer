#include "CSerialShim.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <unistd.h>

int serial_wait_ready(int descriptor, int forWrite, int timeoutMilliseconds) {
    fd_set descriptors;
    struct timeval timeout;
    int result;

    if (descriptor < 0 || descriptor >= FD_SETSIZE) {
        errno = EBADF;
        return -1;
    }
    if (timeoutMilliseconds < 0) {
        errno = EINVAL;
        return -1;
    }

    FD_ZERO(&descriptors);
    FD_SET(descriptor, &descriptors);
    timeout.tv_sec = timeoutMilliseconds / 1000;
    timeout.tv_usec = (timeoutMilliseconds % 1000) * 1000;

    do {
        if (forWrite) {
            result = select(descriptor + 1, NULL, &descriptors, NULL, &timeout);
        } else {
            result = select(descriptor + 1, &descriptors, NULL, NULL, &timeout);
        }
    } while (result < 0 && errno == EINTR);

    if (result <= 0) {
        return result;
    }
    if (!FD_ISSET(descriptor, &descriptors)) {
        errno = EIO;
        return -1;
    }
    return 1;
}

int serial_bytes_available(int descriptor) {
    int available;
    int result;

    do {
        available = 0;
        result = ioctl(descriptor, FIONREAD, &available);
    } while (result < 0 && errno == EINTR);

    return result < 0 ? -1 : available;
}
