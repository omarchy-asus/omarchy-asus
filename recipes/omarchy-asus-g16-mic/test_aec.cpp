// SPDX-License-Identifier: MIT
//
// test_aec: checks the echo cancellation the two fragments turn on, by
// running webrtc-audio-processing-1 (the library behind PipeWire's
// aec/libspa-aec-webrtc) with the same settings on synthetic signals.
//
//   g16-mic-aec.conf          the default: echo cancellation only, no noise
//                             suppression, no gain control (keeps every word)
//   g16-mic-aec-ns-high.conf  opt-in: the same plus noise suppression at
//                             PipeWire's fixed high level (word-loss risk)
//
// No files other than the confs, no audio devices, deterministic signals.
// Scenarios (48 kHz mono, 10 ms frames), a-d with the default settings:
//   a) bulk delay 60 ms, hint 60 ms: echo return loss enhancement (ERLE)
//   b) true delay 100 ms, hint 40 ms: the library must find the delay
//   c) 100 ppm clock drift between reference and echo path, 20 s: ERLE and
//      no divergence (output never louder than the mic by > 1 dB per 100 ms)
//   d) double talk: near-end speech must survive while the far end plays,
//      plus a near-end-only control. These are the assertions that matter
//      most: keeping words beats removing echo.
//   e) the opt-in noise-suppression-high settings: double talk and the
//      near-end-only control again, plus the ERLE of a. Its numbers are
//      printed next to the default's (the near-end retention difference in
//      dB) and only the absolute word floors are asserted.
// Every scenario prints its numbers; exit 1 on any failure.

#include <modules/audio_processing/include/audio_processing.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr int kRate = 48000;
constexpr size_t kFrame = 480;  // 10 ms
constexpr double kPi = 3.14159265358979323846;

int g_failures = 0;

void check(bool ok, const char *what, double value, const char *cmp, double limit)
{
    std::printf("  %-4s %-52s %9.2f (%s %.2f)\n", ok ? "PASS" : "FAIL", what, value, cmp, limit);
    if (!ok)
        g_failures++;
}

// ---- settings shared by the fragments and the library run -----------------
//
// These mirror aec.args in g16-mic-aec.conf (default) and
// g16-mic-aec-ns-high.conf (opt-in). PipeWire 1.6 (aec-webrtc.cpp,
// webrtc-audio-processing 1.x path) maps them as:
//   webrtc.gain_control          -> gain_controller1/2.enabled
//   webrtc.noise_suppression     -> noise_suppression.enabled, level kHigh
//   webrtc.high_pass_filter      -> high_pass_filter.enabled
//   webrtc.voice_detection       -> voice_detection.enabled
//   webrtc.transient_suppression -> transient_suppression.enabled
//   webrtc.mobile_mode           -> echo_canceller.mobile_mode
// and always sets echo_canceller.enabled = true. The two fragments differ
// only in webrtc.noise_suppression: false in the default, true in the
// opt-in. When it is on, PipeWire fixes the level to kHigh in its source
// (no key lowers it), so the test uses kHigh too: the test must run what
// PipeWire runs.
struct ConfKey {
    const char *key;
    bool value;
};
// Default, g16-mic-aec.conf: echo cancellation only.
const ConfKey kExpectedDefault[] = {
    {"webrtc.gain_control", false},
    {"webrtc.noise_suppression", false},
    {"webrtc.high_pass_filter", false},
    {"webrtc.voice_detection", false},
    {"webrtc.transient_suppression", false},
    {"webrtc.mobile_mode", false},
};
// Opt-in, g16-mic-aec-ns-high.conf: plus noise suppression (high).
const ConfKey kExpectedNsHigh[] = {
    {"webrtc.gain_control", false},
    {"webrtc.noise_suppression", true},
    {"webrtc.high_pass_filter", false},
    {"webrtc.voice_detection", false},
    {"webrtc.transient_suppression", false},
    {"webrtc.mobile_mode", false},
};
constexpr size_t kNumKeys = sizeof(kExpectedDefault) / sizeof(kExpectedDefault[0]);
static_assert(kNumKeys == sizeof(kExpectedNsHigh) / sizeof(kExpectedNsHigh[0]), "tables differ in size");

webrtc::AudioProcessing::Config apm_config(bool ns_high)
{
    webrtc::AudioProcessing::Config c;
    c.echo_canceller.enabled = true;
    c.echo_canceller.mobile_mode = false;
    c.noise_suppression.enabled = ns_high;
    c.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;
    c.gain_controller1.enabled = false;
    c.gain_controller2.enabled = false;
    c.high_pass_filter.enabled = false;
    c.voice_detection.enabled = false;
    c.transient_suppression.enabled = false;
    return c;
}

