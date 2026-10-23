#!/usr/bin/env python3
"""Offline tests for the `proton` launcher: python3 -I recipes/proton-experimental-asus/tests/launcher.test.py

A fake Proton Experimental (its `proton` records how it was run) and a fake installed tool
directory; no Steam, no wine.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

RECIPE = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
PIN = "experimental-11.0-20261014-x86_64"
FAKE_PROTON = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["RECORD"], "w") as f:
    json.dump({"dir": os.path.dirname(os.path.abspath(sys.argv[0])), "args": sys.argv[1:]}, f)
"""


class Launcher(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        # installed tool: our launcher, pin, drivers
        self.tool = os.path.join(self.tmp, "tool")
        for arch in ("x86_64", "i386"):
            self.write(f"tool/lib/wine/{arch}-unix/winex11.so", f"ours {arch}")
        shutil.copy(os.path.join(RECIPE, "proton"), os.path.join(self.tool, "proton"))
        self.write("tool/PROTON_PIN", PIN + "\n")
        # Valve's Proton Experimental in a Steam library
        self.steam = os.path.join(self.tmp, "Steam")
        self.valve = os.path.join(self.steam, "steamapps", "common", "Proton - Experimental")
        self.write("Steam/steamapps/appmanifest_1493710.acf",
                   '"AppState"\n{\n\t"appid"\t\t"1493710"\n\t"installdir"\t\t"Proton - Experimental"\n}\n')
        self.write("Steam/steamapps/libraryfolders.vdf",
                   f'"libraryfolders"\n{{\n\t"0"\n\t{{\n\t\t"path"\t\t"{self.steam}"\n\t}}\n}}\n')
        self.write("Steam/steamapps/common/Proton - Experimental/proton", FAKE_PROTON)
        self.set_valve_build(PIN)
        for arch in ("x86_64", "i386"):
            self.write(f"Steam/steamapps/common/Proton - Experimental/files/lib/wine/{arch}-unix/winex11.so",
                       f"valve {arch}")
            self.write(f"Steam/steamapps/common/Proton - Experimental/files/lib/wine/{arch}-unix/win32u.so",
                       f"valve win32u {arch}")
        os.symlink("x86_64-unix", os.path.join(self.valve, "files/lib/wine/link-unix"))
        self.data = os.path.join(self.tmp, "data")
        self.record = os.path.join(self.tmp, "record.json")

    def write(self, rel, text):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def read(self, path):
        with open(path) as f:
            return f.read()

    def set_valve_build(self, build):
        self.write("Steam/steamapps/common/Proton - Experimental/version", f"1791989105 {build}\n")

    def run_tool(self, *args, **env):
        e = {"PATH": os.environ["PATH"], "HOME": self.tmp, "XDG_DATA_HOME": self.data,
             "STEAM_COMPAT_CLIENT_INSTALL_PATH": self.steam, "RECORD": self.record}
        e.update(env)
        if os.path.exists(self.record):
            os.unlink(self.record)
        p = subprocess.run([sys.executable, os.path.join(self.tool, "proton")] + list(args),
                           env=e, capture_output=True, text=True)
        rec = json.loads(self.read(self.record)) if os.path.exists(self.record) else None
        return p, rec

    def copy_dir(self):
        return os.path.join(self.data, "omarchy-asus", "proton-experimental-asus", PIN)

    def test_pinned_build_runs_the_fixed_copy(self):
        p, rec = self.run_tool("waitforexitandrun", "game.exe", "-arg")
        self.assertEqual(p.returncode, 0, p.stderr)
        copy = self.copy_dir()
        self.assertEqual(rec, {"dir": copy, "args": ["waitforexitandrun", "game.exe", "-arg"]})
        for arch in ("x86_64", "i386"):
            lib = f"files/lib/wine/{arch}-unix"
            self.assertEqual(self.read(os.path.join(copy, lib, "winex11.so")), f"ours {arch}")
            # Valve's own file is untouched, the rest are hard links to it
            self.assertEqual(self.read(os.path.join(self.valve, lib, "winex11.so")), f"valve {arch}")
            self.assertTrue(os.path.samefile(os.path.join(copy, lib, "win32u.so"),
                                             os.path.join(self.valve, lib, "win32u.so")))
        self.assertTrue(os.path.islink(os.path.join(copy, "files/lib/wine/link-unix")))

    def test_second_run_reuses_the_copy(self):
        self.run_tool("run", "a.exe")
        marker = os.path.join(self.copy_dir(), "files/lib/wine/x86_64-unix/win32u.so")
        ino = os.stat(marker).st_ino
        p, rec = self.run_tool("run", "b.exe")
        self.assertNotIn("preparing", p.stderr)
        self.assertEqual(rec["dir"], self.copy_dir())
        self.assertEqual(os.stat(marker).st_ino, ino)

    def test_updated_driver_refreshes_the_copy(self):
        self.run_tool("run", "a.exe")
        self.write("tool/lib/wine/x86_64-unix/winex11.so", "ours x86_64, rebuilt")
        p, rec = self.run_tool("run", "a.exe")
        self.assertIn("preparing", p.stderr)
        self.assertEqual(self.read(os.path.join(self.copy_dir(), "files/lib/wine/x86_64-unix/winex11.so")),
                         "ours x86_64, rebuilt")

    def test_other_build_runs_valve_unchanged(self):
        self.set_valve_build("experimental-11.0-20261101-x86_64")
        p, rec = self.run_tool("run", "game.exe")
        self.assertEqual(rec, {"dir": self.valve, "args": ["run", "game.exe"]})
        self.assertIn("running Proton Experimental unchanged", p.stderr)
        self.assertFalse(os.path.exists(self.copy_dir()))

    def test_new_pin_removes_the_old_copy(self):
        self.run_tool("run", "a.exe")
        old = self.copy_dir()
        new_pin = "experimental-11.0-20261101-x86_64"
        self.write("tool/PROTON_PIN", new_pin + "\n")
        self.set_valve_build(new_pin)
        p, rec = self.run_tool("run", "a.exe")
        self.assertEqual(rec["dir"], os.path.join(os.path.dirname(old), new_pin))
        self.assertFalse(os.path.exists(old))

    def test_library_on_another_path(self):
        # Proton Experimental in a second library listed in libraryfolders.vdf
        lib2 = os.path.join(self.tmp, "games")
        os.makedirs(os.path.join(lib2, "steamapps", "common"))
        shutil.move(self.valve, os.path.join(lib2, "steamapps", "common", "Proton - Experimental"))
        shutil.move(os.path.join(self.steam, "steamapps", "appmanifest_1493710.acf"),
                    os.path.join(lib2, "steamapps"))
        self.write("Steam/steamapps/libraryfolders.vdf",
                   f'"libraryfolders"\n{{\n\t"0"\n\t{{\n\t\t"path"\t\t"{self.steam}"\n\t}}\n'
                   f'\t"1"\n\t{{\n\t\t"path"\t\t"{lib2}"\n\t}}\n}}\n')
        p, rec = self.run_tool("run", "a.exe")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(rec["dir"], self.copy_dir())

    def test_concurrent_first_launches(self):
        # several games starting at once on a fresh install: each runs the finished copy
        env = {"PATH": os.environ["PATH"], "HOME": self.tmp, "XDG_DATA_HOME": self.data,
               "STEAM_COMPAT_CLIENT_INSTALL_PATH": self.steam}
        procs = []
        for i in range(6):
            e = dict(env, RECORD=os.path.join(self.tmp, f"record{i}.json"))
            procs.append(subprocess.Popen([sys.executable, os.path.join(self.tool, "proton"), "run", f"{i}.exe"],
                                          env=e, stderr=subprocess.PIPE, text=True))
        for i, p in enumerate(procs):
            _, err = p.communicate()
            self.assertEqual(p.returncode, 0, err)
            rec = json.loads(self.read(os.path.join(self.tmp, f"record{i}.json")))
            self.assertEqual(rec, {"dir": self.copy_dir(), "args": ["run", f"{i}.exe"]})
        self.assertEqual(self.read(os.path.join(self.copy_dir(), "files/lib/wine/x86_64-unix/winex11.so")),
                         "ours x86_64")
        leftovers = [n for n in os.listdir(os.path.dirname(self.copy_dir())) if ".tmp-" in n]
        self.assertEqual(leftovers, [])

    def test_not_installed(self):
        shutil.rmtree(self.valve)
        p, rec = self.run_tool("run", "a.exe")
        self.assertEqual(p.returncode, 1)
        self.assertIsNone(rec)
        self.assertIn("not installed", p.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
