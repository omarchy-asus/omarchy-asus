"""A fake hidraw node for winlockd.test.sh: a raw pty whose slave is linked at
argv[1]. Hex lines on stdin are written to the master, padded to 64 bytes so each
read(64) gets one report as from hidraw (reports the daemon reads);
whatever the daemon writes (the 01 01 commit) is appended to argv[2] as hex."""
import os, select, sys, tty

master, slave = os.openpty()
tty.setraw(slave)
os.symlink(os.ttyname(slave), sys.argv[1])
# slave stays open here too, so the master never reads EIO between daemons
print("ready", flush=True)
pending = b""
while True:
    ready, _, _ = select.select([0, master], [], [])
    if 0 in ready:  # os.read, not readline: a buffered line would never wake select
        chunk = os.read(0, 4096)
        if not chunk:
            break
        *lines, pending = (pending + chunk).split(b"\n")
        for line in lines:
            os.write(master, bytes.fromhex(line.decode()).ljust(64, b"\0"))
    if master in ready:
        data = os.read(master, 64)
        with open(sys.argv[2], "a") as f:
            f.write(data.hex(" ") + "\n")
