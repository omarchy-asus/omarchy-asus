/* A polkit authority for winlockd.test.sh: answers CheckAuthorization with
 * $FAKE_POLKIT_ALLOW (1 = authorized) and logs "<action> <subject kind>". */
#include <stdio.h>
#include <stdlib.h>
#include <systemd/sd-bus.h>

static int check(sd_bus_message *m, void *u, sd_bus_error *e) {
    const char *kind, *action;
    int r = sd_bus_message_enter_container(m, 'r', "sa{sv}");
    if (r >= 0) r = sd_bus_message_read(m, "s", &kind);
    if (r >= 0) r = sd_bus_message_skip(m, "a{sv}");
    if (r >= 0) r = sd_bus_message_exit_container(m);
    if (r >= 0) r = sd_bus_message_read(m, "s", &action);
    if (r < 0) return r;
    FILE *f = fopen(getenv("FAKE_POLKIT_LOG"), "a");
    if (f) { fprintf(f, "%s %s\n", action, kind); fclose(f); }
    int ok = atoi(getenv("FAKE_POLKIT_ALLOW") ?: "0");
    return sd_bus_reply_method_return(m, "(bba{ss})", ok, 0, 0);
}

static const sd_bus_vtable vt[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("CheckAuthorization", "(sa{sv})sa{ss}us", "(bba{ss})", check, 0),
    SD_BUS_VTABLE_END,
};

int main(void) {
    sd_bus *bus;
    if (sd_bus_open_system(&bus) < 0 ||
        sd_bus_add_object_vtable(bus, NULL, "/org/freedesktop/PolicyKit1/Authority",
                                 "org.freedesktop.PolicyKit1.Authority", vt, NULL) < 0 ||
        sd_bus_request_name(bus, "org.freedesktop.PolicyKit1", 0) < 0)
        return 1;
    for (;;) {
        int r = sd_bus_process(bus, NULL);
        if (r < 0) return 1;
        if (r == 0 && sd_bus_wait(bus, (uint64_t)-1) < 0) return 1;
    }
}
