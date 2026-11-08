#!/usr/bin/env python3
"""Patch NE10's CMakeLists so it accepts aarch64 as an ARM target.

NE10's own source supports aarch64 -- modules/CMakeLists.txt and the DSP module
build for it fine -- but the fail-fast guard in the top-level CMakeLists only
matches CMAKE_SYSTEM_PROCESSOR "^arm", which rejects "aarch64". HeIMDALL's
BringUpInstructions tell you to build NE10 with NE10_LINUX_TARGET_ARCH=aarch64,
so the guard contradicts the documented build.

Passing -DCMAKE_SYSTEM_PROCESSOR=armv8 does not help: CMake re-derives
CMAKE_SYSTEM_PROCESSOR from uname in CMakeDetermineSystem, after the -D.

Usage: ./patch-ne10-aarch64.py [path/to/Ne10]
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "."

p = path.rstrip("/") + "/CMakeLists.txt"
src = open(p).read()

old = 'if(GNULINUX_PLATFORM AND (NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^arm"))'
new = 'if(GNULINUX_PLATFORM AND (NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm|aarch64)"))'

if new in src:
    print("already patched")
    sys.exit(0)

n = src.count(old)
if n != 1:
    sys.exit("expected exactly 1 occurrence of the guard, found %d" % n)

open(p, "w").write(src.replace(old, new, 1))
print("patched: NE10 now accepts aarch64 as an ARM target (%s)" % p)
