#!/bin/bash
# heimdall-chain-nosudo.sh -- bring up the HeIMDALL DAQ chain WITHOUT root.
#
# Upstream's daq_start_sm.sh assumes passwordless sudo. On the Xavier AGX it does
# not exist, so this runs as much of the chain as possible unprivileged, for
# bring-up and measurement:
#
#   rtl_daq.out  |  rebuffer.out  ->  decimate.out  ->  decimator_out shm
#
# What upstream's script does that this does NOT:
#   * sysctl kernel.sched_rt_runtime_us=-1     (needs root; only affects RT throttling)
#   * usbfs_memory_mb=0                        (needs root; see the warning below)
#   * drop_caches                              (needs root; perf only)
#   * chrt -f 99 on every stage                (needs root; priority only)
#   * hw_controller.py                         (needs root for I2C; drives the
#                                               switch matrix / noise source)
#   * delay_sync.py                            (imports skrf + numba, neither of
#                                               which is installed here; without
#                                               it there is NO phase calibration,
#                                               so this chain is NOT coherent)
#
# usbfs_memory_mb is the one that actually matters. libusb caps total transfer
# buffers at 16 MB by default and HeIMDALL raises it to unlimited. With five
# RTL2832U streams that cap is plausibly the cause of
# "Failed to allocate zero-copy buffer" and the intermittent segfaults seen when
# streaming all five tuners through SoapySDR. If this script produces frames,
# the cap is not binding; if rtl_daq dies, that limit is the first suspect:
#
#   sudo sh -c 'echo 0 > /sys/module/usbcore/parameters/usbfs_memory_mb'
#
# Usage: ./heimdall-chain-nosudo.sh [seconds]     default 10
# Env:   CENTRE_MHZ, SAMPLE_RATE_MBPS, NUM_CH override the ini for this run.

set -u

SECS="${1:-10}"
CENTRE_MHZ="${CENTRE_MHZ:-}"
SAMPLE_RATE_MBPS="${SAMPLE_RATE_MBPS:-}"
NUM_CH="${NUM_CH:-}"

HERE=$(cd "$(dirname "$0")" && pwd)
# This script may live in <repo>/scripts or in <repo>/Firmware/scripts; find the
# Firmware tree rather than assuming a fixed depth.
if [ -d "$HERE/../Firmware/_daq_core" ]; then
  FW=$(cd "$HERE/../Firmware" && pwd)
elif [ -d "$HERE/../_daq_core" ]; then
  FW=$(cd "$HERE/.." && pwd)
else
  echo "cannot locate the Firmware tree from $HERE" >&2
  exit 1
