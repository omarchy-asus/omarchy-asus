#!/bin/bash
# bin/g16-wakeups, offline: a fake tracefs/procfs/sysfs, the root step run as this
# user (G16_ROOT=none) and bin/issue stubbed:
#   1. a capture enables the events, snapshots /proc, keeps the trace, then turns
#      tracing and every event back off;
#   2. the report attributes each idle exit: an IPI to its call site, sender and
#      woken task (across L3), the tick, a task timer to the task that armed it
#      (with its slack), a device IRQ, a polling exit; and counts idle ticks per
#      CPU, tick_stop refusals, tasklet and workqueue functions, /proc rates;
#   3. the report is posted to #239 by default, to --issue N otherwise, without
#      the home path; --no-post posts nothing;
#   4. --analyze re-reads a kept bundle without root, and --compare reports B
#      against A;
#   5. bad options exit 2, and a missing tracefs fails without leaving a bundle.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; [[ -n ${KEEP:-} ]] || rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
SCRIPT=$W/bin/g16-wakeups
S=$T/sys P=$T/proc B=$T/bin H=$T/home
mkdir -p "$B" "$H" "$P/sys/kernel" "$S/class/dmi/id" "$S/class/power_supply/BAT1" "$S/devices/system/cpu/cpuidle" \
  "$S/module/rcutree/parameters"
echo "ROG Zephyrus G16 GA605KM_GA605KM" >"$S/class/dmi/id/product_name"
echo Battery >"$S/class/power_supply/BAT1/type"
echo Discharging >"$S/class/power_supply/BAT1/status"
echo menu >"$S/devices/system/cpu/cpuidle/current_governor"
echo Y >"$S/module/rcutree/parameters/enable_rcu_lazy"
echo 1 >"$P/sys/kernel/nmi_watchdog"
echo 7.2.8-9.4-omarchy >"$P/sys/kernel/osrelease"
echo "root=/dev/x quiet rcu_nocbs=all splash" >"$P/cmdline"
# Two L3 domains: CPUs 0-1 (Zen 5, 5.09 GHz) and 2-3 (Zen 5c, 3.5 GHz).
for c in 0 1 2 3; do
  d=$S/devices/system/cpu/cpu$c
  mkdir -p "$d/cache/index3" "$d/cpufreq"
  if ((c < 2)); then echo 0-1 >"$d/cache/index3/shared_cpu_list"; echo 5090000 >"$d/cpufreq/cpuinfo_max_freq"
  else echo 2-3 >"$d/cache/index3/shared_cpu_list"; echo 3506494 >"$d/cpufreq/cpuinfo_max_freq"; fi
done
cat >"$P/interrupts" <<'EOF'
           CPU0       CPU1       CPU2       CPU3
 LOC:       1000       1000       1000       1000   Local timer interrupts
 CAL:        100        100        100        100   Function call interrupts
EOF
cat >"$P/softirqs" <<'EOF'
                    CPU0       CPU1       CPU2       CPU3
          HI:          0          0          0          0
       TIMER:         10         10         10         10
     TASKLET:          0          0          0          0
         RCU:         50         50         50         50
EOF
# tracefs: creating an instance populates it, as the kernel does (a mkdir stub
# fills it from a template).
TRB=$S/kernel/tracing
mkdir -p "$TRB/instances" "$T/tmpl/per_cpu/cpu0"
for e in power/cpu_idle irq_vectors/local_timer_entry irq_vectors/call_function_single_entry irq_vectors/reschedule_entry \
         irq/irq_handler_entry irq/tasklet_entry ipi/ipi_send_cpu ipi/ipi_send_cpumask sched/sched_waking timer/hrtimer_start \
         timer/hrtimer_expire_entry timer/timer_start timer/timer_expire_entry timer/tick_stop \
         workqueue/workqueue_queue_work workqueue/workqueue_execute_start; do
  mkdir -p "$T/tmpl/events/$e"; echo 0 >"$T/tmpl/events/$e/enable"
