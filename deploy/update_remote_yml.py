#!/usr/bin/env python3
"""Byte-safe version bump of the remote monitor plugin in cordis.patch.yml.
Usage: update_remote_yml.py <old-version> <new-version>"""
import io
import os
import sys

old = sys.argv[1] if len(sys.argv) > 1 else "v23"
new = sys.argv[2] if len(sys.argv) > 2 else "v24"

p = os.path.expanduser("~/.dsh/profiles/web/cordis.patch.yml")
with io.open(p, encoding="utf-8") as f:
    s = f.read()

old_marker = "dsh-remote-monitor-" + old
new_marker = "dsh-remote-monitor-" + new
assert s.count(old_marker) == 1, "%s count: %d" % (old_marker, s.count(old_marker))
s = s.replace(old_marker, new_marker)

with io.open(p, "w", encoding="utf-8", newline="") as f:
    f.write(s)
print(old_marker + " -> " + new_marker)
