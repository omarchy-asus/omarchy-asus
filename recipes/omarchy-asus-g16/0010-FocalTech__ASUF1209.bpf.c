// SPDX-License-Identifier: GPL-2.0-only
/*
 * FocalTech ASUF1209 touchpad (I2C 2808:0219), as fitted to the ASUS ROG
 * Zephyrus G16 GA605KM: per-contact touch size for palm detection.
 *
 * The pad's multitouch input report (ID 4) gives each contact only
 * Confidence, Tip Switch, Contact ID, X and Y. After the standard fields it
 * carries five 16-bit vendor fields (page 0xFF01, usages 0x02-0x06), one per
 * contact slot in report order, all declared Constant, so hid-multitouch
 * drops them and the evdev device has no ABS_MT_TOUCH_MAJOR. Captured on the
 * G16, each value is:
 *
 *   bits  0-7   signal strength: a fingertip stays at or below about 62,
 *               a palm heel climbs well past that and often saturates at 255
 *   bits  8-11  contact extent along one sensor axis, in sensor cells
 *   bits 12-15  contact extent along the other axis, in sensor cells
 *
 * The cell extents smear with motion (a fast swipe finger reads 9 x 7, as
 * large as a palm), so only the strength byte separates palms from fingers.
 *
 * This program rewrites the report descriptor so each finger collection
 * ends with an 8-bit Width (Digitizer 0x48) with no physical unit, and
 * repacks every report 4 so that byte carries its slot's strength.
 * hid-multitouch then publishes ABS_MT_TOUCH_MAJOR, and libinput's
 * size-based palm detection (AttrPalmSizeThreshold) can run. The report
 * keeps its length: the five vendor fields shrink to 8 bits and keep the
 * cell extents, so hidraw still shows them.
 *
 * Report 4 payload, after the report ID byte (byte offsets):
 *   before: 5 x [flags, X(2), Y(2)] @0, scan time(2) @25, count @27,
 *           button @28, 0x1F(4) @29, 0x02-0x06 5 x 16-bit @33,
 *           0x20(4) @43, 0x21 @47, 0x14 @48
 *   after:  5 x [flags, X(2), Y(2), width] @0, scan time(2) @30, count @32,
 *           button @33, 0x1F(4) @34, 0x02-0x06 5 x 8-bit (extents) @38,
 *           0x20(4) @43, 0x21 @47, 0x14 @48
 */

#include "vmlinux.h"
#include "hid_bpf.h"
#include "hid_bpf_helpers.h"
#include <bpf/bpf_tracing.h>

#define VID_FOCALTECH		0x2808
#define PID_ASUF1209		0x0219

#define RDESC_SIZE		764
#define REPORT_ID		4
#define REPORT_SIZE		50	/* with the report ID */
#define SLOTS			5
#define SLOT_IN			5	/* bytes per contact, as sent */
#define SLOT_OUT		6	/* bytes per contact, with width */
#define REPACKED		44	/* report bytes the repack rewrites */

HID_BPF_CONFIG(
	HID_DEVICE(BUS_I2C, HID_GROUP_ANY, VID_FOCALTECH, PID_ASUF1209)
);

/*
 * Inserted before each finger collection's End Collection. Every finger
 * collection and the Scan Time field after the last one set their own
 * units, ranges and sizes, so nothing here leaks into a later field.
 */
#define WIDTH_FIELD \
	0x05, 0x0d,		/* Usage Page (Digitizers) */ \
	0x09, 0x48,		/* Usage (Width) */ \
	0x15, 0x00,		/* Logical Minimum (0) */ \
	0x26, 0xff, 0x00,	/* Logical Maximum (255) */ \
	0x35, 0x00,		/* Physical Minimum (0) */ \
	0x45, 0x00,		/* Physical Maximum (0) */ \
	0x55, 0x00,		/* Unit Exponent (0) */ \
	0x65, 0x00,		/* Unit (None) */ \
	0x75, 0x08,		/* Report Size (8) */ \
	0x95, 0x01,		/* Report Count (1) */ \
	0x81, 0x02,		/* Input (Data,Var,Abs) */

static const __u8 width_field[] = { WIDTH_FIELD };
#define WIDTH_LEN		sizeof(width_field)
#define FIXED_RDESC_SIZE	(RDESC_SIZE + SLOTS * WIDTH_LEN)

