/* SPDX-License-Identifier: MIT */
/* test_util.h: tiny header-only test helpers shared by every g16-mic C test.
 *
 * CHECK(cond, "fmt", ...)            fails (and continues) when cond is false
 * CHECK_NEAR(a, b, tol, "fmt", ...)  doubles; NaN always fails
 * CHECK_EQ_INT(a, b, "fmt", ...)     integers, both values printed
 * G16T_RETURN()                      prints "<n> failures" or "ok", returns 1/0
 *
 * The message must start with a string literal; it may be left out.
 */
#ifndef G16MIC_TEST_UTIL_H
#define G16MIC_TEST_UTIL_H

#include <math.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int g16t_failures __attribute__((unused));

__attribute__((format(printf, 4, 5)))
static inline void g16t_fail(const char *file, int line, const char *what, const char *fmt, ...)
{
	va_list ap;

	fprintf(stderr, "%s:%d: FAIL: %s:", file, line, what);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	g16t_failures++;
}

#define CHECK(cond, ...)                                                   \
	do {                                                                   \
		if (!(cond))                                                       \
			g16t_fail(__FILE__, __LINE__, #cond, " " __VA_ARGS__);         \
	} while (0)

#define CHECK_NEAR(a, b, tol, ...)                                         \
	do {                                                                   \
		double g16t_a_ = (double)(a), g16t_b_ = (double)(b);               \
		double g16t_t_ = (double)(tol);                                    \
		if (!(fabs(g16t_a_ - g16t_b_) <= g16t_t_)) {                       \
			fprintf(stderr, "%s:%d: %s = %.9g, %s = %.9g, tol %.3g\n",     \
				__FILE__, __LINE__, #a, g16t_a_, #b, g16t_b_, g16t_t_);    \
			g16t_fail(__FILE__, __LINE__, "|" #a " - " #b "| <= " #tol,    \
				" " __VA_ARGS__);                                          \
		}                                                                  \
	} while (0)

#define CHECK_EQ_INT(a, b, ...)                                            \
	do {                                                                   \
		long long g16t_a_ = (long long)(a), g16t_b_ = (long long)(b);      \
		if (g16t_a_ != g16t_b_) {                                          \
			fprintf(stderr, "%s:%d: %s = %lld, %s = %lld\n",               \
				__FILE__, __LINE__, #a, g16t_a_, #b, g16t_b_);             \
			g16t_fail(__FILE__, __LINE__, #a " == " #b, " " __VA_ARGS__);  \
		}                                                                  \
	} while (0)

#define G16T_RETURN()                                                      \
	do {                                                                   \
		if (g16t_failures) {                                               \
			printf("%d failures\n", g16t_failures);                        \
			return 1;                                                      \
		}                                                                  \
		printf("ok\n");                                                    \
		return 0;                                                          \
	} while (0)

static inline double g16t_rms(const float *x, size_t n)
{
	double acc = 0.0;

	if (!x || n == 0)
		return 0.0;
	for (size_t i = 0; i < n; i++)
		acc += (double)x[i] * (double)x[i];
	return sqrt(acc / (double)n);
}

/* Amplitude ratio to dB; 0 maps to -600 dB rather than -inf. */
static inline double g16t_db(double x)
{
	return 20.0 * log10(x > 1e-30 ? x : 1e-30);
}

/* Deterministic xorshift32; returns a float in [-1, 1). */
static inline float g16t_rand_uniform(uint32_t *state)
{
	uint32_t x = *state ? *state : 0x9e3779b9u;

	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*state = x;
	return (float)(x >> 8) * (1.0f / 8388608.0f) - 1.0f;
}

#endif /* G16MIC_TEST_UTIL_H */
