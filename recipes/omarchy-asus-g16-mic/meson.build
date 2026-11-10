# SPDX-License-Identifier: MIT
# g16-mic: an opt-in microphone processor for the G16's internal array.
# libg16mic (static) holds the real-time core, calibration, source matching,
# DSP, tracking, the engine and the status file; the g16-mic daemon adds the
# PipeWire host. Nothing is installed into /etc, pipewire.conf.d or systemd
# directories: opting in is a manual step (README.md).

project('g16-mic', 'c',
  version: '0.1.0',
  license: 'MIT',
  meson_version: '>=1.0',
  default_options: ['c_std=c11', 'warning_level=2', 'buildtype=debugoptimized'],
)

add_project_arguments('-D_GNU_SOURCE', language: 'c')

cc = meson.get_compiler('c')
m = cc.find_library('m')
threads = dependency('threads')
fftw = dependency('fftw3f')
# >= 1.1: host.c runs its fallback output triggers on the stream's own data
# loop (pw_stream_get_data_loop, new in 1.1).
pw = dependency('libpipewire-0.3', version: '>=1.1')

lib = static_library('g16mic',
  ['rt.c', 'calib.c', 'match.c', 'dsp.c', 'track.c', 'engine.c', 'status.c', 'handoff.c'],
  dependencies: [fftw, m, threads],
)
libdep = declare_dependency(link_with: lib, dependencies: [fftw, m, threads])

g16mic_exe = executable('g16-mic', ['main.c', 'host.c'],
  dependencies: [libdep, pw],
  install: true,
)

# Opt-in PipeWire fragments: echo cancellation only (the default), and the
# same with noise suppression at PipeWire's high level (a word-loss risk; see
# README.md). Neither is installed into a directory PipeWire reads.
install_data('g16-mic-aec.conf', 'g16-mic-aec-ns-high.conf',
  install_dir: get_option('datadir') / 'omarchy-asus-g16-mic' / 'pipewire')
install_data('calibration.example.conf',
  install_dir: get_option('datadir') / 'omarchy-asus-g16-mic')

test_env = [
  'G16MIC_EXAMPLE_CALIB=' + (meson.current_source_dir() / 'calibration.example.conf'),
  'G16MIC_AEC_CONF=' + (meson.current_source_dir() / 'g16-mic-aec.conf'),
  'G16MIC_AEC_NS_CONF=' + (meson.current_source_dir() / 'g16-mic-aec-ns-high.conf'),
]

foreach t : ['test_rt', 'test_calib', 'test_match', 'test_beam', 'test_track', 'test_engine', 'test_status', 'test_handoff']
  exe = executable(t, t + '.c', dependencies: libdep)
  test(t, exe, timeout: 120, env: test_env)
endforeach

# The live test: g16-mic against a private PipeWire daemon and WirePlumber
# with null/dummy drivers only (test_pw_live.sh). It skips (exit 77) only
# where the pipewire or wireplumber binaries are missing, or when the host is
# already loaded by other work and G16MIC_LIVE_STRICT is unset (SKIP-LOAD),
# which tests/channel/g16-mic.sh still treats as a failure. The PKGBUILD's
# checkdepends=('wireplumber') puts both into the clean chroot, so it runs
# there, and tests/channel/g16-mic.sh fails if it skipped on a host that has
# them. The timeout is 420 s for the test's own runtime, which leaves headroom
# for the steps' setup plus the steady-state step with a source on its own
# driver (about 25 s of its own) and steps 10-13 (stop drain, source loss and
# reconnect, 15 s of contention, overload and recovery: about 70 s together
# with their fresh g16-mic runs), plus up to 10 minutes (600 s, one budget for
# the whole run, steps 9 and 12) waiting for outside load to drop below
# nproc/2 when G16MIC_LIVE_STRICT=1, so a strict run waits instead of timing
# out: 1020 s in all.
pw_helper_exe = executable('test_pw_helper', 'test_pw_helper.c',
  dependencies: [libdep, pw],
  install: false,
)
test('test_pw_live', find_program('bash'),
  args: [files('test_pw_live.sh'), g16mic_exe, pw_helper_exe],
  timeout: 1020,
  is_parallel: false,
  env: test_env,
)

# The echo-cancellation test links the WebRTC audio-processing library that
# PipeWire's module-echo-cancel uses, and checks it on synthetic signals.
aec_opt = get_option('aec_tests')
if add_languages('cpp', required: aec_opt, native: false)
  webrtc = dependency('webrtc-audio-processing-1', required: aec_opt, include_type: 'system')
  if webrtc.found()
    aec_exe = executable('test_aec', 'test_aec.cpp',
      dependencies: [webrtc, m],
      override_options: ['cpp_std=c++17'],
    )
    test('test_aec', aec_exe, timeout: 300, env: test_env)
  endif
endif
