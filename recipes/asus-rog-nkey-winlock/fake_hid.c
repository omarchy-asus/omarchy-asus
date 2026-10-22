/* LD_PRELOAD shim for winlockd.test.sh: the fake hidraw node is a pty, which
 * has no feature reports, so HIDIOCSFEATURE is logged to $FAKE_HID_LOG as hex and
 * HIDIOCGFEATURE answers 5D BF 00 <$FAKE_HID_STATE> (or fails without it). */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <linux/hidraw.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>

int ioctl(int fd, unsigned long req, ...) {
    va_list ap;
    va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    unsigned char *b = arg;
    if (req == HIDIOCSFEATURE(64)) {
        FILE *f = fopen(getenv("FAKE_HID_LOG"), "a");
        if (!f) return -1;
        fprintf(f, "SetFeature %02x %02x %02x %02x\n", b[0], b[1], b[2], b[3]);
        fclose(f);
        return 64;
    }
    if (req == HIDIOCGFEATURE(64)) {
        const char *s = getenv("FAKE_HID_STATE");
        if (!s) { errno = EIO; return -1; }
        memset(b, 0, 64);
        b[0] = 0x5D; b[1] = 0xBF; b[3] = (unsigned char)atoi(s);
        return 64;
    }
    int (*real)(int, unsigned long, void *) = (int (*)(int, unsigned long, void *))dlsym(RTLD_NEXT, "ioctl");
    return real(fd, req, arg);
}
