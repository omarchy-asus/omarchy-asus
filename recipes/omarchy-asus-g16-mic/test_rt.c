/* SPDX-License-Identifier: MIT */
/* test_rt: the real-time buffers (rt.c).
 *
 * - g16mic_fifo keeps every sample in order across wrap-around with odd sizes
 * - g16mic_spsc never grows: a full queue drops and counts, and under a slow
 *   consumer every attempt is either popped (in order) or counted as dropped
 * - g16mic_ring counts overflow/underflow, zero-fills a short read and keeps
 *   data intact across wrap-around
 */
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <time.h>

#include "g16mic.h"
#include "test_util.h"

static void test_fifo(void)
{
	g16mic_fifo f;
	float in[16], out[16];
	float next_in = 0.0f, next_out = 0.0f;
	static const size_t wsizes[] = { 3, 5, 1, 7, 2 };
	static const size_t rsizes[] = { 5, 1, 3, 2, 7, 4 };

	CHECK(g16mic_fifo_init(&f, 0) == -1, "zero capacity is refused");
	CHECK_EQ_INT(g16mic_fifo_init(&f, 7), 0, "init cap 7");
	CHECK_EQ_INT(g16mic_fifo_space(&f), 7, "empty fifo has full space");

	for (int iter = 0; iter < 200; iter++) {
		size_t w = wsizes[iter % 5], r = rsizes[iter % 6];
		size_t space = g16mic_fifo_space(&f);
		size_t want = w < space ? w : space;

		for (size_t i = 0; i < w; i++)
			in[i] = next_in + (float)i;
		size_t wrote = g16mic_fifo_write(&f, in, w);
		CHECK_EQ_INT(wrote, want, "write returns min(n, space) at iteration %d", iter);
		next_in += (float)wrote;
		CHECK(g16mic_fifo_fill(&f) + g16mic_fifo_space(&f) == 7, "fill + space == cap");

		size_t fill = g16mic_fifo_fill(&f);
		size_t got = g16mic_fifo_read(&f, out, r);
		CHECK_EQ_INT(got, r < fill ? r : fill, "read returns min(n, fill)");
		for (size_t i = 0; i < got; i++) {
			CHECK(out[i] == next_out, "sample %g at iteration %d, want %g",
			      (double)out[i], iter, (double)next_out);
			next_out += 1.0f;
		}
	}
	/* Overfill: only the space is taken. */
	g16mic_fifo_read(&f, NULL, g16mic_fifo_fill(&f));
	for (size_t i = 0; i < 16; i++)
		in[i] = (float)i;
	CHECK_EQ_INT(g16mic_fifo_write(&f, in, 16), 7, "overfill writes only cap");
	CHECK_EQ_INT(g16mic_fifo_write(&f, in, 1), 0, "full fifo takes nothing");
	CHECK_EQ_INT(g16mic_fifo_read(&f, out, 16), 7, "drain");
	for (size_t i = 0; i < 7; i++)
		CHECK(out[i] == (float)i, "overfill kept the first samples");
	CHECK_EQ_INT(g16mic_fifo_read(&f, out, 1), 0, "empty fifo gives nothing");
	g16mic_fifo_free(&f);
}

struct rec {
	uint64_t seq;
	float pad[7];
};

static void test_spsc_capacity(void)
{
	g16mic_spsc q;
	struct rec r = { 0 };

	CHECK(g16mic_spsc_init(&q, sizeof r, 3) == -1, "non-power-of-two cap refused");
	CHECK(g16mic_spsc_init(&q, sizeof r, 1) == -1, "cap 1 refused");
	CHECK(g16mic_spsc_init(&q, 0, 8) == -1, "zero slot size refused");
	CHECK_EQ_INT(g16mic_spsc_init(&q, sizeof r, 8), 0, "init cap 8");

	int accepted = 0;
	for (int i = 0; i < 50; i++) {
		r.seq = (uint64_t)i;
		accepted += g16mic_spsc_push(&q, &r);
	}
	CHECK_EQ_INT(accepted, 8, "exactly cap records accepted");
	CHECK_EQ_INT(g16mic_spsc_dropped(&q), 42, "dropped == attempts - cap");
	CHECK_EQ_INT(q.cap, 8, "queue did not grow");

	for (int i = 0; i < 8; i++) {
		CHECK_EQ_INT(g16mic_spsc_pop(&q, &r), 1, "pop %d", i);
		CHECK_EQ_INT(r.seq, i, "the first cap records were kept, in order");
	}
	CHECK_EQ_INT(g16mic_spsc_pop(&q, &r), 0, "empty after cap pops");
	/* Room again after popping. */
	r.seq = 99;
	CHECK_EQ_INT(g16mic_spsc_push(&q, &r), 1, "push after drain");
	CHECK_EQ_INT(g16mic_spsc_pop(&q, &r), 1, "pop after drain");
	CHECK_EQ_INT(r.seq, 99, "record intact");
	g16mic_spsc_free(&q);
}

#define ATTEMPTS 100000

struct thr {
	g16mic_spsc q;
	atomic_int done;
	uint64_t popped;
	int order_ok;
	int64_t last;
};

