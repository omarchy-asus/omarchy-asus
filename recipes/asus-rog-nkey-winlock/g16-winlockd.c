/* g16-winlockd: owns the ROG N-Key keyboard's (USB 0b05:19b6) hidraw node so
 * the desktop user doesn't have to.
 *
 * Started by udev for each 0b05:19b6 hidraw node (g16-winlockd@hidrawN.service);
 * an instance whose node doesn't declare report ID 0x5D exits at once. The one
 * that does waits on the node (epoll, no timers), turns every 5D BF 01 xx report
 * into the D-Bus signal LockChanged(b), and offers two methods:
 *   Status() -> b      GetFeature 5D, or the last state seen; Error.Unknown
 *                      before the first report or SetLocked
 *   SetLocked(b)       SetFeature 5D BF 00 xx, output report 01 01, then
 *                      GetFeature 5D to read the result back;
 *                      root, or polkit io.github.omarchy-asus.winlock.set-locked
 *
 * Feature report 0x5D answers the last command written to it, and at boot that
 * is Aura's, not Win-lock's: there is no read-only query for the lock. Windows'
 * AsusWinKeyActiveGuard only reads it back right after its own 5D BF write, and
 * so does SetLocked here.
 * Raw reports never leave the process.
 *
 * G16_WINLOCKD_SYSFS and G16_WINLOCKD_DEV move /sys/class/hidraw and /dev, for
 * the tests (winlockd.test.sh); the unit sets neither.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/hidraw.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <systemd/sd-bus.h>
#include <systemd/sd-event.h>

#define NAME "io.github.omarchy_asus.WinLock1"
#define PATH "/io/github/omarchy_asus/WinLock1"
#define POLKIT_ACTION "io.github.omarchy-asus.winlock.set-locked"
#define REPORT_ID 0x5D
#define REPORT_LEN 64

static int hid = -1;
static int last = -1; /* last state seen, -1 = none yet */
static sd_bus *bus;

static const char *env_or(const char *name, const char *dflt) {
    const char *v = getenv(name);
    return v && *v ? v : dflt;
}

/* Does the HID report descriptor declare report ID 0x5D? Walks the items, so a
 * 0x85 that is only a data byte doesn't count (same walk as before, in Python). */
static bool declares_5d(const unsigned char *d, size_t n) {
    for (size_t i = 0; i < n;) {
        unsigned char p = d[i];
        if (p == 0xFE) { /* long item: FE size tag data */
            if (i + 2 >= n) return false;
            i += 3 + d[i + 1];
            continue;
        }
        size_t size = (size_t[]){0, 1, 2, 4}[p & 3];
        if (i + 1 + size > n) return false;
        if ((p & 0xFC) == 0x84 && size >= 1 && d[i + 1] == REPORT_ID) return true;
        i += 1 + size;
    }
    return false;
}

static ssize_t read_file(const char *path, void *buf, size_t len) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, len);
    close(fd);
    return n;
}

/* The node is the N-Key keyboard's Win-lock interface. */
static bool is_winlock_node(const char *node) {
    const char *sys = env_or("G16_WINLOCKD_SYSFS", "/sys/class/hidraw");
    char path[512], buf[4096];
    snprintf(path, sizeof path, "%s/%s/device/uevent", sys, node);
    ssize_t n = read_file(path, buf, sizeof buf - 1);
    if (n <= 0) return false;
    buf[n] = 0;
    if (!strstr(buf, "HID_ID=0003:00000B05:000019B6")) return false;
    snprintf(path, sizeof path, "%s/%s/device/report_descriptor", sys, node);
    n = read_file(path, buf, sizeof buf);
    return n > 0 && declares_5d((unsigned char *)buf, (size_t)n);
}

static int on_report(sd_event_source *s, int fd, uint32_t revents, void *u) {
    unsigned char r[REPORT_LEN];
    ssize_t n = read(fd, r, sizeof r);
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) return 0;
    if (n <= 0) { /* unplugged or rebound: udev starts a new instance */
        fprintf(stderr, "keyboard gone (%s)\n", n < 0 ? strerror(errno) : "EOF");
        return sd_event_exit(sd_event_source_get_event(s), 0);
    }
    if (n < 4 || r[0] != REPORT_ID || r[1] != 0xBF || r[2] != 0x01) return 0;
    last = r[3] != 0;
    printf("Win-lock %s\n", last ? "on" : "off");
    fflush(stdout);
    int e = sd_bus_emit_signal(bus, PATH, NAME, "LockChanged", "b", last);
    if (e < 0) fprintf(stderr, "LockChanged: %s\n", strerror(-e));
    return 0;
}

/* GetFeature 5D: the lock state (0 or 1) when the reply is to a 5D BF command,
 * else -1 (the reply belongs to Aura, or the ioctl failed). */
static int read_back(void) {
    unsigned char buf[REPORT_LEN] = {REPORT_ID};
    int n = ioctl(hid, HIDIOCGFEATURE(REPORT_LEN), buf);
    if (n >= 4 && buf[0] == REPORT_ID && buf[1] == 0xBF) return buf[3] != 0;
    return -1;
}

