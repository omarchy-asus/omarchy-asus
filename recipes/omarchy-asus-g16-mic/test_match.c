/* SPDX-License-Identifier: MIT */
/* test_match: choosing the capture source by node.name (match.c), on fake
 * PipeWire node lists. The matcher must never pick a monitor, a sink, our own
 * outputs or some other microphone, and on reconnect it finds the same name
 * again (with its new id) or nothing at all.
 */
#include "g16mic.h"
#include "test_util.h"

#define WANT "alsa_input.pci-0000_65_00.6.analog-stereo"

static const g16mic_node_info base[] = {
	{ 31, "alsa_output.pci-0000_65_00.6.analog-stereo", "Audio/Sink", NULL },
	{ 32, WANT ".monitor", "Audio/Source", "monitor" },
	{ 40, "alsa_input.usb-Z_Headset-00.mono-fallback", "Audio/Source", NULL },
	{ 41, WANT, "Audio/Source", NULL },
	{ 50, "g16_mic_processed", "Audio/Source", NULL },
	{ 51, "g16_mic_raw", "Audio/Source", NULL },
	{ 60, "alsa_output.pci-0000_65_00.6.analog-stereo.monitor", "Audio/Source", "monitor" },
};
#define NBASE (sizeof base / sizeof base[0])

static void expect(const char *wanted, const g16mic_node_info *nodes, size_t n,
		   g16mic_match_result want, size_t want_index, const char *what)
{
	size_t idx = 12345;
	g16mic_match_result r = g16mic_match_source(wanted, nodes, n, &idx);

	CHECK(r == want, "%s: got %s want %s", what, g16mic_match_result_name(r),
	      g16mic_match_result_name(want));
	if (want == G16MIC_MATCH_FOUND)
		CHECK_EQ_INT(idx, want_index, "%s: index", what);
	else
		CHECK_EQ_INT(idx, 12345, "%s: index untouched unless found", what);
}

static void test_found(void)
{
	expect(WANT, base, NBASE, G16MIC_MATCH_FOUND, 3, "exact node.name");
	CHECK_EQ_INT(base[3].id, 41, "the right node");
	expect("alsa_input.usb-Z_Headset-00.mono-fallback", base, NBASE, G16MIC_MATCH_FOUND, 2,
	       "another mic only when named exactly");
}

static void test_reconnect(void)
{
	/* The wanted source goes away: the USB mic and the monitors remain. */
	g16mic_node_info gone[NBASE];
	size_t n = 0;

	for (size_t i = 0; i < NBASE; i++)
		if (base[i].id != 41)
			gone[n++] = base[i];
	expect(WANT, gone, n, G16MIC_MATCH_ABSENT, 0, "wanted removed: never the USB mic");

	/* It comes back with a new id, at a different place in the list. */
	g16mic_node_info back[NBASE];
	back[0] = (g16mic_node_info){ 77, WANT, "Audio/Source", NULL };
	for (size_t i = 0; i < n; i++)
		back[i + 1] = gone[i];
	size_t idx = 0;
	CHECK_EQ_INT(g16mic_match_source(WANT, back, n + 1, &idx), G16MIC_MATCH_FOUND, "re-added");
	CHECK_EQ_INT(idx, 0, "re-added index");
	CHECK_EQ_INT(back[idx].id, 77, "re-added node has the new id");

	/* An empty graph (PipeWire restarting) has nothing to offer. */
	expect(WANT, NULL, 0, G16MIC_MATCH_ABSENT, 0, "empty node list");
}

static void test_refusals(void)
{
	expect(WANT ".monitor", base, NBASE, G16MIC_MATCH_REFUSED_MONITOR, 0, "wanted name is a monitor");
	expect("alsa_output.pci-0000_65_00.6.analog-stereo", base, NBASE, G16MIC_MATCH_REFUSED_CLASS,
	       0, "wanted names a sink");
	expect("alsa_input", base, NBASE, G16MIC_MATCH_ABSENT, 0, "prefix only");
	expect("alsa_input.pci-0000_65_00.6", base, NBASE, G16MIC_MATCH_ABSENT, 0, "longer prefix only");
	expect(WANT ".", base, NBASE, G16MIC_MATCH_ABSENT, 0, "name with extra suffix");
	expect("g16_mic_processed", base, NBASE, G16MIC_MATCH_REFUSED_OWN, 0, "our processed output");
	expect("g16_mic_raw", base, NBASE, G16MIC_MATCH_REFUSED_OWN, 0, "our raw output");
	expect(NULL, base, NBASE, G16MIC_MATCH_BAD_NAME, 0, "NULL name");
	expect("", base, NBASE, G16MIC_MATCH_BAD_NAME, 0, "empty name");

	/* A monitor whose name does not end in .monitor is caught by device.class. */
	const g16mic_node_info sneaky[] = {
		{ 5, "loopback-capture", "Audio/Source", "monitor" },
	};
	expect("loopback-capture", sneaky, 1, G16MIC_MATCH_REFUSED_MONITOR, 0,
	       "device.class monitor");

	/* Anything but exactly Audio/Source is refused. */
	static const char *const classes[] = { "Audio/Sink", "Audio/Source/Virtual",
		"Stream/Input/Audio", "Audio/Duplex", "audio/source", NULL };
	for (size_t i = 0; i < sizeof classes / sizeof classes[0]; i++) {
		const g16mic_node_info one[] = { { 9, "node-x", classes[i], NULL } };
		expect("node-x", one, 1, G16MIC_MATCH_REFUSED_CLASS, 0,
		       classes[i] ? classes[i] : "(null media.class)");
	}

	/* Nodes with no name are skipped, not matched. */
	const g16mic_node_info unnamed[] = { { 3, NULL, "Audio/Source", NULL } };
	expect(WANT, unnamed, 1, G16MIC_MATCH_ABSENT, 0, "unnamed node");
}

static void test_ambiguous(void)
{
	const g16mic_node_info dup[] = {
		{ 41, WANT, "Audio/Source", NULL },
		{ 90, "alsa_input.usb-Z_Headset-00.mono-fallback", "Audio/Source", NULL },
		{ 91, WANT, "Stream/Input/Audio", NULL },
	};
	expect(WANT, dup, 3, G16MIC_MATCH_AMBIGUOUS, 0, "two nodes with the same name");
}

static void test_names(void)
{
	static const char *const want[] = { "found", "absent", "refused-monitor", "refused-class",
		"refused-own", "ambiguous", "bad-name" };

	for (int i = 0; i <= G16MIC_MATCH_BAD_NAME; i++)
		CHECK(strcmp(g16mic_match_result_name((g16mic_match_result)i), want[i]) == 0,
		      "result name %d", i);
	CHECK(g16mic_match_result_name((g16mic_match_result)99) != NULL, "out-of-range name");
}

int main(void)
{
	test_found();
	test_reconnect();
	test_refusals();
	test_ambiguous();
	test_names();
	G16T_RETURN();
}