static void *producer(void *arg)
{
	struct thr *t = arg;
	struct rec r;

	memset(&r, 0, sizeof r);
	for (uint64_t i = 0; i < ATTEMPTS; i++) {
		r.seq = i;
		r.pad[0] = (float)(i & 0xff);
		g16mic_spsc_push(&t->q, &r);
	}
	atomic_store(&t->done, 1);
	return NULL;
}

static void *consumer(void *arg)
{
	struct thr *t = arg;
	struct rec r;
	const struct timespec nap = { 0, 1000000 };  /* 1 ms */

	for (;;) {
		if (g16mic_spsc_pop(&t->q, &r)) {
			if ((int64_t)r.seq <= t->last || r.pad[0] != (float)(r.seq & 0xff))
				t->order_ok = 0;
			t->last = (int64_t)r.seq;
			t->popped++;
			if (t->popped % 1000 == 0)
				nanosleep(&nap, NULL);
			continue;
		}
		if (atomic_load(&t->done)) {
			/* The producer is finished; drain whatever it left. */
			while (g16mic_spsc_pop(&t->q, &r)) {
				if ((int64_t)r.seq <= t->last)
					t->order_ok = 0;
				t->last = (int64_t)r.seq;
				t->popped++;
			}
			break;
		}
		sched_yield();
	}
	return NULL;
}

static void test_spsc_threads(void)
{
	static struct thr t;
	pthread_t pt, ct;

	memset(&t, 0, sizeof t);
	t.order_ok = 1;
	t.last = -1;
	atomic_init(&t.done, 0);
	CHECK_EQ_INT(g16mic_spsc_init(&t.q, sizeof(struct rec), 64), 0, "init cap 64");
	CHECK_EQ_INT(pthread_create(&ct, NULL, consumer, &t), 0, "consumer thread");
	CHECK_EQ_INT(pthread_create(&pt, NULL, producer, &t), 0, "producer thread");
	pthread_join(pt, NULL);
	pthread_join(ct, NULL);

	uint64_t dropped = g16mic_spsc_dropped(&t.q);
	CHECK(t.order_ok, "popped sequence strictly increasing");
	CHECK_EQ_INT(t.popped + dropped, ATTEMPTS, "popped + dropped == attempts");
	CHECK_EQ_INT(atomic_load(&t.q.pushed), t.popped, "every pushed record was popped");
	CHECK_EQ_INT(atomic_load(&t.q.popped), t.popped, "popped counter");
	CHECK_EQ_INT(t.q.cap, 64, "queue did not grow under overload");
	printf("spsc overload: popped %llu dropped %llu\n",
	       (unsigned long long)t.popped, (unsigned long long)dropped);
	g16mic_spsc_free(&t.q);
}

static void test_ring(void)
{
	g16mic_ring r;
	float in[32], out[32];

	CHECK(g16mic_ring_init(&r, 12) == -1, "non-power-of-two ring refused");
	CHECK_EQ_INT(g16mic_ring_init(&r, 16), 0, "init cap 16");

	for (int i = 0; i < 32; i++)
		in[i] = (float)(i + 1);
	CHECK_EQ_INT(g16mic_ring_write(&r, in, 20), 16, "write what fits");
	CHECK_EQ_INT(atomic_load(&r.overflow), 4, "overflow counts the rest");
	CHECK_EQ_INT(g16mic_ring_fill(&r), 16, "full");

	for (int i = 0; i < 32; i++)
		out[i] = -7.0f;
	CHECK_EQ_INT(g16mic_ring_read(&r, out, 20), 16, "read what is there");
	for (int i = 0; i < 16; i++)
		CHECK(out[i] == (float)(i + 1), "data at %d", i);
	for (int i = 16; i < 20; i++)
		CHECK(out[i] == 0.0f, "zero-filled at %d", i);
	CHECK(out[20] == -7.0f, "nothing written past n");
	CHECK_EQ_INT(atomic_load(&r.underflow), 4, "underflow counts the missing");
	g16mic_ring_free(&r);

	/* Integrity across wrap-around, odd chunk sizes on both sides. */
	CHECK_EQ_INT(g16mic_ring_init(&r, 8), 0, "init cap 8");
	float next_in = 0.0f, next_out = 0.0f;
	for (int iter = 0; iter < 500; iter++) {
		size_t w = (size_t)(iter % 5) + 1;
		size_t space = 8 - g16mic_ring_fill(&r);
		if (w > space)
			w = space;
		for (size_t i = 0; i < w; i++)
			in[i] = next_in++;
		CHECK_EQ_INT(g16mic_ring_write(&r, in, w), w, "write within space");
		size_t avail = g16mic_ring_fill(&r);
		size_t n = (size_t)(iter % 3) + 1;
		if (n > avail)
			n = avail;
		CHECK_EQ_INT(g16mic_ring_read(&r, out, n), n, "read within fill");
		for (size_t i = 0; i < n; i++) {
			CHECK(out[i] == next_out, "wrap data %g want %g", (double)out[i], (double)next_out);
			next_out += 1.0f;
		}
	}
	CHECK_EQ_INT(atomic_load(&r.overflow), 0, "no overflow when writes respect space");
	CHECK_EQ_INT(atomic_load(&r.underflow), 0, "no underflow when reads respect fill");
	g16mic_ring_free(&r);
}

int main(void)
{
	test_fifo();
	test_spsc_capacity();
	test_spsc_threads();
	test_ring();
	G16T_RETURN();
}