done
echo 0 >"$T/tmpl/tracing_on"; echo 1408 >"$T/tmpl/buffer_size_kb"; : >"$T/tmpl/trace"
printf 'entries: 30\noverrun: 0\n' >"$T/tmpl/per_cpu/cpu0/stats"
REAL_MKDIR=$(command -v mkdir)
cat >"$B/mkdir" <<MK
#!/bin/bash
"$REAL_MKDIR" "\$@" || exit
for a in "\$@"; do
  case \$a in */kernel/tracing/instances/*) cp -r "$T/tmpl/." "\$a/" ;; esac
done
MK
chmod +x "$B/mkdir"
# Another run's instance, mid-capture: it must be left alone.
"$REAL_MKDIR" -p "$TRB/instances/g16-wakeups-1"
cp -r "$T/tmpl/." "$TRB/instances/g16-wakeups-1/"
echo 1 >"$TRB/instances/g16-wakeups-1/tracing_on"; echo "other run" >"$TRB/instances/g16-wakeups-1/trace"
# Two seconds of events: five idle exits, one of each cause.
cat >"$T/fixture.trace" <<'EOF'
# tracer: nop
#           TASK-PID     CPU#  |||||  TIMESTAMP  FUNCTION
          <idle>-0       [002] d..1. 100.000100: cpu_idle: state=2 cpu_id=2
          <idle>-0       [000] d..1. 100.000200: cpu_idle: state=2 cpu_id=0
          <idle>-0       [003] d..1. 100.000300: cpu_idle: state=2 cpu_id=3
          <idle>-0       [000] d..1. 100.000310: tick_stop: success=0 dependency=RCU
          chrome-4242    [001] d..2. 100.001000: sched_waking: comm=herdr pid=777 prio=120 target_cpu=002
          chrome-4242    [001] d..2. 100.001010: ipi_send_cpu: cpu=2 callsite=ttwu_queue_wakelist+0x123/0x240 callback=generic_smp_call_function_single_interrupt+0x0/0x20
          <idle>-0       [002] d..1. 100.001020: cpu_idle: state=4294967295 cpu_id=2
          <idle>-0       [002] d.h1. 100.001030: call_function_single_entry: vector=251
          <idle>-0       [000] d..1. 100.002000: cpu_idle: state=4294967295 cpu_id=0
          <idle>-0       [000] d.h1. 100.002010: local_timer_entry: vector=236
          <idle>-0       [000] d.h1. 100.002020: hrtimer_expire_entry: hrtimer=00000000aaaa0000 function=tick_nohz_handler now=99999
          <idle>-0       [000] d.h1. 100.002030: hrtimer_start: hrtimer=00000000aaaa0000 function=tick_nohz_handler expires=100000 softexpires=100000 mode=ABS was_armed=0
        Hyprland-900     [001] d..1. 100.003000: hrtimer_start: hrtimer=00000000bbbb0000 function=hrtimer_wakeup expires=1050000 softexpires=1000000 mode=ABS was_armed=0
          <idle>-0       [001] d..1. 100.003100: cpu_idle: state=2 cpu_id=1
          <idle>-0       [003] d..1. 100.004000: cpu_idle: state=4294967295 cpu_id=3
          <idle>-0       [003] d.h1. 100.004010: local_timer_entry: vector=236
          <idle>-0       [003] d.h1. 100.004020: hrtimer_expire_entry: hrtimer=00000000bbbb0000 function=hrtimer_wakeup now=1050100
          <idle>-0       [003] d.h1. 100.004030: hrtimer_expire_entry: hrtimer=00000000ffff0000 function=tick_nohz_handler now=1050100
          <idle>-0       [001] d..1. 100.005000: cpu_idle: state=4294967295 cpu_id=1
          <idle>-0       [001] d.h1. 100.005010: irq_handler_entry: irq=77 name=mt7925e
     mt76-tx phy0-812    [001] d.s1. 100.005020: sched_waking: comm=mt76-tx phy0 pid=812 prio=120 target_cpu=001
          <idle>-0       [001] d.s1. 100.005030: tasklet_entry: tasklet=00000000cccc0000 function=mt76_irq_tasklet
          <idle>-0       [001] d.s1. 100.005040: workqueue_queue_work: work struct=00000000dddd0000 function=usb_giveback_urb_bh workqueue=events_bh req_cpu=8192 cpu=1
          <idle>-0       [001] d.s1. 100.005050: workqueue_execute_start: work struct 00000000dddd0000: function usb_giveback_urb_bh
          <idle>-0       [000] d..1. 100.006000: cpu_idle: state=2 cpu_id=0
          <idle>-0       [000] d..1. 100.007000: cpu_idle: state=4294967295 cpu_id=0
          <idle>-0       [000] d..1. 100.007100: cpu_idle: state=2 cpu_id=0
           herdr-777     [002] d..1. 100.007500: timer_start: timer=00000000eeee0000 function=process_timeout expires=2 [timeout=1] bucket_expiry=2 cpu=2 idx=0 flags=
          <idle>-0       [002] ..s1. 100.008000: timer_expire_entry: timer=00000000eeee0000 function=process_timeout now=1 baseclk=1
       HeapUser-31       [000] ...1. 100.009000: ipi_send_cpumask: cpumask=00000000,0000000c callsite=flush_tlb_mm_range+0x1f6/0x740 callback=generic_smp_call_function_single_interrupt+0x0/0x20
EOF
# bin/issue stub: records "N agent" per post and keeps the body.
cat >"$B/issue" <<'EOF'
#!/bin/bash
n=$2; shift 2; agent='' body=''
while (($#)); do case $1 in --agent) agent=$2; shift ;; --body-file) body=$2; shift ;; esac; shift; done
echo "$n $agent" >>"$STUB/posts"; cp "$body" "$STUB/body.$n"
EOF
chmod +x "$B/issue"
run() { env HOME="$H" STUB="$T" G16_ROOT=none G16_WK_SYS="$S" G16_WK_PROC="$P" G16_WK_ISSUE="$B/issue" \
  G16_WK_STATE="$H/state" "$SCRIPT" "$@"; }

# 1. capture: feed the fixture in while tracing is on, as the kernel would.
(
  for _ in $(seq 100); do
    for I in "$TRB"/instances/g16-wakeups-*; do [[ $I != */g16-wakeups-1 && $(cat "$I/tracing_on" 2>/dev/null) == 1 ]] && break 2; done
    sleep 0.05
  done
  cp "$T/fixture.trace" "$I/trace"
  # /proc moves on during the window: LOC +400 per CPU, RCU +20 per CPU over 2 s.
  sed -i 's/1000 /1400 /g' "$P/interrupts"; sed -i 's/ 50 / 70 /g; s/ 50$/ 70/' "$P/softirqs"
) &
out=$(PATH="$B:$PATH" run --seconds 2 --label stock 2>&1); rc=$?
wait
for I in "$TRB"/instances/g16-wakeups-*; do [[ $I == */g16-wakeups-1 ]] || break; done
[[ $(cat "$TRB/instances/g16-wakeups-1/tracing_on") == 1 && $(cat "$TRB/instances/g16-wakeups-1/trace") == "other run" ]] &&
  ok "another run's instance is left alone" || bad "the other run's instance was touched"