static int method_status(sd_bus_message *m, void *u, sd_bus_error *err) {
    int s = read_back();
    if (s >= 0) last = s;
    if (last >= 0) return sd_bus_reply_method_return(m, "b", last);
    return sd_bus_error_set(err, NAME ".Error.Unknown",
                            "Win-lock state not known until the first Fn+Super or SetLocked");
}

/* Root, or polkit says yes for this caller (allow_active: the local, active session). */
static int authorized(sd_bus_message *m, sd_bus_error *err) {
    sd_bus_creds *c = NULL;
    uid_t uid;
    int r = sd_bus_query_sender_creds(m, SD_BUS_CREDS_EUID, &c);
    if (r >= 0) r = sd_bus_creds_get_euid(c, &uid);
    sd_bus_creds_unref(c);
    if (r >= 0 && uid == 0) return 1;

    sd_bus_message *reply = NULL;
    int ok = 0;
    r = sd_bus_call_method(bus, "org.freedesktop.PolicyKit1", "/org/freedesktop/PolicyKit1/Authority",
                           "org.freedesktop.PolicyKit1.Authority", "CheckAuthorization", err, &reply,
                           "(sa{sv})sa{ss}us", "system-bus-name", 1, "name", "s",
                           sd_bus_message_get_sender(m), POLKIT_ACTION, 0, 0, "");
    if (r >= 0) r = sd_bus_message_enter_container(reply, 'r', "bba{ss}");
    if (r >= 0) r = sd_bus_message_read(reply, "b", &ok);
    sd_bus_message_unref(reply);
    if (r < 0) return r;
    return ok;
}

static int method_set_locked(sd_bus_message *m, void *u, sd_bus_error *err) {
    int locked;
    int r = sd_bus_message_read(m, "b", &locked);
    if (r < 0) return r;
    r = authorized(m, err);
    if (r < 0) return r;
    if (r == 0) return sd_bus_error_set(err, SD_BUS_ERROR_ACCESS_DENIED, "not authorized: " POLKIT_ACTION);

    unsigned char f[REPORT_LEN] = {REPORT_ID, 0xBF, 0x00, locked ? 0x01 : 0x00};
    static const unsigned char commit[2] = {0x01, 0x01}; /* a write, not another SetFeature */
    if (ioctl(hid, HIDIOCSFEATURE(REPORT_LEN), f) < 0 || write(hid, commit, sizeof commit) != sizeof commit)
        return sd_bus_error_set_errno(err, errno ? errno : EIO);
    /* The Windows tool's read-back: 100 ms, then GetFeature now answers 5D BF.
     * Without a 5D BF reply, the write went through: take it as the state. */
    nanosleep(&(struct timespec){.tv_nsec = 100 * 1000 * 1000}, NULL);
    int s = read_back();
    last = s >= 0 ? s : locked != 0;
    return sd_bus_reply_method_return(m, "");
}

/* UNPRIVILEGED: sd-bus refuses other users' calls to a root service otherwise;
 * SetLocked does its own check. */
static const sd_bus_vtable vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD_WITH_ARGS("Status", SD_BUS_NO_ARGS, SD_BUS_RESULT("b", locked), method_status,
                            SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD_WITH_ARGS("SetLocked", SD_BUS_ARGS("b", locked), SD_BUS_NO_RESULT, method_set_locked,
                            SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_SIGNAL_WITH_ARGS("LockChanged", SD_BUS_ARGS("b", locked), 0),
    SD_BUS_VTABLE_END,
};

int main(int argc, char **argv) {
    if (argc != 2 || strchr(argv[1], '/')) {
        fprintf(stderr, "usage: g16-winlockd hidrawN\n");
        return 2;
    }
    if (!is_winlock_node(argv[1])) {
        printf("%s is not the ROG N-Key Win-lock interface; nothing to do\n", argv[1]);
        return 0;
    }
    char dev[512];
    snprintf(dev, sizeof dev, "%s/%s", env_or("G16_WINLOCKD_DEV", "/dev"), argv[1]);
    hid = open(dev, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOCTTY);
    if (hid < 0) {
        fprintf(stderr, "%s: %s\n", dev, strerror(errno));
        return 1;
    }

    sd_event *ev = NULL;
    int r = sd_event_default(&ev);
    if (r >= 0) r = sd_bus_open_system(&bus);
    if (r >= 0) r = sd_bus_set_exit_on_disconnect(bus, 1);
    if (r >= 0) r = sd_bus_add_object_vtable(bus, NULL, PATH, NAME, vtable, NULL);
    if (r >= 0) r = sd_bus_request_name(bus, NAME, 0);
    if (r >= 0) r = sd_bus_attach_event(bus, ev, 0);
    if (r >= 0) r = sd_event_add_io(ev, NULL, hid, EPOLLIN, on_report, NULL);
    if (r < 0) {
        fprintf(stderr, "setup: %s\n", strerror(-r));
        return 1;
    }
    printf("watching %s\n", dev);
    fflush(stdout);
    r = sd_event_loop(ev);
    return r < 0 ? 1 : 0;
}
