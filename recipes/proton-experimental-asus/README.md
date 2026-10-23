# proton-experimental-asus

A Steam compatibility tool, **Proton Experimental (omarchy-asus)**: Valve's Proton
Experimental with one wine fix, for games in exclusive fullscreen on a multi-monitor
Hyprland setup (#266).

## What it fixes

Pick exclusive fullscreen in a game while Hyprland shows the game on another monitor
than the game's chosen one (on the G16: the game is on the HDMI monitor, the game's
display is the laptop panel, Wine's display 1). The pointer is then wrong in the game:
hover and clicks land about 80 px higher than the pointer (the letterbox of the emulated
2560x1440 mode on the 2560x1600 panel), the bottom of the screen can't be reached, and a
game that confines the cursor gets it pinned to the panel's edge, so edge-scroll pans
while the pointer is mid-screen. Borderless fullscreen isn't affected.

Why: when the game moves its fullscreen window to display 1, winex11 sends
`_NET_WM_FULLSCREEN_MONITORS` and, since Proton's wine commit a63f42b3 ("winex11:
Serialize _NET_WM_FULLSCREEN_MONITORS changes by expecting a ConfigureNotify."), waits for
the window manager to answer with a ConfigureNotify before it sends or accepts any other
geometry change. Hyprland (and sway, and other wlroots XWayland window managers) don't
support `_NET_WM_FULLSCREEN_MONITORS` (it isn't in their `_NET_SUPPORTED`), so the answer
never comes. The Win32 side keeps the window on the panel with the panel's emulated mode,
while the X11 window stays on HDMI: pointer positions are mapped through the wrong
monitor.

The fix, `general-0001-winex11-Only-expect-a-ConfigureNotify-for-_NET_WM_FU.patch`, only
waits for that ConfigureNotify when the window manager lists `_NET_WM_FULLSCREEN_MONITORS`
in `_NET_SUPPORTED`. Otherwise the geometry request goes out, Hyprland answers it with the
geometry it keeps (ICCCM's synthetic ConfigureNotify), and the Win32 window follows the
X11 window to the monitor it is really on. Window managers that support the hint (KWin,
Mutter) take the same path as before. It is a general Wine/Hyprland fix, not specific to
ASUS hardware, hence the `general-` series. The fork branch it is regenerated from:
`asus/experimental_11.0` on https://github.com/omarchy-asus/wine (Valve's
`experimental_11.0` plus this one commit).

Valve's stable Proton 11.0 has the same code (Proton 10.0 doesn't). Upstream wine
doesn't: its `window_set_net_wm_fullscreen_monitors()` never waits for a ConfigureNotify.

## How it works

The package doesn't rebuild Proton. It ships:

- `lib/wine/{x86_64,i386}-unix/winex11.so`: the X11 driver, built from the wine commit of
  the pinned Proton Experimental build (`PROTON_PIN`, `_build`/`_winecommit` in the
  PKGBUILD) with the patch applied, with Proton's compiler flags. `check()` fails the build
  unless both load exactly the libraries Valve's do.
- `proton`: run by Steam in the Steam Linux Runtime. It finds the Proton Experimental that
  Steam installed (app 1493710). If that is the pinned build, it makes once a copy of it
  under `~/.local/share/omarchy-asus/proton-experimental-asus/<build>/` (hard links, so no
  extra space when on the same filesystem as the Steam library; a full copy otherwise) with
  our `winex11.so` in place, and runs that copy's `proton`. If Steam has a different build,
  our driver wouldn't match its `win32u.so`, so it runs Proton Experimental unchanged and
  says so on stderr; the game still starts, without the fix.

Proton Experimental must be installed in Steam (it is a requirement of the game anyway when
it is the game's compatibility tool). Select **Proton Experimental (omarchy-asus)** per game
under Properties, Compatibility. Restart Steam after installing the package.

## Updating to a new Proton Experimental

The pin must follow Valve: each Proton Experimental update turns the fix off until the
package is rebuilt for it. Proton's tags name the wine commit
(`experimental-bleeding-edge-11.0-<n>-<date>-p<proton>-w<wine>-d<dxvk>-v<vkd3d>` on the
commit the `experimental-11.0-<date>` tag points at).

1. Read the installed build: `cat ~/.local/share/Steam/steamapps/common/"Proton - Experimental"/version`.
2. `git ls-remote https://github.com/ValveSoftware/Proton refs/tags/experimental-11.0-<date>`,
   then the commit's subject gives `w<short wine commit>`; resolve it to the full commit on
   ValveSoftware/wine's `experimental_11.0` branch.
3. Rebase `asus/experimental_11.0` on the fork onto that commit, regenerate the patch
   (`git format-patch -1`, keep the `general-0001-` name), update `_build`, `_winecommit`,
   `_vkxml` (`VK_XML_VERSION` in `dlls/winevulkan/make_vulkan`), `pkgver`, the checksums,
   and the library list in `check()` if Valve's driver changed.
4. `bin/build-pkg --channel rc recipes/proton-experimental-asus`.

The launcher's tests: `python3 -I tests/launcher.test.py` (offline, a fake Proton).

Drop the package once Valve's Proton Experimental ships the fix (or reverts a63f42b3):
then stock Proton Experimental behaves the same.

## Reproducer (no game needed)

`tests/repro/` reproduces the bug in a private headless sway with two outputs laid out like
XWayland's view of the G16 (panel 2560x1600 at 0,0, HDMI 2560x1440 at 2560,0):
`fsrepro.exe` opens a borderless window on the monitor the compositor gives it, then, like a
game's display-mode menu, sets an emulated 2560x1440 mode on display 1 and moves its window
there (sway keeps it on HDMI). `vptr` moves a virtual Wayland pointer to known spots on HDMI
and clicks.

```sh
# needs mingw-w64-gcc, wayland, wlr-protocols (the virtual pointer protocol), sway, grim
cd tests/repro    # or a copy of it
x86_64-w64-mingw32-gcc -O2 -mconsole -o fsrepro.exe fsrepro.c -lgdi32 -luser32
wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml vp.h
wayland-scanner private-code /usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml vp.c
gcc -O2 -o vptr vptr.c vp.c -lwayland-client
./run.sh HEADLESS-2 <Proton files dir> -- 0 2560 1440 8 bc
```

Pointer at HDMI (400,400), (1280,720), (2000,1300); the `click: client` lines it logs:

| flags | stock Proton Experimental | with the fix |
|---|---|---|
| `b` (exclusive on display 1) | 400,320 1280,640 2000,1220 | 400,400 1280,720 2000,1300 |
| `bc` (and ClipCursor, as games do) | 2559,320 2559,640 2559,1220 | 400,400 1280,720 2000,1300 |
| `bcf` (and the game moves itself back, 5 times) | 2559,320 2559,640 2559,1220 | 400,400 1280,720 2000,1300 |

With the panel focused (`HEADLESS-1 b`) both give 400,320 1280,640 2000,1220: the emulated
mode's letterbox on the panel, which is correct there.