[[ $rc == 0 ]] && ok "capture and report exit 0" || bad "exit $rc: $out"
en=$(cat "$I"/events/*/*/enable | sort -u | paste -sd' ')
[[ $(cat "$I/tracing_on") == 0 && $en == 0 ]] && ok "tracing and every event are off afterwards" || bad "tracing_on=$(cat "$I/tracing_on") enables=$en"
K=$H/state/stock
[[ -s $K/trace && -s $K/interrupts.0 && -s $K/interrupts.1 && -s $K/topology && -s $K/summary.json ]] && ok "bundle kept" || bad "bundle incomplete: $(ls "$K" 2>&1)"
grep -q 'events=.*power/cpu_idle.*timer/timer_start.*irq/tasklet_entry' "$K/meta" && grep -q 'extra=rcu_nocbs=all' "$K/meta" && grep -q 'power=Discharging' "$K/meta" &&
  ok "meta records events, cmdline extras and power" || bad "meta: $(cat "$K/meta")"

# 2. attribution
R=$T/body.239
[[ -s $R ]] || { bad "nothing posted to #239"; R=/dev/null; }
chk() { grep -qF -- "$2" "$R" && ok "$1" || bad "$1: no '$2' in the report"; }
chk "exit total" "Idle exits by cause: 2/s"
chk "IPI with call site, sender, wakee" "| IPI ttwu_queue_wakelist from chrome waking herdr | 0.5 | 20 % | 0.0 | 0.5 |"
chk "tick exit on Zen 5" "| timer: tick | 0.5 | 20 % | 0.5 | 0.0 |"
chk "task timer with its owner, ahead of the tick that rode along" "| timer: hrtimer_wakeup armed by Hyprland | 0.5 | 20 % | 0.0 | 0.5 |"
chk "device IRQ" "| IRQ mt7925e | 0.5 |"
chk "polling exit" "| none (polling exit, no interrupt) | 0.5 |"
chk "idle ticks: a tick first or second in the waking interrupt both count" "### Idle ticks: 1/s"
chk "tick_stop refusal" "\`tick_stop\` refusals: RCU 0.5/s"
chk "IPI totals, cross-L3 and to-idle shares" "### IPIs: 2/s, 100 % across L3 domains, 33 % to an idle CPU"
chk "waker to wakee pair" "| chrome → herdr | 0.5 |"
chk "TLB shootdown call site" "| flush_tlb_mm_range | 1.0 |"
chk "slack of a task timer" "| hrtimer_wakeup, Hyprland | 0.5 | 50 |"
chk "timer wheel with the arming task" "| process_timeout, herdr | 0.5 |"
chk "tasklet function" "| mt76_irq_tasklet | 0.5 |"
chk "workqueue function" "| usb_giveback_urb_bh | 0.5 |"
chk "queued work with workqueue and task" "| events_bh, usb_giveback_urb_bh, irq context | 0.5 |"
chk "LOC rate split by core type" "| LOC | 800 | 400 | 400 |"
chk "RCU softirq rate" "| RCU | 40 | 20 | 20 |"
chk "cmdline extras in the header" 'cmdline extras `rcu_nocbs=all`'
grep -qF "$H" "$R" && bad "home path in the report" || ok "no home path in the report"
[[ $(cat "$T/posts") == "239 g16-wakeups" ]] && ok "posted once to #239 as g16-wakeups" || bad "posts: $(cat "$T/posts")"

