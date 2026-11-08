#!/bin/bash
# build-deps-ne10.sh -- build NE10 for aarch64 and place libNE10.a for the Makefile.
#
# HeIMDALL's Makefile selects the ARM-NEON decimator on any non-x86_64 host and
# links "-L. -lNE10", but only NE10 *headers* are vendored in _daq_core -- the
# library is not. Upstream's BringUpInstructions say to build NE10 with
# NE10_LINUX_TARGET_ARCH=aarch64, but NE10's top-level CMakeLists then refuses:
#
#   CMake Error at CMakeLists.txt:191 (message):
#     You are trying to compile for non-ARM (CMAKE_SYSTEM_PROCESSOR='aarch64')!
#
# because its guard matches CMAKE_SYSTEM_PROCESSOR against "^arm" and "aarch64"
# does not match. -DCMAKE_SYSTEM_PROCESSOR=armv8 does not help: CMake re-derives
# that variable from uname in CMakeDetermineSystem, after the -D.
#
# So this clones NE10, widens the guard, builds for aarch64 and copies
# libNE10.a next to decimate.out.
#
# Usage: ./build-deps-ne10.sh
# Exit 0 on success.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
if [ -d "$HERE/../Firmware/_daq_core" ]; then
  FW=$(cd "$HERE/../Firmware" && pwd)
elif [ -d "$HERE/../_daq_core" ]; then
  FW=$(cd "$HERE/.." && pwd)
else
  echo "cannot locate the Firmware tree from $HERE" >&2
  exit 1
fi
DEPS="$(cd "$FW/.." && pwd)/deps"
NE10="$DEPS/Ne10"
CORE="$FW/_daq_core"

ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
bad()  { printf '\033[31m%s\033[0m\n' "$*"; }
head1() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

arch=$(uname -m)
head1 "target"
printf '  host arch : %s\n' "$arch"
printf '  NE10 src  : %s\n' "$NE10"
printf '  install to: %s\n' "$CORE"

if [ "$arch" = "x86_64" ]; then
  bad "x86_64 does not need NE10 -- the Makefile uses the KFR decimator instead."
  printf '  You need libkfr_capi (see BringUpInstructions.txt section 4-X86).\n'
  exit 1
fi

head1 "fetch"
mkdir -p "$DEPS"
if [ -d "$NE10/.git" ]; then
  ok "already cloned"
else
  git clone --depth 1 https://github.com/projectNe10/Ne10 "$NE10" > /tmp/ne10-clone.log 2>&1 \
    || { bad "clone failed, see /tmp/ne10-clone.log"; exit 1; }
  ok "cloned"
fi

head1 "patch aarch64 guard"
python3 "$HERE/patch-ne10-aarch64.py" "$NE10" || { bad "patch failed"; exit 1; }

head1 "build"
mkdir -p "$NE10/build"
cd "$NE10/build" || exit 1
NE10_LINUX_TARGET_ARCH=aarch64 cmake -DGNULINUX_PLATFORM=ON \
    -DNE10_BUILD_EXAMPLES=OFF -DNE10_BUILD_UNIT_TEST=OFF .. > /tmp/ne10-cmake.log 2>&1 \
  || { bad "cmake failed:"; tail -8 /tmp/ne10-cmake.log; exit 1; }
make -j"$(nproc 2>/dev/null || echo 2)" > /tmp/ne10-make.log 2>&1 \
  || { bad "make failed:"; tail -8 /tmp/ne10-make.log; exit 1; }
ok "built"

head1 "install"
if [ ! -f modules/libNE10.a ]; then
  bad "modules/libNE10.a not produced"; exit 1
fi
cp modules/libNE10.a "$CORE/" || { bad "copy failed"; exit 1; }
ok "libNE10.a -> $CORE/libNE10.a"

head1 "verify"
if nm "$CORE/libNE10.a" 2>/dev/null | grep -q "T ne10_fir_decimate_init_float"; then
  ok "ne10_fir_decimate_init_float present (this is all HeIMDALL uses)"
else
  bad "ne10_fir_decimate_init_float missing -- wrong module set built?"
  exit 1
fi
printf '\n  Now build the DAQ binaries serially (the Makefile races under -j):\n'
printf '    cd %s && make\n' "$CORE"
exit 0