// ---- conf check -----------------------------------------------------------

std::string strip_comments(const std::string &s)
{
    std::string out;
    bool in_quote = false, in_comment = false;
    for (char ch : s) {
        if (in_comment) {
            if (ch == '\n') {
                in_comment = false;
                out += ch;
            }
            continue;
        }
        if (ch == '"')
            in_quote = !in_quote;
        if (ch == '#' && !in_quote) {
            in_comment = true;
            continue;
        }
        out += ch;
    }
    return out;
}

bool is_key_char(char ch)
{
    return std::isalnum(static_cast<unsigned char>(ch)) || ch == '.' || ch == '_' || ch == '-';
}

// Reads the value after "key =" (or "key :") starting at pos.
std::string read_value(const std::string &s, size_t pos)
{
    while (pos < s.size() && std::isspace(static_cast<unsigned char>(s[pos])))
        pos++;
    if (pos >= s.size() || (s[pos] != '=' && s[pos] != ':'))
        return "";
    pos++;
    while (pos < s.size() && std::isspace(static_cast<unsigned char>(s[pos])))
        pos++;
    if (pos < s.size() && s[pos] == '"') {
        size_t close = s.find('"', pos + 1);
        if (close == std::string::npos)
            return "";
        return s.substr(pos + 1, close - pos - 1);
    }
    size_t start = pos;
    while (pos < s.size() && (is_key_char(s[pos]) || s[pos] == '/'))
        pos++;
    return s.substr(start, pos - start);
}

// Returns the value of a top-level-style key (first occurrence as a token).
std::string find_key(const std::string &s, const std::string &key)
{
    size_t pos = 0;
    while ((pos = s.find(key, pos)) != std::string::npos) {
        bool start_ok = pos == 0 || !is_key_char(s[pos - 1]);
        size_t end = pos + key.size();
        bool end_ok = end >= s.size() || !is_key_char(s[end]);
        if (start_ok && end_ok)
            return read_value(s, end);
        pos = end;
    }
    return "";
}

// Every node.name value in the file, in order (find_key only returns the
// first one).
std::vector<std::string> all_node_names(const std::string &s)
{
    std::vector<std::string> names;
    const std::string key = "node.name";
    size_t pos = 0;
    while ((pos = s.find(key, pos)) != std::string::npos) {
        bool start_ok = pos == 0 || !is_key_char(s[pos - 1]);
        size_t end = pos + key.size();
        bool end_ok = end >= s.size() || !is_key_char(s[end]);
        if (start_ok && end_ok) {
            std::string v = read_value(s, end);
            if (!v.empty())
                names.push_back(v);
        }
        pos = end;
    }
    return names;
}