fi
CORE="$FW/_daq_core"
CTL="$FW/_data_control"
LOGS="$FW/_logs"

ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
bad()  { printf '\033[31m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
head1() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

cd "$FW" || exit 1

head1 "preflight"
for b in rtl_daq.out rebuffer.out decimate.out; do
  if [ -x "$CORE/$b" ]; then ok "$b"; else bad "$b missing -- run make in _daq_core"; exit 1; fi
done
if [ ! -f "$CORE/libNE10.a" ] && [ ! -f "$FW/../deps/Ne10/build/modules/libNE10.a" ]; then
  warn "libNE10.a not found next to decimate.out (only matters if it is not linked statically)"
fi
usbfs=$(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo '?')
printf '  usbfs_memory_mb = %s (HeIMDALL wants 0/unlimited; needs root)\n' "$usbfs"

head1 "config"
if [ -n "$CENTRE_MHZ" ]; then
  sed -i "s/^center_freq *=.*/center_freq = $(awk -v m="$CENTRE_MHZ" 'BEGIN{printf "%d", m*1e6}')/" daq_chain_config.ini
fi
if [ -n "$SAMPLE_RATE_MBPS" ]; then
  sed -i "s/^sample_rate *=.*/sample_rate = $(awk -v m="$SAMPLE_RATE_MBPS" 'BEGIN{printf "%d", m*1e6}')/" daq_chain_config.ini
fi
if [ -n "$NUM_CH" ]; then
  sed -i "s/^num_ch *=.*/num_ch = $NUM_CH/" daq_chain_config.ini
fi
grep -E "^(center_freq|sample_rate|num_ch|cpi_size|decimation_ratio|daq_buffer_size|out_data_iface_type)" daq_chain_config.ini | sed 's/^/  /'

head1 "FIR coefficients"
python3 fir_filter_designer.py > /tmp/fir.log 2>&1
if [ $? -ne 0 ]; then bad "fir_filter_designer.py failed:"; tail -5 /tmp/fir.log; exit 1; fi
ok "generated _data_control/fir_coeffs.txt"

head1 "control FIFOs"
mkdir -p "$CTL" "$LOGS"
for f in fw_decimator_in bw_decimator_in fw_decimator_out bw_decimator_out; do
  rm -f "$CTL/$f"; mkfifo "$CTL/$f"
done
ok "fifos created"

head1 "starting chain"
PREFIX="${KRAKEN_LIB_PREFIX:-$HOME/projects/KrakenSDR/krakensdr/deps/prefix}"
export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
printf '  LD_LIBRARY_PATH=%s\n' "$PREFIX/lib"

# rtl_daq writes frames to stdout, rebuffer consumes them. Keep that pipe intact.
( "$CORE/rtl_daq.out" 2> "$LOGS/rtl_daq.log" | "$CORE/rebuffer.out" 0 2> "$LOGS/rebuffer.log" ) &
CHAIN_PID=$!
( "$CORE/decimate.out" 2> "$LOGS/decimator.log" ) &
DEC_PID=$!

cleanup() {
  kill "$DEC_PID" "$CHAIN_PID" 2>/dev/null
  # -x (exact process name), NOT -f: with -f the pattern also matches the shell
  # that is running this script, so cleanup kills its own caller.
  pkill -x rtl_daq.out 2>/dev/null
  pkill -x rebuffer.out 2>/dev/null
  pkill -x decimate.out 2>/dev/null
}
trap cleanup EXIT INT TERM

head1 "observing for ${SECS}s"
for i in $(seq 1 "$SECS"); do
  sleep 1
  if ! kill -0 "$CHAIN_PID" 2>/dev/null; then warn "rtl_daq|rebuffer exited after ${i}s"; break; fi
done

head1 "shared memory segments"
if ls /dev/shm 2>/dev/null | grep -qiE "decimator|delay_sync|HEIMDALL"; then
  ls -l /dev/shm | grep -iE "decimator|delay_sync|HEIMDALL" | sed 's/^/  /'
  ok "HeIMDALL is publishing IQ frame buffers"
else
  bad "no HeIMDALL shared memory segments in /dev/shm"
  ls /dev/shm 2>/dev/null | head -10 | sed 's/^/  /'
fi

# A buffer existing does not prove it is being fed. Sample the same bytes twice
# a few seconds apart: if the digest changes, frames are actually arriving.
head1 "consuming decimator_out"
# The chain back-pressures on its own: decimate.out fills decimator_out_A and _B
# and then stalls, which stalls rebuffer and rtl_daq. So a consumer is REQUIRED
# before any data can move - "nothing is flowing" on its own proves nothing.
if [ ! -x "$CORE/daq_consumer.out" ] || [ "$CORE/daq_consumer.c" -nt "$CORE/daq_consumer.out" ]; then
  printf '  building daq_consumer.out ...\n'
  ( cd "$CORE" && gcc -Wall -std=gnu99 -O2 -I. -o daq_consumer.out daq_consumer.c \
      sh_mem_util.o iq_header.o log.o ini.o -lrt -lm ) >/tmp/consumer-build.log 2>&1
  if [ ! -x "$CORE/daq_consumer.out" ]; then
    bad "daq_consumer.out failed to build:"; tail -5 /tmp/consumer-build.log; CONSUMER_RC=1
  fi
fi
CONSUMER_RC=1
if [ -x "$CORE/daq_consumer.out" ]; then
  ( cd "$FW" && timeout 40 "$CORE/daq_consumer.out" "${FRAMES:-5}" ) 2>&1 | sed 's/^/  /'
  CONSUMER_RC=${PIPESTATUS[0]}
fi

head1 "logs"
for l in rtl_daq rebuffer decimator; do
  printf -- '--- %s ---\n' "$l"
  tail -6 "$LOGS/$l.log" 2>/dev/null | sed 's/^/  /' || echo "  (no log)"
done

head1 "verdict"
if grep -q "Failed to submit transfer" "$LOGS/rtl_daq.log" 2>/dev/null; then
  bad "libusb is refusing to submit USB transfers"
  printf '  The buffers exist but NOTHING is flowing: this is the usbfs cap.\n'
  printf '  Total libusb transfer buffers are limited to %s MB; five RTL2832U\n' "$usbfs"
  printf '  streams need more. HeIMDALL raises it to unlimited and that needs root:\n\n'
  printf "    sudo sh -c 'echo 0 > /sys/module/usbcore/parameters/usbfs_memory_mb'\n\n"
  printf '  This is the same limit that made five concurrent SoapySDR streams\n'
  printf '  fail with "Failed to allocate zero-copy buffer".\n'
  exit 1
fi
if [ "${CONSUMER_RC:-1}" -eq 0 ]; then
  ok "DAQ chain is producing and moving IQ frames"
  printf '\n  NOTE: this is NOT coherent. delay_sync.py did not run (needs skrf +\n'
  printf '  numba), so no phase calibration has been applied and no delay_sync_iq\n'
  printf '  buffer exists. It is enough to prove the acquisition chain works here.\n'
  exit 0
fi
bad "chain did not move any IQ data"
printf '  If rtl_daq.log shows libusb allocation failures, raise:\n'
exit 1