/* Offsets in the original descriptor */
#define REPORT4_ID_OFFSET	58	/* Report ID (4) */
#define FINGER_END(n)		(128 + (n) * 69)	/* End Collection of finger n */
#define VENDOR_SIZE(n)		(484 + (n) * 8)	/* Report Size (16) of usage 0x02 + n */

static __always_inline bool is_asuf1209_rdesc(const __u8 *rdesc, unsigned int size)
{
	int n;

	if (size != RDESC_SIZE)
		return false;
	if (rdesc[REPORT4_ID_OFFSET] != 0x85 || rdesc[REPORT4_ID_OFFSET + 1] != REPORT_ID)
		return false;
	for (n = 0; n < SLOTS; n++) {
		/* ... Usage (Y) ... Input (Data,Var,Abs), End Collection */
		if (rdesc[FINGER_END(n) - 2] != 0x81 || rdesc[FINGER_END(n) - 1] != 0x02 ||
		    rdesc[FINGER_END(n)] != 0xc0)
			return false;
		/* Usage (0x02 + n), Report Size (16), Report Count (1), Input (Cnst,Var,Abs) */
		if (rdesc[VENDOR_SIZE(n) - 2] != 0x09 || rdesc[VENDOR_SIZE(n) - 1] != 0x02 + n ||
		    rdesc[VENDOR_SIZE(n)] != 0x75 || rdesc[VENDOR_SIZE(n) + 1] != 0x10 ||
		    rdesc[VENDOR_SIZE(n) + 4] != 0x81 || rdesc[VENDOR_SIZE(n) + 5] != 0x03)
			return false;
	}
	return true;
}

SEC(HID_BPF_RDESC_FIXUP)
int BPF_PROG(asuf1209_fix_rdesc, struct hid_bpf_ctx *hctx)
{
	__u8 *data = hid_bpf_get_data(hctx, 0, HID_MAX_DESCRIPTOR_SIZE);

	int i, n, shift;

	if (!data || !is_asuf1209_rdesc(data, hctx->size))
		return 0;

	/* Open a WIDTH_LEN gap before each finger's End Collection: walk
	 * back from the end, moving every byte right by WIDTH_LEN for each
	 * End Collection at or before it, so nothing is overwritten unread. */
	for (i = RDESC_SIZE - 1; i >= 0; i--) {
		shift = 0;
		for (n = 0; n < SLOTS; n++)
			if (i >= FINGER_END(n))
				shift += WIDTH_LEN;
		if (i + shift >= FIXED_RDESC_SIZE)
			return 0;
		data[i + shift] = data[i];
	}
	for (n = 0; n < SLOTS; n++)
		__builtin_memcpy(data + FINGER_END(n) + n * WIDTH_LEN, width_field, WIDTH_LEN);

	/* The vendor fields 0x02-0x06 now hold only their high byte. */
	for (n = 0; n < SLOTS; n++)
		data[VENDOR_SIZE(n) + SLOTS * WIDTH_LEN + 1] = 0x08;

	return FIXED_RDESC_SIZE;
}

SEC(HID_BPF_DEVICE_EVENT)
int BPF_PROG(asuf1209_fix_event, struct hid_bpf_ctx *hctx)
{
	__u8 *data = hid_bpf_get_data(hctx, 0, REPORT_SIZE);
	__u8 in[REPACKED];
	int s;

	if (!data || data[0] != REPORT_ID || hctx->size < REPORT_SIZE)
		return 0;

	__builtin_memcpy(in, data, REPACKED);

	for (s = 0; s < SLOTS; s++) {
		__builtin_memcpy(data + 1 + s * SLOT_OUT, in + 1 + s * SLOT_IN, SLOT_IN);
		data[1 + s * SLOT_OUT + SLOT_IN] = in[34 + 2 * s];	/* strength */
	}
	__builtin_memcpy(data + 31, in + 26, 8);	/* scan time, count, button, 0x1F */
	for (s = 0; s < SLOTS; s++)
		data[39 + s] = in[35 + 2 * s];		/* cell extents */

	return 0;
}

HID_BPF_OPS(asuf1209_palm_size) = {
	.hid_device_event = (void *)asuf1209_fix_event,
	.hid_rdesc_fixup = (void *)asuf1209_fix_rdesc,
};

SEC("syscall")
int probe(struct hid_bpf_probe_args *ctx)
{
	ctx->retval = is_asuf1209_rdesc(ctx->rdesc, ctx->rdesc_size) ? 0 : -EINVAL;
	return 0;
}

char _license[] SEC("license") = "GPL";
