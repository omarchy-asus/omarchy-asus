/* vptr: drive a wlr virtual pointer from stdin.
 * lines: "abs X Y W H" (absolute in a WxH layout extent), "click", "sleep MS" */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include <linux/input-event-codes.h>
#include "vp.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *mgr;

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
    if (!strcmp(iface, wl_seat_interface.name)) seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
        mgr = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener rl = {reg_global, reg_remove};

static uint32_t t;
int main(void)
{
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) return 1;
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &rl, NULL);
    wl_display_roundtrip(dpy);
    if (!mgr) { fprintf(stderr, "no virtual pointer manager\n"); return 1; }
    struct zwlr_virtual_pointer_v1 *p = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr, seat);
    wl_display_roundtrip(dpy);
    char line[128];
    while (fgets(line, sizeof line, stdin))
    {
        unsigned x, y, w, h, ms;
        if (sscanf(line, "abs %u %u %u %u", &x, &y, &w, &h) == 4)
        {
            zwlr_virtual_pointer_v1_motion_absolute(p, t += 10, x, y, w, h);
            zwlr_virtual_pointer_v1_frame(p);
        }
        else if (!strncmp(line, "click", 5))
        {
            zwlr_virtual_pointer_v1_button(p, t += 10, BTN_LEFT, 1);
            zwlr_virtual_pointer_v1_frame(p);
            wl_display_flush(dpy);
            usleep(50000);
            zwlr_virtual_pointer_v1_button(p, t += 10, BTN_LEFT, 0);
            zwlr_virtual_pointer_v1_frame(p);
        }
        else if (sscanf(line, "sleep %u", &ms) == 1)
        {
            wl_display_flush(dpy);
            usleep(ms * 1000);
        }
        wl_display_roundtrip(dpy);
    }
    zwlr_virtual_pointer_v1_destroy(p);
    wl_display_roundtrip(dpy);
    return 0;
}