# 3/4. --analyze (no root, other issue) and --compare
rm -f "$T/posts"
out=$(run --analyze "$K" --label nocb --issue 229 2>&1) && [[ $(cat "$T/posts") == "229 g16-wakeups" ]] &&
  ok "--analyze re-reads a bundle and posts to --issue" || bad "--analyze: $out / $(cat "$T/posts" 2>&1)"
[[ -s $H/state/nocb/summary.json ]] && ok "--analyze --label keeps a summary" || bad "no nocb summary"
rm -f "$T/posts"
out=$(run --compare stock nocb --issue 229 --no-post 2>&1)
grep -qF "| idle exits | 2 | 2 | +0 |" <<<"$out" && grep -qF "| LOC | 800 | 800 | +0 |" <<<"$out" &&
  ok "--compare reports B against A" || bad "--compare: $out"
[[ ! -e $T/posts ]] && ok "--no-post posts nothing" || bad "--no-post posted: $(cat "$T/posts")"

# 5. usage and a missing tracefs
run --seconds 0 >/dev/null 2>&1; [[ $? == 2 ]] && ok "--seconds 0 is bad usage" || bad "--seconds 0 accepted"
run --label 'a b' >/dev/null 2>&1; [[ $? == 2 ]] && ok "a label with a space is bad usage" || bad "label with a space accepted"
run --bogus >/dev/null 2>&1; [[ $? == 2 ]] && ok "unknown option is bad usage" || bad "unknown option accepted"
rm -rf "$TRB"
out=$(run --seconds 1 --label broken --no-post 2>&1); rc=$?
[[ $rc == 1 && ! -e $H/state/broken ]] && ok "no tracefs: fails and keeps no bundle" || bad "no tracefs: rc=$rc, $(ls "$H/state" 2>&1)"

((fails == 0)) && echo "all g16-wakeups checks passed" || { echo "$fails check(s) failed"; exit 1; }
