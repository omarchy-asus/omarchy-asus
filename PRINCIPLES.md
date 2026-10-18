# Principles

How omarchy-asus works. Short on purpose.

**Rule 1:** Help make the software better.

**Rule 2:** Don't be a dick.

Everything else follows from those two.

1. **Just works.** Install Omarchy on an ASUS laptop and everything works: keyboard, GPU,
   sleep, power, displays. Anything less is a bug, and every bug can be fixed.

2. **Upstream first.** Every patch here is a pull request waiting to happen. Write fixes the
   way Omarchy, the kernel, NVIDIA or Hyprland would write them, and send them there.

3. **Smaller is better.** Success is deleting our deltas as upstream releases them. The best
   version of this repo is an empty one.

4. **A fallback beats a stale pin.** If we can't keep a package current, we withdraw it and
   stock flows through. Nobody gets stuck on an old build because we fell behind.

5. **No behaviour change without a reason.** Ship the fix, not our preferences. Anything
   experimental is off by default and labelled as experimental.

6. **Tested on real hardware.** A fix is done when it works on the laptop it's for. Say which
   model you tested and what you checked. Say so plainly when it hasn't been tested.

7. **Honest status.** Say what ships, what's in progress and what's broken. No overclaiming.

8. **Public by default, private data never.** Work happens in the open. Hostnames, paths,
   serials and other personal data stay out of issues, commits and logs.

9. **Everyone is welcome.** The work is judged on the work. Reports, fixes, testing and
   ideas all count.