// Checks one fragment against its expected table. Returns its node.name
// values (empty when skipped or unreadable).
std::vector<std::string> check_conf(const char *path_env, const ConfKey *expected, const char *source_name,
                                    const char *label)
{
    std::printf("conf: %s matches the settings under test\n", label);
    const char *path = std::getenv(path_env);
    if (!path || !*path) {
        std::printf("  SKIP %s not set (meson test sets it)\n", path_env);
        return {};
    }
    std::ifstream f(path);
    if (!f) {
        check(false, "conf file readable", 0, "==", 1);
        return {};
    }
    std::stringstream ss;
    ss << f.rdbuf();
    std::string s = strip_comments(ss.str());

    // Bracket and quote balance: the minimum for valid SPA-JSON.
    int brace = 0, bracket = 0, quotes = 0;
    bool bad_nesting = false;
    for (char ch : s) {
        if (ch == '"')
            quotes++;
        if (quotes % 2)
            continue;
        if (ch == '{')
            brace++;
        if (ch == '}')
            brace--;
        if (ch == '[')
            bracket++;
        if (ch == ']')
            bracket--;
        if (brace < 0 || bracket < 0)
            bad_nesting = true;
    }
    check(!bad_nesting && brace == 0 && bracket == 0 && quotes % 2 == 0,
          "braces, brackets and quotes balanced", brace + bracket + quotes % 2, "==", 0);

    check(find_key(s, "name") == "libpipewire-module-echo-cancel",
          "loads libpipewire-module-echo-cancel", 0, "==", 0);
    check(find_key(s, "library.name") == "aec/libspa-aec-webrtc",
          "library.name = aec/libspa-aec-webrtc", 0, "==", 0);
    check(find_key(s, "monitor.mode") == "true", "monitor.mode = true", 0, "==", 0);
    check(find_key(s, "target.object") == "g16_mic_processed",
          "capture target.object = g16_mic_processed", 0, "==", 0);

    // The new source's node.name, read inside source.props.
    std::string src_name;
    size_t sp = s.find("source.props");
    if (sp != std::string::npos)
        src_name = find_key(s.substr(sp), "node.name");
    if (src_name != source_name)
        std::printf("  source node.name is '%s'\n", src_name.c_str());
    std::string src_what = std::string("source node.name = ") + source_name;
    check(src_name == source_name, src_what.c_str(), 0, "==", 0);

    // Every webrtc.* key must be one PipeWire 1.6 parses for library 1.x,
    // and each must carry the value this test runs.
    std::set<std::string> allowed;
    for (size_t i = 0; i < kNumKeys; i++)
        allowed.insert(expected[i].key);
    int unknown = 0;
    size_t pos = 0;
    while ((pos = s.find("webrtc.", pos)) != std::string::npos) {
        if (pos > 0 && is_key_char(s[pos - 1])) {
            pos += 7;
            continue;
        }
        size_t end = pos;
        while (end < s.size() && is_key_char(s[end]))
            end++;
        std::string key = s.substr(pos, end - pos);
        if (!allowed.count(key)) {
            std::printf("  key not parsed by PipeWire 1.6 (webrtc 1.x): %s\n", key.c_str());
            unknown++;
        }
        pos = end;
    }
    check(unknown == 0, "no webrtc.* keys PipeWire 1.6 ignores", unknown, "==", 0);
    for (size_t i = 0; i < kNumKeys; i++) {
        const ConfKey &k = expected[i];
        std::string v = find_key(s, k.key);
        bool ok = v == (k.value ? "true" : "false");
        std::string what = std::string(k.key) + " = " + (k.value ? "true" : "false");
        if (!ok)
            std::printf("  %s is '%s'\n", k.key, v.c_str());
        check(ok, what.c_str(), 0, "==", 0);
    }
    return all_node_names(s);
}

// Both fragments can be linked at once only if no node.name is shared.
void check_disjoint(const std::vector<std::string> &a, const std::vector<std::string> &b)
{
    std::printf("conf: the two fragments share no node.name\n");
    if (a.empty() || b.empty()) {
        std::printf("  SKIP one of the fragments was not checked\n");
        return;
    }
    std::set<std::string> sa(a.begin(), a.end());
    int shared = 0;
    for (const std::string &n : b)
        if (sa.count(n)) {
            std::printf("  node.name in both: %s\n", n.c_str());
            shared++;
        }
    check(shared == 0, "node.name values disjoint", shared, "==", 0);
}

// ---- deterministic signals ------------------------------------------------

struct XorShift {
    uint32_t s;
    explicit XorShift(uint32_t seed) : s(seed ? seed : 0x9e3779b9u) {}
    uint32_t next()
    {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        return s;
    }
    double uniform() { return (next() >> 8) * (1.0 / 16777216.0); }  // [0, 1)
    double symmetric() { return 2.0 * uniform() - 1.0; }               // [-1, 1)
};

double db_to_amp(double db) { return std::pow(10.0, db / 20.0); }

