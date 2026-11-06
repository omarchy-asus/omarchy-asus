/* SPDX-License-Identifier: MIT */
/* rt.c: the real-time buffers of libg16mic.
 *
 * g16mic_fifo  single-thread float FIFO (the engine's block re-chunker)
 * g16mic_spsc  lock-free bounded queue of fixed-size records between the
 *              PipeWire process callback and a worker thread; a full queue
 *              drops the new record and counts it
 * g16mic_ring  lock-free single-producer single-consumer float ring
 *
 * Memory is allocated only in the *_init calls. Head and tail are monotonic
 * indices masked by cap - 1; the producer publishes with release, the consumer
 * observes with acquire; counters are relaxed.
 */
#include <stdlib.h>
#include <string.h>

#include "g16mic.h"

static int is_pow2(size_t v)
{
	return v >= 2 && (v & (v - 1)) == 0;
}

/* ---- g16mic_fifo -------------------------------------------------------- */

int g16mic_fifo_init(g16mic_fifo *f, size_t cap)
{
	if (!f)
		return -1;
	memset(f, 0, sizeof *f);
	if (cap == 0 || cap > SIZE_MAX / sizeof(float))
		return -1;
	f->buf = calloc(cap, sizeof(float));
	if (!f->buf)
		return -1;
	f->cap = cap;
	return 0;
}

void g16mic_fifo_free(g16mic_fifo *f)
{
	if (!f)
		return;
	free(f->buf);
	memset(f, 0, sizeof *f);
}

size_t g16mic_fifo_write(g16mic_fifo *f, const float *src, size_t n)
{
	if (!f || !f->buf || !src || n == 0)
		return 0;
	size_t space = f->cap - f->fill;
	if (n > space)
		n = space;
	if (n == 0)
		return 0;
	size_t first = f->cap - f->w;
	if (first > n)
		first = n;
	memcpy(f->buf + f->w, src, first * sizeof(float));
	if (n > first)
		memcpy(f->buf, src + first, (n - first) * sizeof(float));
	f->w = (f->w + n) % f->cap;
	f->fill += n;
	return n;
}

size_t g16mic_fifo_read(g16mic_fifo *f, float *dst, size_t n)
{
	if (!f || !f->buf || n == 0)
		return 0;
	if (n > f->fill)
		n = f->fill;
	if (n == 0)
		return 0;
	size_t first = f->cap - f->r;
	if (first > n)
		first = n;
	if (dst) {
		memcpy(dst, f->buf + f->r, first * sizeof(float));
		if (n > first)
			memcpy(dst + first, f->buf, (n - first) * sizeof(float));
	}
	f->r = (f->r + n) % f->cap;
	f->fill -= n;
	return n;
}

size_t g16mic_fifo_fill(const g16mic_fifo *f)
{
	return f ? f->fill : 0;
}

size_t g16mic_fifo_space(const g16mic_fifo *f)
{
	return f ? f->cap - f->fill : 0;
}

/* ---- g16mic_spsc -------------------------------------------------------- */

int g16mic_spsc_init(g16mic_spsc *q, size_t slot_size, size_t cap_pow2)
{
	if (!q)
		return -1;
	q->slots = NULL;
	q->slot_size = 0;
	q->cap = 0;
	atomic_init(&q->head, 0);
	atomic_init(&q->tail, 0);
	atomic_init(&q->pushed, 0);
	atomic_init(&q->dropped, 0);
	atomic_init(&q->popped, 0);
	if (slot_size == 0 || !is_pow2(cap_pow2) || cap_pow2 > SIZE_MAX / slot_size)
		return -1;
	q->slots = calloc(cap_pow2, slot_size);
	if (!q->slots)
		return -1;
	q->slot_size = slot_size;
	q->cap = cap_pow2;
	return 0;
}

void g16mic_spsc_free(g16mic_spsc *q)
{
	if (!q)
		return;
	free(q->slots);
	q->slots = NULL;
	q->cap = 0;
	q->slot_size = 0;
}

