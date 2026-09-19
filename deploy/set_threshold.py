#!/usr/bin/env python3
"""Set the remote monitor plugin's autoCompactThreshold (old, new)."""
import io
import os
import sys

old = sys.argv[1] if len(sys.argv) > 1 else "0.8"
new = sys.argv[2] if len(sys.argv) > 2 else "0.8"

p = os.path.expanduser("~/.dsh/profiles/web/cordis.patch.yml")
with io.open(p, encoding="utf-8") as f:
    s = f.read()

old_line = "        autoCompactThreshold: " + old
new_line = "        autoCompactThreshold: " + new
assert s.count(old_line) == 1, "threshold line count: %d" % s.count(old_line)
s = s.replace(old_line, new_line)

with io.open(p, "w", encoding="utf-8", newline="") as f:
    f.write(s)
print("threshold " + old + " -> " + new)