// Voiced speech-like signal: a harmonic series on a drifting f0, harmonics
// tapered off above 6 kHz, a 4 Hz syllable envelope (250 ms slots, a quarter
// of them silent, so there are pauses) and a little breath noise. Scaled so
// the voiced parts have RMS `dbfs`.
std::vector<float> make_speech(size_t n, double f0_lo, double f0_hi, uint32_t seed, double dbfs)
{
    XorShift rng(seed);
    const size_t slot = kRate / 4;
    std::vector<double> x(n), env(n);
    double phase = 0.0;
    double f0_prev = f0_lo + (f0_hi - f0_lo) * rng.uniform();
    double f0_target = f0_prev;
    double amp = 0.0;
    bool voiced = false;
    for (size_t i = 0; i < n; i++) {
        size_t k_in_slot = i % slot;
        if (k_in_slot == 0) {
            f0_prev = f0_target;
            f0_target = f0_lo + (f0_hi - f0_lo) * rng.uniform();
            voiced = rng.uniform() < 0.75;
            amp = 0.5 + 0.5 * rng.uniform();
        }
        double u = static_cast<double>(k_in_slot) / slot;
        double f0 = f0_prev + (f0_target - f0_prev) * u;
        double e = voiced ? amp * std::sin(kPi * u) * std::sin(kPi * u) : 0.0;
        phase += 2.0 * kPi * f0 / kRate;
        if (phase > 2.0 * kPi)
            phase -= 2.0 * kPi;
        // sin(k*phase) by the Chebyshev recurrence.
        double c2 = 2.0 * std::cos(phase);
        double s_km2 = 0.0, s_km1 = std::sin(phase);
        double sum = 0.0;
        for (int k = 1; k * f0 < 6300.0; k++) {
            double s_k = (k == 1) ? s_km1 : c2 * s_km1 - s_km2;
            if (k > 1) {
                s_km2 = s_km1;
                s_km1 = s_k;
            }
            double taper = std::min(1.0, std::max(0.0, (6300.0 - k * f0) / 300.0));
            sum += taper * s_k / k;
        }
        x[i] = e * (sum + 0.03 * rng.symmetric());
        env[i] = e;
    }
    double acc = 0.0;
    size_t cnt = 0;
    for (size_t i = 0; i < n; i++)
        if (env[i] > 0.1) {
            acc += x[i] * x[i];
            cnt++;
        }
    double rms = cnt ? std::sqrt(acc / cnt) : 1.0;
    double g = db_to_amp(dbfs) / rms;
    std::vector<float> out(n);
    for (size_t i = 0; i < n; i++)
        out[i] = static_cast<float>(std::max(-1.0, std::min(1.0, x[i] * g)));
    return out;
}

// Room response: 40 ms of exponentially decaying noise (60 dB down at the
// end), scaled so its energy is -6 dB: the echo returns 6 dB below the
// far-end level.
std::vector<float> make_room(uint32_t seed)
{
    XorShift rng(seed);
    const size_t len = kRate * 40 / 1000;
    const double tau = len / std::log(1000.0);
    std::vector<double> h(len);
    double e = 0.0;
    for (size_t k = 0; k < len; k++) {
        h[k] = rng.symmetric() * std::exp(-static_cast<double>(k) / tau);
        e += h[k] * h[k];
    }
    double g = std::sqrt(std::pow(10.0, -6.0 / 10.0) / e);
    std::vector<float> out(len);
    for (size_t k = 0; k < len; k++)
        out[k] = static_cast<float>(h[k] * g);
    return out;
}

// Catmull-Rom cubic interpolation of x at fractional index t.
double cubic_at(const std::vector<float> &x, double t)
{
    long i = static_cast<long>(std::floor(t));
    double f = t - i;
    auto at = [&](long j) -> double {
        if (j < 0 || j >= static_cast<long>(x.size()))
            return 0.0;
        return x[j];
    };
    double p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
    return p1 + 0.5 * f * (p2 - p0 + f * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + f * (3.0 * (p1 - p2) + p3 - p0)));
}

// echo[n] = sum_k h[k] * src[n - delay - k], n in [0, n_out).
std::vector<float> echo_path(const std::vector<float> &src, const std::vector<float> &h, size_t delay, size_t n_out)
{
    std::vector<double> acc(n_out, 0.0);
    for (size_t k = 0; k < h.size(); k++) {
        const double hk = h[k];
        const size_t shift = delay + k;
        const size_t end = std::min(n_out, src.size() + shift);
        const float *s = src.data();
        for (size_t n = shift; n < end; n++)
            acc[n] += hk * s[n - shift];
    }
    std::vector<float> out(n_out);
    for (size_t n = 0; n < n_out; n++)
        out[n] = static_cast<float>(acc[n]);
    return out;
}

// White noise floor at -70 dBFS RMS, as a real mic has.
void add_floor(std::vector<float> &mic, uint32_t seed)
{
    XorShift rng(seed);
    const double a = db_to_amp(-70.0) * std::sqrt(3.0);
    for (float &v : mic)
        v += static_cast<float>(a * rng.symmetric());
}

// ---- the library ----------------------------------------------------------

