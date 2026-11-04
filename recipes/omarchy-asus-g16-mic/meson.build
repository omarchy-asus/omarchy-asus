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
pw = dependency('libpipewire-0.3', version: '>=1.0')

lib = static_library('g16mic',
  ['rt.c', 'calib.c', 'match.c', 'dsp.c', 'track.c', 'engine.c', 'status.c'],
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

foreach t : ['test_rt', 'test_calib', 'test_match', 'test_beam', 'test_track', 'test_engine', 'test_status']
  exe = executable(t, t + '.c', dependencies: libdep)
  test(t, exe, timeout: 120, env: test_env)
endforeach

# The live test: g16-mic against a private PipeWire daemon and WirePlumber
# with null/dummy drivers only (test_pw_live.sh). It skips (exit 77) only
# where the pipewire or wireplumber binaries are missing; the PKGBUILD's
# checkdepends puts both into the clean chroot, so it runs there.
pw_helper_exe = executable('test_pw_helper', 'test_pw_helper.c',
  dependencies: [libdep, pw],
  install: false,
)
test('test_pw_live', find_program('bash'),
  args: [files('test_pw_live.sh'), g16mic_exe, pw_helper_exe],
  timeout: 180,
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
