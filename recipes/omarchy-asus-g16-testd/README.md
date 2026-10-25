# omarchy-asus-g16-testd

> [!WARNING]
> **EXPERIMENTAL. For the ASUS ROG Zephyrus G16 GA605KM only.** Test tooling:
> it refuses to open a session on any other machine, and nothing pulls it in.

One root helper per G16 hardware test session (#277). A test session needs
root for many small steps: a sysfs knob written and put back, a private
tracefs instance, EC RAM read through `ec_sys`, a module swap, a boot drop-in.
With a pkexec dialog for each step, the dialogs set the session's pace, and
the shell's polkit agent loses some when two are pending at once. With this
package a session asks once:

```sh
g16-testd session start            # the one dialog; 4 h (--hours, at most 12)
g16-testd call knob-set nmi-watchdog 0 --reason "#225 A/B"
g16-testd call trace-start w timer/hrtimer_expire_entry,ipi/ipi_send_cpu - --reason "#239"
g16-testd call trace-stop w --reason "#239"   # prints the trace file, yours, mode 0600
g16-testd session status
g16-testd session stop             # everything back; the helper is gone
```

`g16-testd list` prints every allowlist. `g16-testd available` exits 0 when a
session is open for you, so a kit can use the helper when it's there and fall
back to its own pkexec step when it isn't.

## What it can do

Only fixed operations, each on a fixed allowlist in the program itself.
Nothing a caller sends is run as a command.

| call | does | limits |
|---|---|---|
| `ec-read OFFSET LEN` | loads `ec_sys write_support=0` and reads EC RAM (FTBL, #185/#244) | 256 bytes; refuses when `ec_sys` is loaded with write support |
| `trace-start NAME EVENTS [KPROBES] [BUFFER_KB]` / `trace-stop NAME` | a private tracefs instance `g16-testd-NAME` and named kprobes (#218, #239, #172); `trace-stop` hands the trace over as an open file and writes it to `$XDG_RUNTIME_DIR/omarchy-asus-g16-testd/NAME.trace`, yours to remove, so the helper keeps no copy (#284) | events and kprobes from the allowlist, each kprobe with its fixed fetch arguments (`dmub-cacp-set-level` records `level`); stopped after 30 min, then kept by the helper until `trace-stop NAME` collects it or the session ends |
| `knob-set KNOB VALUE` / `knob-restore KNOB` | the A/B knobs: `nmi-watchdog`, `nvme-apst`, `sd-reader`, `sd-reader-pm`, `kbd-usb-pm`, `numlock-led`, `wifi-ps`, `bt-rfkill`, `panel-power-savings`, `platform-profile`; the Zen 5c-first knobs of kernel patch 9900 (#10) `hfi-ranking`, `hfi-wake-preferred`, `hfi-wake-pack`, `hfi-wlc-track`; and for the boost and clock tweaks (#328) `cpu-boost` (its restore also puts each policy's `scaling_max_freq` back, which the kernel can lower while boost is off), `cpu-epp` (every policy), `cpu-max-freq` (every policy, at most its own `cpuinfo_max_freq`; each put back to its own value) and `pmf-profile` (amd-pmf's own platform profile, so asus-wmi's stays as it is; `platform-profile` sets every handler) | each knob's own values or range (`g16-testd list`); knobs go back last-set first |
| `module-swap NAME PATH` / `module-restore NAME` | swaps in a test build of a module (#226), then puts the stock one back | only builds whose sha256 was given at `session start --module NAME=SHA256`; the copy that is loaded is the one hashed |
| `boot-dropin NAME on\|off` | a limine-entry-tool drop-in (`rcu-nocbs-all`, `nmi-watchdog-off`, #229), then `limine-update`; prints the resulting command lines to check before a reboot | named drop-ins only |
| `freeze SCOPE [SECONDS]` / `thaw SCOPE` | freezes one of your app scopes (#249) | `app-*.scope` under your own `app.slice`, never a service; thawed after 300 s (at most 1800) whatever happens |

Every call needs `--reason`, and is logged to the journal
(`journalctl -u omarchy-asus-g16-testd`) with the caller's uid, pid and the
reason.

## How it holds

- **One dialog.** `session start` runs `pkexec g16-testd root-start` once
  (polkit action `io.github.omarchy-asus.g16-testd.session-start`,
  `auth_admin`). That starts the helper as a transient system unit,
  `omarchy-asus-g16-testd.service`, with a runtime limit just past the
  session's expiry.
- **Only while the session is open, only for you.** The helper listens on
  `/run/omarchy-asus-g16-testd/socket`, owned by the user who opened the
  session, mode 0600, and checks every connection's peer uid. No polkit rule
  stays behind: with no session open there is no helper, and every call fails
  (exit 3).
- **Everything goes back.** Each change is recorded under
  `/var/lib/omarchy-asus-g16-testd` before it is made. `session stop` and the
  expiry put back every knob, module, trace, frozen scope and drop-in. When
  the unit is stopped (a reboot included), runtime changes go back and the
  drop-ins stay, because a boot A/B needs them across the reboot; the next
  session lists them and its stop removes them. After a crash, the next start
  puts back what the last one changed in the same boot.
- **Stay-awake for the session.** `session start` records Omarchy's
  stay-awake state (`omarchy-toggle-idle status`) and turns it on, so no idle
  dim, lock or suspend cuts into an unattended A/B. At the end, `allow-idle`
  runs only if stay-awake was off before. `session status` shows the state from
  before the session. If the helper couldn't run `allow-idle` (a crash, a
  failure), the session's record stays and the next `session start` puts it
  back first. If it did, the record is only retired, so a stay-awake you turn on
  yourself afterwards stays on.
- **Removing the package** ends an open session and puts back everything any
  session left, the boot drop-ins included (`g16-testd cleanup` from the
  package's removal, then `limine-update`).
- No windows, no sound, nothing outside the allowlists.

## Testing

`tests/channel/g16-testd.sh` runs `tests/test_g16_testd.py`: the helper as
your own user against a fake root (`--fake`), with every command it would run
only logged. It checks that the allowlists refuse what isn't on them, that
everything is put back on stop, expiry, SIGTERM and after a crash, that
another uid is refused and that calls fail with no session open, and that
stay-awake is handled. It then checks that `package()` installs exactly the
expected files.