std::unique_ptr<webrtc::AudioProcessing> make_apm(bool ns_high)
{
    std::unique_ptr<webrtc::AudioProcessing> apm(webrtc::AudioProcessingBuilder().Create());
    if (!apm)
        return nullptr;
    apm->ApplyConfig(apm_config(ns_high));
    webrtc::ProcessingConfig pc;
    pc.input_stream() = webrtc::StreamConfig(kRate, 1, false);
    pc.output_stream() = webrtc::StreamConfig(kRate, 1, false);
    pc.reverse_input_stream() = webrtc::StreamConfig(kRate, 1, false);
    pc.reverse_output_stream() = webrtc::StreamConfig(kRate, 1, false);
    if (apm->Initialize(pc) != webrtc::AudioProcessing::kNoError)
        return nullptr;
    return apm;
}

bool api_ok(int rc)
{
    return rc == webrtc::AudioProcessing::kNoError || rc == webrtc::AudioProcessing::kBadStreamParameterWarning;
}

// Feeds far (reverse) and mic (capture) frame by frame; returns the output.
// Returns an empty vector on a library error.
std::vector<float> run(webrtc::AudioProcessing &apm, const std::vector<float> &far, const std::vector<float> &mic,
                       int delay_hint_ms)
{
    const webrtc::StreamConfig sc(kRate, 1, false);
    const size_t frames = mic.size() / kFrame;
    std::vector<float> out(frames * kFrame);
    float rev_in[kFrame], rev_out[kFrame], cap_in[kFrame], cap_out[kFrame];
    for (size_t fi = 0; fi < frames; fi++) {
        const size_t off = fi * kFrame;
        for (size_t i = 0; i < kFrame; i++) {
            rev_in[i] = off + i < far.size() ? far[off + i] : 0.0f;
            cap_in[i] = mic[off + i];
        }
        const float *rsrc[1] = {rev_in};
        float *rdst[1] = {rev_out};
        if (!api_ok(apm.ProcessReverseStream(rsrc, sc, sc, rdst))) {
            std::printf("  ProcessReverseStream failed at frame %zu\n", fi);
            return {};
        }
        if (!api_ok(apm.set_stream_delay_ms(delay_hint_ms))) {
            std::printf("  set_stream_delay_ms failed at frame %zu\n", fi);
            return {};
        }
        const float *csrc[1] = {cap_in};
        float *cdst[1] = {cap_out};
        if (!api_ok(apm.ProcessStream(csrc, sc, sc, cdst))) {
            std::printf("  ProcessStream failed at frame %zu\n", fi);
            return {};
        }
        std::copy(cap_out, cap_out + kFrame, out.begin() + off);
    }
    return out;
}

double energy(const std::vector<float> &x, size_t a, size_t b)
{
    double e = 0.0;
    for (size_t i = a; i < b && i < x.size(); i++)
        e += static_cast<double>(x[i]) * x[i];
    return e;
}

double erle_db(const std::vector<float> &mic, const std::vector<float> &out, size_t a, size_t b)
{
    return 10.0 * std::log10((energy(mic, a, b) + 1e-12) / (energy(out, a, b) + 1e-12));
}

// Largest (output - mic) energy in dB over 100 ms windows.
double worst_gain_db(const std::vector<float> &mic, const std::vector<float> &out)
{
    const size_t w = kRate / 10;
    double worst = -1e9;
    for (size_t a = 0; a + w <= out.size(); a += w) {
        double g = 10.0 * std::log10((energy(out, a, a + w) + 1e-12) / (energy(mic, a, a + w) + 1e-12));
        worst = std::max(worst, g);
    }
    return worst;
}

// Mean level of x over [a, b) in dBFS (RMS).
double level_dbfs(const std::vector<float> &x, size_t a, size_t b)
{
    return 10.0 * std::log10(energy(x, a, b) / static_cast<double>(std::max<size_t>(b - a, 1)) + 1e-20);
}

// 100 ms stretches where the mic carries more than the -70 dBFS noise floor (echo or
// speech) are "active"; the rest are near-silent.
const double kActiveDbfs = -50.0;

// Over 100 ms windows: the largest output-over-mic gain where the mic is
// active, and the loudest output (dBFS) where it is near-silent. Without
// noise suppression the echo canceller's output in a near-silent window can
// sit above the -70 dBFS floor it was fed (its residual and comfort noise,
// about -60 dBFS here), which a ratio alone would call amplification; the
// absolute level says whether that is audible.
void worst_windows(const std::vector<float> &mic, const std::vector<float> &out, double *active_gain_db,
                   double *quiet_out_dbfs)
{
    const size_t w = kRate / 10;
    *active_gain_db = -1e9;
    *quiet_out_dbfs = -1e9;
    for (size_t a = 0; a + w <= out.size(); a += w) {
        if (level_dbfs(mic, a, a + w) >= kActiveDbfs) {
            double g = 10.0 * std::log10((energy(out, a, a + w) + 1e-12) / (energy(mic, a, a + w) + 1e-12));
            *active_gain_db = std::max(*active_gain_db, g);
        } else {
            *quiet_out_dbfs = std::max(*quiet_out_dbfs, level_dbfs(out, a, a + w));
        }
    }
}