int g16mic_spsc_push(g16mic_spsc *q, const void *rec)
{
	if (!q || !q->slots || !rec)
		return 0;
	size_t h = atomic_load_explicit(&q->head, memory_order_relaxed);
	size_t t = atomic_load_explicit(&q->tail, memory_order_acquire);
	if (h - t >= q->cap) {
		atomic_fetch_add_explicit(&q->dropped, 1, memory_order_relaxed);
		return 0;
	}
	memcpy(q->slots + (h & (q->cap - 1)) * q->slot_size, rec, q->slot_size);
	atomic_store_explicit(&q->head, h + 1, memory_order_release);
	atomic_fetch_add_explicit(&q->pushed, 1, memory_order_relaxed);
	return 1;
}

int g16mic_spsc_pop(g16mic_spsc *q, void *rec)
{
	if (!q || !q->slots)
		return 0;
	size_t t = atomic_load_explicit(&q->tail, memory_order_relaxed);
	size_t h = atomic_load_explicit(&q->head, memory_order_acquire);
	if (t == h)
		return 0;
	if (rec)
		memcpy(rec, q->slots + (t & (q->cap - 1)) * q->slot_size, q->slot_size);
	atomic_store_explicit(&q->tail, t + 1, memory_order_release);
	atomic_fetch_add_explicit(&q->popped, 1, memory_order_relaxed);
	return 1;
}

uint64_t g16mic_spsc_dropped(const g16mic_spsc *q)
{
	return q ? atomic_load_explicit(&q->dropped, memory_order_relaxed) : 0;
}

/* ---- g16mic_ring -------------------------------------------------------- */

int g16mic_ring_init(g16mic_ring *r, size_t cap_pow2)
{
	if (!r)
		return -1;
	r->buf = NULL;
	r->cap = 0;
	atomic_init(&r->head, 0);
	atomic_init(&r->tail, 0);
	atomic_init(&r->overflow, 0);
	atomic_init(&r->underflow, 0);
	if (!is_pow2(cap_pow2) || cap_pow2 > SIZE_MAX / sizeof(float))
		return -1;
	r->buf = calloc(cap_pow2, sizeof(float));
	if (!r->buf)
		return -1;
	r->cap = cap_pow2;
	return 0;
}

void g16mic_ring_free(g16mic_ring *r)
{
	if (!r)
		return;
	free(r->buf);
	r->buf = NULL;
	r->cap = 0;
}

size_t g16mic_ring_write(g16mic_ring *r, const float *src, size_t n)
{
	if (!r || !r->buf || n == 0)
		return 0;
	size_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
	size_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
	size_t space = r->cap - (h - t);
	size_t w = n < space ? n : space;
	if (!src)
		w = 0;
	if (w > 0) {
		size_t idx = h & (r->cap - 1);
		size_t first = r->cap - idx;
		if (first > w)
			first = w;
		memcpy(r->buf + idx, src, first * sizeof(float));
		if (w > first)
			memcpy(r->buf, src + first, (w - first) * sizeof(float));
		atomic_store_explicit(&r->head, h + w, memory_order_release);
	}
	if (w < n)
		atomic_fetch_add_explicit(&r->overflow, (uint64_t)(n - w), memory_order_relaxed);
	return w;
}

size_t g16mic_ring_read(g16mic_ring *r, float *dst, size_t n)
{
	if (!r || !r->buf || !dst || n == 0)
		return 0;
	size_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
	size_t h = atomic_load_explicit(&r->head, memory_order_acquire);
	size_t avail = h - t;
	size_t got = n < avail ? n : avail;
	if (got > 0) {
		size_t idx = t & (r->cap - 1);
		size_t first = r->cap - idx;
		if (first > got)
			first = got;
		memcpy(dst, r->buf + idx, first * sizeof(float));
		if (got > first)
			memcpy(dst + first, r->buf, (got - first) * sizeof(float));
		atomic_store_explicit(&r->tail, t + got, memory_order_release);
	}
	if (got < n) {
		memset(dst + got, 0, (n - got) * sizeof(float));
		atomic_fetch_add_explicit(&r->underflow, (uint64_t)(n - got), memory_order_relaxed);
	}
	return got;
}

size_t g16mic_ring_fill(const g16mic_ring *r)
{
	if (!r || !r->buf)
		return 0;
	/* Tail first: head only grows, so head - tail never underflows. */
	size_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
	size_t h = atomic_load_explicit(&r->head, memory_order_acquire);
	size_t fill = h - t;
	return fill > r->cap ? r->cap : fill;
}
