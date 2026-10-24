"""g16-testd offline (#277): the daemon runs as this user against a fake root (--fake),
so nothing is written outside a temporary directory and every command it would run
(modprobe, rmmod, insmod, iw, limine-update) is only logged.

Covers: the allowlists refuse anything outside them (an unknown knob, a value out of
range, a module with an unlisted sha256, a drop-in, event or kprobe not on the list,
a service instead of an app scope); every recorded value goes back on stop, at
expiry, on SIGTERM (drop-ins kept for the reboot) and at the next start after a
crash; with no session open every call fails; another uid is refused.
"""
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "g16-testd")
UID = os.getuid()
SHA_A = hashlib.sha256(b"module A").hexdigest()


def put(root, rel, value):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(value + "\n")
    return p


def get(root, rel):
    with open(os.path.join(root, rel)) as f:
        return f.read().strip()


class Session(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="g16td")
        self.root = r = self.tmp.name
        self.sock = os.path.join(r, "s")
        self.env = dict(os.environ, G16_TESTD_SOCKET=self.sock)
        put(r, "proc/sys/kernel/random/boot_id", "boot-1")
        put(r, "proc/sys/kernel/nmi_watchdog", "1")
        put(r, "sys/module/nvme_core/parameters/apst_primary_timeout_ms", "100")
        put(r, "sys/module/nvme_core/parameters/apst_secondary_timeout_ms", "2000")
        put(r, "sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us", "100000")
        put(r, "sys/firmware/acpi/platform_profile", "balanced")
        put(r, "sys/firmware/acpi/platform_profile_choices", "quiet balanced performance")
        put(r, "sys/class/drm/card1-eDP-1/amdgpu/panel_power_savings", "0")
        put(r, "sys/class/rfkill/rfkill0/type", "bluetooth")
        put(r, "sys/class/rfkill/rfkill0/soft", "0")
        put(r, "sys/class/leds/input3::numlock/brightness", "1")
        put(r, "sys/kernel/tracing/instances/.keep", "")
        put(r, "sys/kernel/tracing/kprobe_events", "")
        put(r, "sys/kernel/debug/ec/ec0/io", "")
        with open(os.path.join(r, "sys/kernel/debug/ec/ec0/io"), "wb") as f:
            f.write(bytes(range(256)))
        put(r, "etc/default/limine", 'ESP_PATH="/boot"')
        put(r, "boot/limine.conf", "/+Omarchy\n  cmdline: quiet splash rcu_nocbs=all\n")
        self.cg = os.path.join(r, f"sys/fs/cgroup/user.slice/user-{UID}.slice/user@{UID}.service/app.slice")
        put(r, f"{self.cg}/app-graphical.slice/app-Hyprland-firefox-123.scope/cgroup.freeze", "0")
        put(r, f"{self.cg}/../session.slice/voxtype.service/cgroup.freeze", "0")
        put(r, "fake-commands.json", json.dumps({}))
        self.proc = None

    def tearDown(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        if self.proc:
            self.log.close()
        self.tmp.cleanup()

    def canned(self, d):
        put(self.root, "fake-commands.json", json.dumps(d))

    def start(self, uid=UID, seconds=600, modules=(SHA_A,), stay_awake_before="on"):
        argv = [sys.executable, "-I", TOOL, "daemon", "--uid", str(uid), "--expires",
                str(time.time() + seconds), "--fake", self.root, "--stay-awake-before", stay_awake_before]
        for s in modules:
            argv += ["--module", f"mod_a={s}"]
        if os.path.exists(self.sock):  # left by a killed daemon
            os.unlink(self.sock)
        log = os.path.join(self.root, "daemon.log")
        opened = open(log).read().count("session open") if os.path.exists(log) else 0
        self.log = open(log, "a")
        self.proc = subprocess.Popen(argv, env=self.env, stderr=self.log)
        for _ in range(100):
            if open(log).read().count("session open") > opened:
                return
            time.sleep(0.05)
        self.fail("daemon did not come up: " + get(self.root, "daemon.log"))

    def g(self, *args, reason="test"):
        argv = [sys.executable, "-I", TOOL, *args]
        if args[0] == "call":
            argv += ["--reason", reason]
        p = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=30)
        return p.returncode, p.stdout + p.stderr

    def stop(self):
        rc, out = self.g("session", "stop")
        self.proc.wait(timeout=10)
        return rc, out

    def commands(self):
        p = os.path.join(self.root, "commands.log")
        return open(p).read().splitlines() if os.path.exists(p) else []

    # ---------------------------------------------------------------- no session
    def test_no_session_every_call_fails(self):
        rc, out = self.g("call", "knob-set", "nmi-watchdog", "0")
        self.assertEqual(rc, 3, out)
        self.assertIn("no session open", out)
        self.assertEqual(self.g("available")[0], 3)
        self.assertEqual(get(self.root, "proc/sys/kernel/nmi_watchdog"), "1")

    def test_other_uid_refused(self):
        self.start(uid=UID + 4242)
        rc, out = self.g("call", "knob-set", "nmi-watchdog", "0")
        self.assertEqual(rc, 1)
        self.assertIn("not this session's user", out)
        self.assertEqual(get(self.root, "proc/sys/kernel/nmi_watchdog"), "1")

    def test_reason_required(self):
        self.start()
        rc, out = self.g("call", "knob-set", "nmi-watchdog", "0", reason="")
        self.assertEqual(rc, 1)
        self.assertIn("--reason", out)

    # ---------------------------------------------------------------- knobs
    def test_knob_allowlist(self):
        self.start()
        for args, why in [(("knob-set", "swappiness", "10"), "unknown knob"),
                          (("knob-set", "nmi-watchdog", "2"), "not one of"),
                          (("knob-set", "panel-power-savings", "5"), "out of range"),
                          (("knob-set", "panel-power-savings", "../x"), "out of range"),
                          (("knob-set", "platform-profile", "turbo"), "not one of"),
                          (("knob-set", "nvme-apst", "30"), "not of the form"),
                          (("knob-set", "nvme-apst", "70000/500"), "at most 60000")]:
            rc, out = self.g("call", *args)
            self.assertEqual(rc, 1, args)
            self.assertIn(why, out, args)
        self.assertEqual(get(self.root, "sys/class/drm/card1-eDP-1/amdgpu/panel_power_savings"), "0")

    def test_stop_restores_every_knob(self):
        self.start()
        for k, v in [("nmi-watchdog", "0"), ("nvme-apst", "30/500"), ("platform-profile", "quiet"),
                     ("panel-power-savings", "3"), ("bt-rfkill", "1"), ("numlock-led", "0")]:
            rc, out = self.g("call", "knob-set", k, v)
            self.assertEqual(rc, 0, out)
        # a second set keeps the first original
        self.assertEqual(self.g("call", "knob-set", "panel-power-savings", "4")[0], 0)
        self.assertEqual(get(self.root, "sys/module/nvme_core/parameters/apst_primary_timeout_ms"), "30")
        rc, out = self.g("session", "status")
        self.assertEqual(json.loads(out)["knobs"]["panel-power-savings"], "0")
        rc, out = self.stop()
        self.assertEqual(rc, 0, out)
        for rel, v in [("proc/sys/kernel/nmi_watchdog", "1"),
                       ("sys/module/nvme_core/parameters/apst_primary_timeout_ms", "100"),
                       ("sys/module/nvme_core/parameters/apst_secondary_timeout_ms", "2000"),
                       ("sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us", "100000"),
                       ("sys/firmware/acpi/platform_profile", "balanced"),
                       ("sys/class/drm/card1-eDP-1/amdgpu/panel_power_savings", "0"),
                       ("sys/class/rfkill/rfkill0/soft", "0"),
                       ("sys/class/leds/input3::numlock/brightness", "1")]:
            self.assertEqual(get(self.root, rel), v, rel)
        self.assertFalse(os.path.exists(os.path.join(self.root, "var/lib/omarchy-asus-g16-testd/records.json")))
        self.assertFalse(os.path.exists(self.sock))

    def test_knob_restore_one(self):
        self.start()
        self.g("call", "knob-set", "nmi-watchdog", "0")
        rc, out = self.g("call", "knob-restore", "nmi-watchdog")
        self.assertEqual((rc, out.strip()), (0, "1"))
        self.assertEqual(self.g("call", "knob-restore", "nmi-watchdog")[1].strip(), "not changed")

    def test_wifi_through_iw(self):
        put(self.root, "sys/class/net/wlan0/phy80211", "")
        self.canned({"iw dev wlan0 get power_save": "Power save: off"})
        self.start()
        self.assertEqual(self.g("call", "knob-set", "wifi-ps", "on")[0], 0)
        self.stop()
        c = self.commands()
        self.assertIn("iw dev wlan0 set power_save on", c)
        self.assertIn("iw dev wlan0 set power_save off", c[c.index("iw dev wlan0 set power_save on"):])

    def test_expiry_restores(self):
        self.start(seconds=2)
        self.g("call", "knob-set", "nmi-watchdog", "0")
        self.g("call", "boot-dropin", "nmi-watchdog-off", "on")
        self.proc.wait(timeout=10)
        self.assertEqual(get(self.root, "proc/sys/kernel/nmi_watchdog"), "1")
        self.assertFalse(os.path.exists(os.path.join(self.root, "etc/limine-entry-tool.d")
                                        + "/omarchy-asus-g16-testd-nmi-watchdog-off.conf"))

    def test_sigterm_restores_runtime_keeps_dropins(self):
        self.start()
        self.g("call", "knob-set", "nmi-watchdog", "0")
        self.g("call", "boot-dropin", "nmi-watchdog-off", "on")
        self.proc.send_signal(signal.SIGTERM)
        self.proc.wait(timeout=10)
        self.assertEqual(get(self.root, "proc/sys/kernel/nmi_watchdog"), "1")
        f = os.path.join(self.root, "etc/limine-entry-tool.d/omarchy-asus-g16-testd-nmi-watchdog-off.conf")
        self.assertTrue(os.path.exists(f))
        # a later session after the reboot still knows it, and its stop removes it
        put(self.root, "proc/sys/kernel/random/boot_id", "boot-2")
        self.start()
        self.assertEqual(json.loads(self.g("session", "status")[1])["dropins"], ["nmi-watchdog-off"])
        self.stop()
        self.assertFalse(os.path.exists(f))

    def test_crash_recovered_at_next_start(self):
        self.start()
        self.g("call", "knob-set", "nmi-watchdog", "0")
        self.g("call", "knob-set", "platform-profile", "performance")
        self.proc.kill()
        self.proc.wait()
        self.assertEqual(get(self.root, "proc/sys/kernel/nmi_watchdog"), "0")
        self.start()
        self.assertEqual(get(self.root, "proc/sys/kernel/nmi_watchdog"), "1")
        self.assertEqual(get(self.root, "sys/firmware/acpi/platform_profile"), "balanced")
        self.assertEqual(json.loads(self.g("session", "status")[1])["knobs"], {})

    def test_crash_in_an_earlier_boot_not_replayed(self):
        self.start()
        self.g("call", "knob-set", "platform-profile", "performance")
        self.proc.kill()
        self.proc.wait()
        put(self.root, "proc/sys/kernel/random/boot_id", "boot-2")
        put(self.root, "sys/firmware/acpi/platform_profile", "quiet")  # the user's own, since
        self.start()
        self.assertEqual(get(self.root, "sys/firmware/acpi/platform_profile"), "quiet")

    def test_sd_reader_remove_and_rescan(self):
        port = put(self.root, "sys/devices/pci0000:00/0000:00:02.2/power/control", "auto")
        port = os.path.dirname(os.path.dirname(port))
        dev = os.path.join(port, "0000:62:00.0")
        put(self.root, f"{dev}/vendor", "0x17a0")
        put(self.root, f"{dev}/device", "0x9767")
        os.makedirs(os.path.join(self.root, "sys/bus/pci/devices"))
        link = os.path.join(self.root, "sys/bus/pci/devices/0000:62:00.0")
        os.symlink(dev, link)
        self.start()
        self.assertEqual(self.g("call", "knob-set", "sd-reader", "removed")[0], 0)
        self.assertEqual(get(self.root, f"{dev}/remove"), "1")
        os.unlink(link)  # what the kernel does on remove
        put(self.root, f"{port}/rescan", "")
        # the fake has no kernel to bring it back: the rescan below its port is tried,
        # the port's own setting goes back, and stop says the reader didn't return
        rc, out = self.stop()
        self.assertEqual(rc, 1, out)
        self.assertIn("did not come back", out)
        self.assertEqual(get(self.root, f"{port}/rescan"), "1")
        self.assertEqual(get(self.root, f"{port}/power/control"), "auto")

    # ---------------------------------------------------------------- stay-awake
    def allow_idle_runs(self):
        return [c for c in self.commands() if c.endswith("omarchy-toggle-idle allow-idle")]

    def test_stay_awake_put_back_only_if_it_was_off(self):
        self.start(stay_awake_before="on")
        self.stop()
        self.assertEqual(self.allow_idle_runs(), [])
        self.start(stay_awake_before="off")
        self.assertEqual(json.loads(self.g("session", "status")[1])["stay_awake_before"], "off")
        self.stop()
        self.assertEqual(self.allow_idle_runs(), [f"setpriv --reuid={UID} --regid={os.getgid()} --init-groups "
                                                  "--reset-env omarchy-toggle-idle allow-idle"])

    def test_stay_awake_put_back_at_expiry_and_sigterm(self):
        self.start(seconds=2, stay_awake_before="off")
        self.proc.wait(timeout=10)
        self.assertEqual(len(self.allow_idle_runs()), 1)
        self.start(stay_awake_before="off")
        self.proc.send_signal(signal.SIGTERM)
        self.proc.wait(timeout=10)
        self.assertEqual(len(self.allow_idle_runs()), 2)

    def test_client_records_and_puts_back_leftover(self):
        bin_ = os.path.join(self.root, "bin")
        state = os.path.join(self.root, "state")
        calls = os.path.join(self.root, "idle.log")
        put(bin_, "omarchy-toggle-idle", f'#!/bin/sh\necho "$1" >>{calls}\n'
            'if [ "$1" = status ]; then echo \'{"enabled":false}\'; fi\n')
        os.chmod(os.path.join(bin_, "omarchy-toggle-idle"), 0o755)
        put(bin_, "systemd-run", "#!/bin/sh\nexit 0\n")  # stands in for the pkexec dialog
        os.chmod(os.path.join(bin_, "systemd-run"), 0o755)
        env = dict(self.env, PATH=f"{bin_}:{os.environ['PATH']}", XDG_STATE_HOME=state)
        record = os.path.join(state, "omarchy-asus-g16-testd/stay-awake-before")
        run = lambda *a: subprocess.run([sys.executable, "-I", TOOL, *a], env=env,  # noqa: E731
                                        capture_output=True, text=True, timeout=30)
        p = run("session", "start")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(get(self.root, record), "off")
        self.assertEqual(open(calls).read().split(), ["status", "stay-awake"])
        # the session ended without its restore (a crash): the next start puts it back first
        p = run("session", "start")
        self.assertEqual(open(calls).read().split(), ["status", "stay-awake", "allow-idle", "status", "stay-awake"])

    # ---------------------------------------------------------------- modules
    def module_file(self, data):
        p = os.path.join(self.root, "home-mod_a.ko")
        with open(p, "wb") as f:
            f.write(data)
        return p

    def test_module_unlisted_sha_refused(self):
        self.start()
        rc, out = self.g("call", "module-swap", "mod_a", self.module_file(b"something else"))
        self.assertEqual(rc, 1)
        self.assertIn("not this session's", out)
        rc, out = self.g("call", "module-swap", "mod_b", self.module_file(b"module A"))
        self.assertEqual(rc, 1)
        self.assertIn("not on this session's list", out)
        self.assertFalse([c for c in self.commands() if c.startswith(("insmod", "rmmod"))])

    def test_module_not_a_regular_file_refused(self):
        self.start()
        rc, out = self.g("call", "module-swap", "mod_a", self.root)
        self.assertEqual(rc, 1)
        self.assertIn("not a regular file you own", out)

    def test_module_swap_and_restore(self):
        os.makedirs(os.path.join(self.root, "sys/module/mod_a"))
        copy = os.path.join(self.root, f"var/lib/omarchy-asus-g16-testd/modules/mod_a-{SHA_A[:16]}.ko")
        self.canned({f"modinfo -F name {copy}": "mod_a\n"})
        self.start()
        rc, out = self.g("call", "module-swap", "mod_a", self.module_file(b"module A"))
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.commands()[-2:], ["rmmod mod_a", f"insmod {copy}"])
        self.stop()
        self.assertEqual(self.commands()[-2:], ["rmmod mod_a", "modprobe mod_a"])
        self.assertFalse(os.path.exists(copy))

    def test_module_wrong_inner_name_refused(self):
        copy = os.path.join(self.root, f"var/lib/omarchy-asus-g16-testd/modules/mod_a-{SHA_A[:16]}.ko")
        self.canned({f"modinfo -F name {copy}": "evil\n"})
        self.start()
        rc, out = self.g("call", "module-swap", "mod_a", self.module_file(b"module A"))
        self.assertEqual(rc, 1)
        self.assertIn("is module evil", out)

    # ---------------------------------------------------------------- drop-ins
    def test_dropin_allowlist_and_cmdline(self):
        self.start()
        rc, out = self.g("call", "boot-dropin", "init-bash", "on")
        self.assertEqual(rc, 1)
        self.assertIn("unknown drop-in", out)
        rc, out = self.g("call", "boot-dropin", "nmi-watchdog-off", "on")
        self.assertEqual(rc, 0, out)
        self.assertIn("quiet splash rcu_nocbs=all", out)
        f = os.path.join(self.root, "etc/limine-entry-tool.d/omarchy-asus-g16-testd-nmi-watchdog-off.conf")
        self.assertIn('KERNEL_CMDLINE[default]+=" nmi_watchdog=0"', open(f).read())
        self.assertIn("limine-update", self.commands())
        self.stop()
        self.assertFalse(os.path.exists(f))
        self.assertEqual(self.commands().count("limine-update"), 2)

    # ---------------------------------------------------------------- tracing
    def test_trace_allowlist(self):
        self.start()
        rc, out = self.g("call", "trace-start", "w", "syscalls/sys_enter_openat")
        self.assertEqual(rc, 1)
        self.assertIn("not on the allowlist", out)
        rc, out = self.g("call", "trace-start", "w", "-", "do-sys-open")
        self.assertEqual(rc, 1)
        rc, out = self.g("call", "trace-start", "../x", "timer/hrtimer_start")
        self.assertEqual(rc, 1)
        self.assertEqual(os.listdir(os.path.join(self.root, "sys/kernel/tracing/instances")), [".keep"])

    def test_trace_no_events_refused_and_cleaned(self):
        self.start()
        inst = os.path.join(self.root, "sys/kernel/tracing/instances/g16-testd-x")
        rc, out = self.g("call", "trace-start", "x", "timer/hrtimer_start", "pci-set-power-state")
        self.assertEqual(rc, 1)
        self.assertIn("none of the events exist", out)
        self.assertFalse(os.path.exists(inst))
        self.assertEqual(get(self.root, "sys/kernel/tracing/kprobe_events").splitlines(),
                         ["p:g16testd/pci_set_power_state pci_set_power_state", "-:g16testd/pci_set_power_state"])

    def test_trace_start_stop(self):
        tpl = os.path.join(self.root, "fake-instance")
        put(tpl, "events/timer/hrtimer_start/enable", "0")
        put(tpl, "events/g16testd/pci_set_power_state/enable", "0")
        put(tpl, "trace", "<idle>-0 hrtimer_start")
        self.start()
        rc, out = self.g("call", "trace-start", "x", "timer/hrtimer_start,timer/tick_stop", "pci-set-power-state")
        self.assertEqual(rc, 0, out)
        r = json.loads(out)
        self.assertEqual(r["missing"], ["timer/tick_stop"])
        inst = os.path.join(self.root, "sys/kernel/tracing/instances/g16-testd-x")
        self.assertEqual(get(inst, "tracing_on"), "1")
        self.assertEqual(get(inst, "events/g16testd/pci_set_power_state/enable"), "1")
        rc, out = self.g("call", "trace-stop", "x")
        self.assertEqual(rc, 0, out)
        self.assertEqual(open(out.strip()).read().strip(), "<idle>-0 hrtimer_start")
        self.assertEqual(oct(os.stat(out.strip()).st_mode & 0o777), "0o600")
        self.assertFalse(os.path.exists(inst))
        self.assertTrue(get(self.root, "sys/kernel/tracing/kprobe_events").endswith("-:g16testd/pci_set_power_state"))

    def test_trace_left_running_removed_at_stop(self):
        put(self.root, "fake-instance/events/timer/hrtimer_start/enable", "0")
        self.start()
        self.assertEqual(self.g("call", "trace-start", "y", "timer/hrtimer_start")[0], 0)
        self.stop()
        self.assertEqual(os.listdir(os.path.join(self.root, "sys/kernel/tracing/instances")), [".keep"])

    # ---------------------------------------------------------------- freeze
    def test_freeze_only_app_scopes_and_thaw(self):
        self.start()
        rc, out = self.g("call", "freeze", "voxtype.service")
        self.assertEqual(rc, 1)
        self.assertIn("only user app scopes", out)
        rc, out = self.g("call", "freeze", "app-../../x.scope")
        self.assertEqual(rc, 1)
        rc, out = self.g("call", "freeze", "app-Hyprland-firefox-123.scope", "60")
        self.assertEqual(rc, 0, out)
        f = f"{self.cg}/app-graphical.slice/app-Hyprland-firefox-123.scope/cgroup.freeze"
        self.assertEqual(get(self.root, f), "1")
        self.stop()
        self.assertEqual(get(self.root, f), "0")

    def test_freeze_watchdog(self):
        self.start()
        self.g("call", "freeze", "app-Hyprland-firefox-123.scope", "1")
        time.sleep(2.5)
        f = f"{self.cg}/app-graphical.slice/app-Hyprland-firefox-123.scope/cgroup.freeze"
        self.assertEqual(get(self.root, f), "0")

    # ---------------------------------------------------------------- EC
    def test_ec_read_only(self):
        self.start()
        rc, out = self.g("call", "ec-read", "0x06", "2")
        self.assertEqual((rc, out.strip()), (0, "0607"))
        self.assertIn("modprobe ec_sys write_support=0", self.commands())
        self.assertEqual(self.g("call", "ec-read", "250", "10")[0], 1)
        self.stop()
        self.assertEqual(self.commands()[-1], "modprobe -r ec_sys")

    def test_ec_write_support_refused(self):
        put(self.root, "sys/module/ec_sys/parameters/write_support", "Y")
        self.start()
        rc, out = self.g("call", "ec-read", "6", "1")
        self.assertEqual(rc, 1)
        self.assertIn("write_support on", out)

    def test_wrong_arg_count(self):
        self.start()
        rc, out = self.g("call", "knob-set", "nmi-watchdog")
        self.assertEqual(rc, 1)
        self.assertIn("wrong number of arguments", out)


class Package(unittest.TestCase):
    def test_list_runs_without_a_session(self):
        p = subprocess.run([sys.executable, "-I", TOOL, "list"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("nmi-watchdog", p.stdout)

    def test_policy_points_at_the_installed_tool(self):
        pol = open(os.path.join(HERE, "..", "io.github.omarchy-asus.g16-testd.policy")).read()
        self.assertIn(">/usr/lib/omarchy-asus-g16-testd/g16-testd<", pol)
        self.assertIn("<allow_active>auth_admin</allow_active>", pol)
        self.assertNotIn("yes</allow", pol)


if __name__ == "__main__":
    unittest.main(verbosity=1)