struct Retention {
    double gain_db;  // least-squares gain of the clean near end in the output
    double corr;     // normalized correlation output vs clean near end
    long lag;        // samples, output relative to the clean near end
};

// Projects out[a+lag, b+lag) onto clean[a, b), searching lag within +-20 ms.
Retention retention(const std::vector<float> &clean, const std::vector<float> &out, size_t a, size_t b)
{
    const long max_lag = kRate / 50;
    Retention best{-200.0, 0.0, 0};
    double best_c = -1e300;
    const double es = energy(clean, a, b);
    for (long lag = -max_lag; lag <= max_lag; lag++) {
        double c = 0.0;
        for (size_t n = a; n < b; n++) {
            long m = static_cast<long>(n) + lag;
            if (m < 0 || m >= static_cast<long>(out.size()))
                continue;
            c += static_cast<double>(out[m]) * clean[n];
        }
        if (c > best_c) {
            best_c = c;
            best.lag = lag;
        }
    }
    double ey = 0.0;
    for (size_t n = a; n < b; n++) {
        long m = static_cast<long>(n) + best.lag;
        if (m >= 0 && m < static_cast<long>(out.size()))
            ey += static_cast<double>(out[m]) * out[m];
    }
    double g = es > 0.0 ? best_c / es : 0.0;
    best.gain_db = 20.0 * std::log10(std::max(g, 1e-10));
    best.corr = (es > 0.0 && ey > 0.0) ? best_c / std::sqrt(es * ey) : 0.0;
    return best;
}

size_t sec(double s) { return static_cast<size_t>(s * kRate); }

// ---- scenarios ------------------------------------------------------------

const uint32_t kFarSeed = 0x1234abcdu;
const uint32_t kNearSeed = 0x0badf00du;
const uint32_t kRoomSeed = 0x5eed0001u;
const double kFarLo = 120.0, kFarHi = 160.0;   // far-end talker
const double kNearLo = 170.0, kNearHi = 220.0; // near-end talker
const double kFarDbfs = -16.0;

// Returns the ERLE; asserts it only for the default (AEC-only) settings,
// the opt-in variant reports it.
double scenario_delay(bool ns_high)
{
    std::printf("a) bulk delay 60 ms, hint 60 ms, 10 s far end only%s\n",
                ns_high ? " (noise suppression high)" : "");
    const size_t n = sec(10);
    auto far = make_speech(n, kFarLo, kFarHi, kFarSeed, kFarDbfs);
    auto room = make_room(kRoomSeed);
    auto mic = echo_path(far, room, sec(0.060), n);
    add_floor(mic, 11);
    auto apm = make_apm(ns_high);
    if (!apm) {
        check(false, "library created", 0, "==", 1);
        return 0.0;
    }
    auto out = run(*apm, far, mic, 60);
    if (out.empty()) {
        check(false, "library processed every frame", 0, "==", 1);
        return 0.0;
    }
    double erle = erle_db(mic, out, sec(6), sec(10));
    if (ns_high)
        std::printf("       ERLE, last 4 s: %.2f dB (reported)\n", erle);
    else
        check(erle >= 15.0, "ERLE, last 4 s (dB)", erle, ">=", 15.0);
    std::printf("       worst 100 ms output-over-mic: %.2f dB\n", worst_gain_db(mic, out));
    return erle;
}

void scenario_delay_mismatch()
{
    std::printf("b) true delay 100 ms, hint 40 ms, 10 s far end only\n");
    const size_t n = sec(10);
    auto far = make_speech(n, kFarLo, kFarHi, kFarSeed, kFarDbfs);
    auto room = make_room(kRoomSeed);
    auto mic = echo_path(far, room, sec(0.100), n);
    add_floor(mic, 12);
    auto apm = make_apm(false);
    if (!apm) {
        check(false, "library created", 0, "==", 1);
        return;
    }
    auto out = run(*apm, far, mic, 40);
    if (out.empty()) {
        check(false, "library processed every frame", 0, "==", 1);
        return;
    }
    double erle = erle_db(mic, out, sec(6), sec(10));
    check(erle >= 10.0, "ERLE, last 4 s (dB)", erle, ">=", 10.0);
    std::printf("       worst 100 ms output-over-mic: %.2f dB\n", worst_gain_db(mic, out));
}

