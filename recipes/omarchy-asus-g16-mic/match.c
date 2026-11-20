/* SPDX-License-Identifier: MIT */
/* match.c: which PipeWire node g16-mic captures from.
 *
 * The user names one source by its node.name. The matcher compares node.name
 * exactly (never a prefix, a substring or a description) and never falls back
 * to "the first available source", so a reconnect finds the same microphone
 * again or nothing. It refuses:
 *   - sink monitors (a name ending in ".monitor", or device.class "monitor"),
 *     which would feed playback back in as speech;
 *   - anything whose media.class is not exactly "Audio/Source" (sinks,
 *     virtual sources, application streams, duplex nodes);
 *   - our own outputs (g16_mic_*), which would be a feedback loop;
 *   - a name that more than one node carries.
 */
#include <string.h>

#include "g16mic.h"

static const char *const result_names[] = {
	"found", "absent", "refused-monitor", "refused-class", "refused-own", "ambiguous", "bad-name",
};

const char *g16mic_match_result_name(g16mic_match_result r)
{
	if ((int)r < 0 || (size_t)r >= sizeof result_names / sizeof result_names[0])
		return "unknown";
	return result_names[r];
}

static int ends_with(const char *s, const char *suffix)
{
	size_t n = strlen(s), m = strlen(suffix);

	return n >= m && strcmp(s + n - m, suffix) == 0;
}

g16mic_match_result g16mic_match_source(const char *wanted, const g16mic_node_info *nodes, size_t n, size_t *index_out)
{
	if (!wanted || !*wanted)
		return G16MIC_MATCH_BAD_NAME;
	if (ends_with(wanted, ".monitor"))
		return G16MIC_MATCH_REFUSED_MONITOR;
	if (strncmp(wanted, "g16_mic_", 8) == 0)
		return G16MIC_MATCH_REFUSED_OWN;

	size_t matches = 0, found = 0;
	for (size_t i = 0; nodes && i < n; i++) {
		if (nodes[i].node_name && strcmp(nodes[i].node_name, wanted) == 0) {
			if (matches == 0)
				found = i;
			matches++;
		}
	}
	if (matches == 0)
		return G16MIC_MATCH_ABSENT;
	if (matches > 1)
		return G16MIC_MATCH_AMBIGUOUS;

	const g16mic_node_info *node = &nodes[found];
	if (node->device_class && strcmp(node->device_class, "monitor") == 0)
		return G16MIC_MATCH_REFUSED_MONITOR;
	if (!node->media_class || strcmp(node->media_class, "Audio/Source") != 0)
		return G16MIC_MATCH_REFUSED_CLASS;
	if (index_out)
		*index_out = found;
	return G16MIC_MATCH_FOUND;
}
