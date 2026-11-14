#!/usr/bin/env python3
"""Runs in a Terminal window for the Smooth Scrolling E2E checks: turns on
mouse reporting on the alternate screen - what tmux, vim (mouse=a) and htop
do - and counts the wheel reports Terminal sends for <seconds>.

  ttywheel.py <out-file> <seconds>

Touches <out-file>.ready once listening; writes "up=<n> down=<n>" to
<out-file> at the end.
"""
import os, re, select, sys, termios, time, tty

out, seconds = sys.argv[1], float(sys.argv[2])
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
tty.setraw(fd)
sys.stdout.write("\x1b[?1049h\x1b[2J\x1b[H\x1b[?1000h\x1b[?1006hcounting wheel reports\r\n")
sys.stdout.flush()
open(out + ".ready", "w").close()
data, end = b"", time.time() + seconds
while time.time() < end:
    if select.select([fd], [], [], 0.1)[0]:
        data += os.read(fd, 4096)
sys.stdout.write("\x1b[?1000l\x1b[?1006l\x1b[?1049l")
sys.stdout.flush()
termios.tcsetattr(fd, termios.TCSADRAIN, saved)
reports = re.findall(rb"\x1b\[<(6[45]);", data)
with open(out, "w") as f:
    f.write(f"up={reports.count(b'64')} down={reports.count(b'65')}\n")