void scenario_drift()
{
    std::printf("c) 100 ppm drift on the echo path, delay 60 ms, 20 s\n");
    const size_t n = sec(20);
    // The reference the library sees is `far`; the echo is the same far
    // end played on a clock 100 ppm fast, so the echo slides 2 ms by the end.
    auto far = make_speech(n + kRate, kFarLo, kFarHi, kFarSeed, kFarDbfs);
    std::vector<float> drifted(n);
    const double ratio = 1.0 + 100e-6;
    for (size_t i = 0; i < n; i++)
        drifted[i] = static_cast<float>(cubic_at(far, i * ratio));
    auto room = make_room(kRoomSeed);
    auto mic = echo_path(drifted, room, sec(0.060), n);
    add_floor(mic, 13);
    far.resize(n);
    auto apm = make_apm(false);
    if (!apm) {
        check(false, "library created", 0, "==", 1);
        return;
    }
    auto out = run(*apm, far, mic, 60);
    if (out.empty()) {
        check(false, "library processed every frame", 0, "==", 1);
        return;
    }
    double erle = erle_db(mic, out, sec(15), sec(20));
    check(erle >= 8.0, "ERLE, last 5 s (dB)", erle, ">=", 8.0);
    // The canceller must never amplify where there is signal, and what it
    // leaves in near-silent windows must stay quiet (-55 dBFS is 35 dB
    // under the -20 dBFS near-end speech these tests use).
    double active_gain, quiet_out;
    worst_windows(mic, out, &active_gain, &quiet_out);
    check(active_gain <= 1.0, "worst 100 ms output over mic, mic active (dB)", active_gain, "<=", 1.0);
    check(quiet_out <= -55.0, "loudest 100 ms output, mic near-silent (dBFS)", quiet_out, "<=", -55.0);
}

// Absolute word floors: no settings, default or opt-in, may go below these,
// and no library update may loosen any threshold below them.
const double kWordFloorDb = -10.0;
const double kWordFloorCorr = 0.5;

struct NearEnd {
    bool ok = false;     // both runs completed
    Retention talk{};    // during double talk
    Retention alone{};   // near end only, no far end
};

// Runs double talk and the near-end-only control with the given settings.
// The default (AEC-only) asserts its thresholds; the opt-in noise
// suppression variant asserts only the absolute word floors and reports.
NearEnd scenario_double_talk(bool ns_high)
{
    const char *sfx = ns_high ? " (noise suppression high)" : "";
    const char tag = ns_high ? 'e' : 'd';
    NearEnd res;
    std::printf("%c) double talk: 6 s far end only, then near end at -20 dBFS for 6 s%s\n", tag, sfx);
    const size_t n = sec(12);
    const size_t dt_a = sec(6), dt_b = sec(12);
    auto far = make_speech(n, kFarLo, kFarHi, kFarSeed, kFarDbfs);
    auto room = make_room(kRoomSeed);
    auto mic = echo_path(far, room, sec(0.060), n);
    add_floor(mic, 14);
    auto talk = make_speech(dt_b - dt_a, kNearLo, kNearHi, kNearSeed, -20.0);
    std::vector<float> clean(n, 0.0f);
    std::copy(talk.begin(), talk.end(), clean.begin() + dt_a);
    for (size_t i = 0; i < n; i++)
        mic[i] += clean[i];
    auto apm = make_apm(ns_high);
    if (!apm) {
        check(false, "library created", 0, "==", 1);
        return res;
    }
    auto out = run(*apm, far, mic, 60);
    if (out.empty()) {
        check(false, "library processed every frame", 0, "==", 1);
        return res;
    }
    double erle = erle_db(mic, out, sec(4), sec(6));
    std::printf("       ERLE before the near end starts (4-6 s): %.2f dB\n", erle);
    Retention r = retention(clean, out, dt_a, dt_b);
    std::printf("       retention %.2f dB, correlation %.3f, alignment lag %ld samples\n", r.gain_db, r.corr,
                r.lag);
    // Word retention is the point: these must hold. Never loosen below
    // -10 dB / 0.5 even if a library update needs a threshold change.
    if (ns_high) {
        check(r.gain_db >= kWordFloorDb, "near end retained during double talk (dB)", r.gain_db, ">=",
              kWordFloorDb);
        check(r.corr >= kWordFloorCorr, "near end correlation during double talk", r.corr, ">=", kWordFloorCorr);
    } else {
        check(r.gain_db >= -6.0, "near end retained during double talk (dB)", r.gain_db, ">=", -6.0);
        check(r.corr >= 0.7, "near end correlation during double talk", r.corr, ">=", 0.7);
    }

    std::printf("%c) control: near end only, no far end, 6 s%s\n", tag, sfx);
    const size_t n2 = sec(6);
    std::vector<float> silent(n2, 0.0f);
    auto near_only = make_speech(n2, kNearLo, kNearHi, kNearSeed, -20.0);
    std::vector<float> mic2 = near_only;
    add_floor(mic2, 15);
    auto apm2 = make_apm(ns_high);
    if (!apm2) {
        check(false, "library created", 0, "==", 1);
        return res;
    }
    auto out2 = run(*apm2, silent, mic2, 60);
    if (out2.empty()) {
        check(false, "library processed every frame", 0, "==", 1);
        return res;
    }
    Retention r2 = retention(near_only, out2, 0, n2);
    std::printf("       retention %.2f dB, correlation %.3f, alignment lag %ld samples\n", r2.gain_db, r2.corr,
                r2.lag);
    if (ns_high) {
        check(r2.gain_db >= kWordFloorDb, "near end retained with no far end (dB)", r2.gain_db, ">=",
              kWordFloorDb);
        check(r2.corr >= kWordFloorCorr, "near end correlation with no far end", r2.corr, ">=", kWordFloorCorr);
    } else {
        // With echo cancellation only and no far end, the near end keeps
        // its energy. The waveform correlation measured here is about 0.87,
        // not 1: the library's echo-canceller path (its band split and
        // suppressor stages) changes the waveform even with no echo, as
        // the same run with the canceller disabled shows (correlation
        // 1.000, 0.00 dB). 0.8 holds that with a margin while still
        // failing on a canceller that eats speech.
        check(r2.gain_db >= -3.0, "near end retained with no far end (dB)", r2.gain_db, ">=", -3.0);
        check(r2.corr >= 0.8, "near end correlation with no far end", r2.corr, ">=", 0.8);
    }
    res.ok = true;
    res.talk = r;
    res.alone = r2;
    return res;
}

// e) the opt-in g16-mic-aec-ns-high.conf settings, reported next to the
// default's so the cost in near-end speech is a number.
void scenario_ns_high(const NearEnd &def, double def_erle)
{
    std::printf("e) opt-in noise suppression high (g16-mic-aec-ns-high.conf)\n");
    double erle = scenario_delay(true);
    NearEnd ns = scenario_double_talk(true);
    if (!def.ok || !ns.ok) {
        std::printf("  e) comparison not available (a run failed above)\n");
        return;
    }
    std::printf("e) summary, ns-high minus default (negative = ns-high keeps less):\n");
    std::printf("       ERLE scenario a: default %.2f dB, ns-high %.2f dB, difference %+.2f dB\n", def_erle, erle,
                erle - def_erle);
    std::printf("       near end during double talk: default %.2f dB / corr %.3f, ns-high %.2f dB / corr %.3f,"
                " difference %+.2f dB\n",
                def.talk.gain_db, def.talk.corr, ns.talk.gain_db, ns.talk.corr, ns.talk.gain_db - def.talk.gain_db);
    std::printf("       near end with no far end:    default %.2f dB / corr %.3f, ns-high %.2f dB / corr %.3f,"
                " difference %+.2f dB\n",
                def.alone.gain_db, def.alone.corr, ns.alone.gain_db, ns.alone.corr,
                ns.alone.gain_db - def.alone.gain_db);
}

}  // namespace

int main()
{
    auto t0 = std::chrono::steady_clock::now();
    auto names_default = check_conf("G16MIC_AEC_CONF", kExpectedDefault, "g16_mic_clean", "g16-mic-aec.conf");
    auto names_ns = check_conf("G16MIC_AEC_NS_CONF", kExpectedNsHigh, "g16_mic_clean_ns", "g16-mic-aec-ns-high.conf");
    check_disjoint(names_default, names_ns);
    double def_erle = scenario_delay(false);
    scenario_delay_mismatch();
    scenario_drift();
    NearEnd def = scenario_double_talk(false);
    scenario_ns_high(def, def_erle);
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("test_aec: %d failure(s), %.1f s\n", g_failures, secs);
    return g_failures ? 1 : 0;
}
