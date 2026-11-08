#!/bin/bash
# sudo-daq-run.sh -- raise the libusb limit and run the HeIMDALL DAQ chain as root,
#                    collecting everything into one log bundle.
#
# WHY THIS NEEDS ROOT
#   libusb caps the total size of the transfer buffers one process may allocate
#   (usbfs_memory_mb, default 16 MB). HeIMDALL needs it unlimited. With five
#   RTL2832U streams the cap is hit and rtl_daq logs
#       Failed to submit transfer N
#       Please increase your allowed usbfs buffer size ...
#   and no IQ data moves. One channel fits inside 16 MB; five do not.
#
# USAGE
#   sudo ./scripts/sudo-daq-run.sh                 # 5 channels, sensible defaults
#   sudo NUM_CH=1 ./scripts/sudo-daq-run.sh        # single channel
#   sudo CENTRE_MHZ=868.3 FRAMES=10 ./scripts/sudo-daq-run.sh
#   sudo RESTORE_USBFS=1 ./scripts/sudo-daq-run.sh  # put usbfs_memory_mb back to 16
#
# ENVIRONMENT
#   CENTRE_MHZ      centre frequency, default 868.3  (European OGN)
#   SAMPLE_RATE_MBPS sample rate in Msps, default 1.024
#   NUM_CH          channels, default 5
#   GAIN            tuner gain, tenths of dB, default 400 (40.0 dB). 0 gives nothing useful.
#   FRAMES          IQ frames to consume, default 8
#   SETTLE          seconds to let the chain fill buffers before consuming, default 6
#   CPI_SIZE        samples per frame, default 1048576
#   RUN_HWC         1 to start hw_controller.py, default 1. REQUIRED for coherence:
#                   delay_sync.py blocks on wait_buff_free() of the delay_sync_hwc
#                   channel, so it makes no progress unless hw_controller consumes it.
#   PYTHON          interpreter for the Python stages. Auto-detected otherwise; it
#                   must be able to import skrf AND numba.
#   RESTORE_USBFS   1 to set usbfs_memory_mb back to 16 when finished, default 0
#   USE_RT          0 = normal priority (default), 1 = chrt -f 99. The run that
#                   first delivered frames used no chrt; the one that died in
#                   rebuffer used chrt -f 99 with sched_rt_runtime_us=-1.
#   CONSUMER_TIMEOUT  seconds before the frame reader is killed, default 120
#
# The script writes a bundle the caller can hand over verbatim:
#   $OUT/run.log, summary.txt, logs/*.log, config/, lsusb.txt, shm-listing.txt ...
# It chowns the bundle to the invoking user so it is readable WITHOUT root.

set -u

# ---------------------------------------------------------------- must be root
if [ "$(id -u)" -ne 0 ]; then
  echo "This needs root (it changes a kernel parameter)." >&2
  echo "  sudo $0 $*" >&2
  exit 1
fi

CALLER="${SUDO_USER:-}"
CALLER_HOME="$HOME"
[ -n "$CALLER" ] && CALLER_HOME="/home/$CALLER"
[ "$CALLER" = "root" ] && CALLER=""

CENTRE_MHZ="${CENTRE_MHZ:-868.3}"
SAMPLE_RATE_MBPS="${SAMPLE_RATE_MBPS:-1.024}"
NUM_CH="${NUM_CH:-5}"
GAIN="${GAIN:-400}"
FRAMES="${FRAMES:-8}"
SETTLE="${SETTLE:-6}"
CPI_SIZE="${CPI_SIZE:-1048576}"
RUN_HWC="${RUN_HWC:-1}"
RESTORE_USBFS="${RESTORE_USBFS:-0}"
USE_RT="${USE_RT:-0}"
CONSUMER_TIMEOUT="${CONSUMER_TIMEOUT:-120}"

# ------------------------------------------------------------ locate the tree
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -d "$HERE/../Firmware/_daq_core" ]; then
  FW=$(cd "$HERE/../Firmware" && pwd)
elif [ -d "$HERE/../_daq_core" ]; then
  FW=$(cd "$HERE/.." && pwd)
else
  echo "cannot locate the Firmware tree from $HERE" >&2
  exit 1
fi
ROOT=$(cd "$FW/.." && pwd)
CORE="$FW/_daq_core"
CTL="$FW/_data_control"
LOGS="$FW/_logs"
PREFIX="${KRAKEN_LIB_PREFIX:-$HOME/projects/KrakenSDR/krakensdr/deps/prefix}"
[ -n "$CALLER" ] && PREFIX="${KRAKEN_LIB_PREFIX:-/home/$CALLER/projects/KrakenSDR/krakensdr/deps/prefix}"

# --------------------------------------------------------------- interpreter
# delay_sync.py needs skrf AND numba; the system python3 has neither, and upstream
# resorts to conda for exactly this reason. Prefer any interpreter that has both,
# so the coherent stages run instead of being skipped.
pick_python() {
  local c
  for c in ${PYTHON:-} \
           "$CALLER_HOME/miniforge3/envs/kraken/bin/python3" \
           "$CALLER_HOME/miniconda3/envs/kraken/bin/python3" \
           "$CALLER_HOME/miniforge3/bin/python3" \
           "$CALLER_HOME/miniconda3/bin/python3" \
           /usr/bin/python3; do
    [ -n "$c" ] || continue
    [ -x "$c" ] || continue
    if "$c" -c "import skrf, numba" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}
PY=""
if PY=$(pick_python); then
  PY_DEPS=1
else
  PY=/usr/bin/python3
  PY_DEPS=0
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/logs/run-$STAMP"
mkdir -p "$OUT/logs" "$OUT/config"
LOG="$OUT/run.log"

# ------------------------------------------------------------------- plumbing
step() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
bad()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }

# Everything below goes to both the screen and the log file.
exec > >(tee -a "$LOG") 2>&1

echo "HeIMDALL DAQ run"
echo "  started  : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  caller   : ${CALLER:-root}"
echo "  tree     : $ROOT"
echo "  bundle   : $OUT"
echo "  python   : $PY (skrf+numba: $([ "$PY_DEPS" = 1 ] && echo yes || echo NO))"

# ------------------------------------------------------------- record the box
step "host"
{
  echo "uname    : $(uname -srm)"
  echo "distro   : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  echo "l4t      : $(head -1 /etc/nv_tegra_release 2>/dev/null || echo '-')"
  echo "nproc    : $(nproc 2>/dev/null || echo '?')"
  echo "uptime   : $(uptime)"
  echo "kernel usbfs_memory_mb (before): $(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo '?')"
} | tee "$OUT/summary.txt" | sed 's/^/  /'

lsusb > "$OUT/lsusb.txt" 2>&1
info "lsusb saved ($(grep -c '0bda:2838' "$OUT/lsusb.txt" 2>/dev/null || echo 0) RTL2838 chains)"

# ------------------------------------------------------------- raise the limit
step "raise libusb buffer limit"
before=$(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo '?')
if echo 0 > /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null; then
  after=$(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo '?')
  if [ "$after" = "0" ]; then
    ok "usbfs_memory_mb: $before -> 0 (unlimited)"
  else
    bad "wrote 0 but reads back '$after'"; exit 1
  fi
else
  bad "could not write /sys/module/usbcore/parameters/usbfs_memory_mb"; exit 1
fi
echo "kernel usbfs_memory_mb (after): 0" >> "$OUT/summary.txt"

# ---------------------------------------------------------------------------
# Clear stale state. A previous run that died (or was killed) leaves /dev/shm
# objects and FIFOs behind, and the next run then fails in confusing ways -
# rebuffer reports "Shared memory initialization failed" with no error code.
# This is the first thing to suspect when a run that worked yesterday fails.
# ---------------------------------------------------------------------------
step "clear stale state"
for p in rtl_daq.out rebuffer.out decimate.out daq_consumer.out; do
  if pgrep -x "$p" >/dev/null 2>&1; then
    warn "killing leftover $p"
    pkill -x "$p" 2>/dev/null
  fi
done
pkill -f delay_sync.py 2>/dev/null
pkill -f hw_controller.py 2>/dev/null
sleep 1
removed=0
for obj in /dev/shm/decimator_in_A /dev/shm/decimator_in_B \
           /dev/shm/decimator_out_A /dev/shm/decimator_out_B \
           /dev/shm/delay_sync_iq_A /dev/shm/delay_sync_iq_B \
           /dev/shm/delay_sync_hwc_A /dev/shm/delay_sync_hwc_B \
           /dev/shm/HEIMDALL_DAQ_FW_GEN_STD_FRAME_A /dev/shm/HEIMDALL_DAQ_FW_GEN_STD_FRAME_B; do
  [ -e "$obj" ] && { rm -f "$obj" && removed=$((removed+1)); }
done
if [ "$removed" -gt 0 ]; then ok "removed $removed stale /dev/shm object(s)"
else ok "no stale /dev/shm objects"; fi
# Verify, do not assume. sh_mem_util's producer opens with O_RDWR and, if that
# fails (e.g. an object left by another user), init returns a small negative code
# that upstream never prints - the only symptom is
#   FATAL rebuffer.c:173: Shared memory initialization failed
leftover=$(ls /dev/shm 2>/dev/null | grep -iE '^(decimator|delay_sync|HEIMDALL)')
if [ -n "$leftover" ]; then
  bad "shared memory objects could not be removed:"
  printf '%s\n' "$leftover" | sed 's/^/     /'
  info "These belong to another user and will make rebuffer fail. Remove them:"
  info "  sudo rm -f /dev/shm/decimator_* /dev/shm/delay_sync_* /dev/shm/HEIMDALL_DAQ_FW_*"
  exit 1
fi
ok "no shared memory objects left behind"

# shared memory capacity: decimator_out is large
shm_avail=$(df -Pm /dev/shm 2>/dev/null | awk 'NR==2{print $4}')
need_mb=$(( (8388608 * NUM_CH * 4 * 2 * 2) / 1048576 ))
if [ -n "$shm_avail" ] && [ "$shm_avail" -lt "$need_mb" ]; then
  bad "/dev/shm has ${shm_avail} MB free, ${need_mb} MB needed for NUM_CH=$NUM_CH"
  info "raise it with: mount -o remount,size=2G /dev/shm"
  exit 1
fi
ok "/dev/shm free: ${shm_avail:-?} MB (need ~${need_mb} MB)"

# Upstream does these too; they are optional for us but cheap and make the run
# behave like the reference configuration.
sysctl -w kernel.sched_rt_runtime_us=-1 >/dev/null 2>&1 && ok "sched_rt_runtime_us = -1"
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && ok "caches dropped"

# ---------------------------------------------------------------- preflight
step "preflight"
rc=0
for b in rtl_daq.out rebuffer.out decimate.out; do
  if [ -x "$CORE/$b" ]; then ok "$b"; else bad "$b missing -- build _daq_core first"; rc=1; fi
done
if [ ! -f "$CORE/libNE10.a" ]; then warn "libNE10.a not next to decimate.out"; fi
if [ ! -e "$PREFIX/lib/librtlsdr.so.0" ]; then
  bad "krakenrf librtlsdr fork not found at $PREFIX/lib"
  info "build it with thread3d/KrakenSDR scripts/build-deps.sh"
  rc=1
fi
[ "$rc" -ne 0 ] && { bad "preflight failed"; exit 1; }
ok "librtlsdr fork: $PREFIX/lib"

if true; then   # always rebuild: a stale binary once cost a whole run
  info "building daq_consumer.out"
  ( cd "$CORE" && gcc -Wall -std=gnu99 -O2 -I. -o daq_consumer.out daq_consumer.c \
      sh_mem_util.o iq_header.o log.o ini.o -lrt -lm ) > "$OUT/logs/consumer-build.log" 2>&1
  if [ -x "$CORE/daq_consumer.out" ]; then ok "daq_consumer.out built"
  else bad "daq_consumer.out build failed -- see logs/consumer-build.log"; exit 1; fi
fi

# ------------------------------------------------------------- configure
step "configure"
cp "$FW/daq_chain_config.ini" "$OUT/config/daq_chain_config.ini.before"
sed -i \
  -e "s/^center_freq *=.*/center_freq = $(awk -v m="$CENTRE_MHZ" 'BEGIN{printf "%d", m*1e6}')/" \
  -e "s/^sample_rate *=.*/sample_rate = $(awk -v m="$SAMPLE_RATE_MBPS" 'BEGIN{printf "%d", m*1e6}')/" \
  -e "s/^num_ch *=.*/num_ch = $NUM_CH/" \
  -e "s/^gain *=.*/gain = $GAIN/" \
  -e "s/^cpi_size *=.*/cpi_size = $CPI_SIZE/" \
  "$FW/daq_chain_config.ini"
grep -E "^(num_ch|center_freq|sample_rate|gain|cpi_size|decimation_ratio|daq_buffer_size|en_noise_source_ctr|ctr_channel_serial_no|out_data_iface_type)" \
  "$FW/daq_chain_config.ini" | sed 's/^/  /'
cp "$FW/daq_chain_config.ini" "$OUT/config/daq_chain_config.ini.used"

cd "$FW" || exit 1
"$PY" fir_filter_designer.py > "$OUT/logs/fir_design.log" 2>&1
if [ $? -ne 0 ]; then bad "fir_filter_designer.py failed"; tail -5 "$OUT/logs/fir_design.log"; exit 1; fi
ok "FIR coefficients regenerated"

# ------------------------------------------------------------------ cleanup
PIDS=""
cleanup() {
  step "stopping"
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  sleep 1
  # -x, not -f: with -f the patterns also match the shell running this script.
  pkill -x rtl_daq.out 2>/dev/null
  pkill -x rebuffer.out 2>/dev/null
  pkill -x decimate.out 2>/dev/null
  pkill -x daq_consumer.out 2>/dev/null
  ok "stopped"
  cp "$OUT/config/daq_chain_config.ini.before" "$FW/daq_chain_config.ini" 2>/dev/null \
    && ok "config restored"
  if [ "$RESTORE_USBFS" = "1" ]; then
    echo 16 > /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null \
      && ok "usbfs_memory_mb restored to 16"
  else
    info "usbfs_memory_mb left at 0 (set RESTORE_USBFS=1 to put it back)"
  fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------ control FIFOs
step "control FIFOs"
mkdir -p "$CTL" "$LOGS" || { bad "cannot create $CTL"; exit 1; }
fifo_fail=0
for f in fw_decimator_in bw_decimator_in fw_decimator_out bw_decimator_out \
         fw_delay_sync_iq bw_delay_sync_iq fw_delay_sync_hwc bw_delay_sync_hwc; do
  rm -f "$CTL/$f"
  if ! mkfifo "$CTL/$f" 2>/dev/null; then
    bad "mkfifo $CTL/$f failed"; fifo_fail=1
  elif [ ! -p "$CTL/$f" ]; then
    bad "$CTL/$f is not a FIFO"; fifo_fail=1
  fi
done
if [ "$fifo_fail" -ne 0 ]; then
  bad "FIFO setup failed -- the chain cannot start"
  exit 1
fi
ok "8 FIFOs created in $CTL"
: > "$LOGS/rtl_daq.log" 2>/dev/null

export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
CHRT=""
if [ "$USE_RT" = "1" ] && command -v chrt >/dev/null 2>&1; then
  CHRT="chrt -f 99"
fi

# ------------------------------------------------------------------- run it
step "starting DAQ chain"
info "LD_LIBRARY_PATH=$PREFIX/lib"
if [ -n "$CHRT" ]; then
  info "real-time priority: chrt -f 99"
elif [ "$USE_RT" = "1" ]; then
  warn "USE_RT=1 but chrt is not installed -- running at normal priority"
else
  info "real-time priority: off (USE_RT=1 to enable)"
fi

$CHRT "$CORE/rtl_daq.out" 2> "$OUT/logs/rtl_daq.log" | \
$CHRT "$CORE/rebuffer.out" 0 2> "$OUT/logs/rebuffer.log" &
PIDS="$PIDS $!"

$CHRT "$CORE/decimate.out" 2> "$OUT/logs/decimator.log" &
PIDS="$PIDS $!"

sleep 2

# hw_controller drives the switch matrix / noise source over I2C. Non-fatal.
if [ "$RUN_HWC" = "1" ]; then
  # hw_controller is a __main__ script (importing it RUNS it), so start it and
  # judge success from whether it is still alive, not from an import test.
  # It is required for coherence: delay_sync blocks on wait_buff_free() of the
  # delay_sync_hwc channel until something consumes it.
  $CHRT "$PY" _daq_core/hw_controller.py > "$OUT/logs/hw_controller.log" 2>&1 &
  HWC_PID=$!
  PIDS="$PIDS $HWC_PID"
  sleep 2
  if kill -0 "$HWC_PID" 2>/dev/null; then
    ok "hw_controller.py running"
  else
    warn "hw_controller.py exited -- see logs/hw_controller.log"
    tail -5 "$OUT/logs/hw_controller.log" 2>/dev/null | sed 's/^/     /'
  fi
fi

# delay_sync gives coherence. It needs skrf + numba.
COHERENT=0
if [ "$PY_DEPS" = "1" ]; then
  $CHRT "$PY" _daq_core/delay_sync.py > "$OUT/logs/delay_sync.log" 2>&1 &
  PIDS="$PIDS $!"
  ok "delay_sync.py started -- this run IS coherent"
  COHERENT=1
else
  warn "delay_sync.py skipped: no interpreter with skrf + numba (set PYTHON=...)"
  info "--> no phase calibration; DoA is not possible in this run"
fi

# --------------------------------------------------------------- reader
# Start it IMMEDIATELY, not as a step after the settle. Python's outShmemIface
# opens fw_<stage> for WRITE, which blocks until a downstream reader appears, and
# delay_sync cannot create delay_sync_hwc (which hw_controller needs) until it
# gets past that open. So with no reader nothing bootstraps: delay_sync and
# hw_controller both sit blocked and it looks like a silent hang.
if [ "$COHERENT" -eq 1 ]; then
  CONSUMER_STAGE="delay_sync_iq"
  info "reader will take delay_sync_iq (delay_sync owns decimator_out)"
else
  CONSUMER_STAGE="decimator_out"
fi
timeout "$CONSUMER_TIMEOUT" "$CORE/daq_consumer.out" "$FRAMES" "$CONSUMER_STAGE" \
    > "$OUT/logs/consumer.log" 2>&1 &
CONSUMER_PID=$!
ok "reader started on $CONSUMER_STAGE (pid $CONSUMER_PID)"

info "checking every stage is alive"
sleep 3
alive=1
for p in rtl_daq.out rebuffer.out decimate.out; do
  if pgrep -x "$p" >/dev/null 2>&1; then
    ok "$p running"
  else
    bad "$p is NOT running"
    alive=0
  fi
done
# The Python stages are newer here and more likely to fall over: numba compiles
# on first run, and delay_sync blocks forever if hw_controller is not consuming
# its delay_sync_hwc channel.
if pgrep -f "_daq_core/hw_controller.py" >/dev/null 2>&1; then
  ok "hw_controller.py running"
elif [ "$RUN_HWC" = "1" ]; then
  bad "hw_controller.py NOT running (delay_sync will block without it)"
  tail -8 "$OUT/logs/hw_controller.log" 2>/dev/null | sed 's/^/     /'
  alive=0
fi
if pgrep -f "_daq_core/delay_sync.py" >/dev/null 2>&1; then
  ok "delay_sync.py running"
elif [ "$PY_DEPS" = "1" ]; then
  bad "delay_sync.py exited"
  tail -12 "$OUT/logs/delay_sync.log" 2>/dev/null | sed 's/^/     /'
  alive=0
fi
if [ "$alive" -ne 1 ]; then
  step "stage logs (this is where the answer is)"
  for l in rtl_daq rebuffer decimator; do
    printf -- '--- %s ---\n' "$l"
    cat "$OUT/logs/$l.log" 2>/dev/null | tail -15 | sed 's/^/  /'
  done
  echo
  # init_out_sm_buffer / init_in_sm_buffer return a small negative code that
  # upstream does not print, so dump everything that decides it: the FIFOs and
  # shm objects it needs must exist, at the paths it resolves from its CWD.
  step "diagnostics"
  printf 'cwd            : %s\n' "$PWD"
  printf 'fifo dir       : %s\n' "$CTL"
  ls -l "$CTL" 2>/dev/null | sed 's/^/  /'
  echo "  --- /dev/shm ---"
  ls -l /dev/shm 2>/dev/null | grep -iE "decimator|delay|HEIMDALL" | sed 's/^/  /'
  echo "  --- /dev/shm free ---"
  df -Pm /dev/shm 2>/dev/null | sed 's/^/  /'
  echo "  --- what each side will ask for ---"
  printf '  rebuffer  out buffer: cpi_size*num_ch*2+1024 = %d bytes\n' $((CPI_SIZE*NUM_CH*2+1024))
  printf '  decimate  in  buffer: cpi_size*num_ch*dec*4*2+1024 = %d bytes\n' $((CPI_SIZE*NUM_CH*1*4*2+1024))
  echo
  info "If 'FIFO dir' is empty the mkfifo step silently failed."
  info "If shm objects are owned by another user, remove them and retry."
  echo
  info "rebuffer 'Shared memory initialization failed' with no detail generally"
  info "means a leftover /dev/shm object from an earlier run - this script now"
  info "clears those, so if it persists check 'ls -l /dev/shm | grep -i decimator'"
  info "for objects owned by a different user."
  cp "$OUT/config/daq_chain_config.ini.before" "$FW/daq_chain_config.ini" 2>/dev/null
  exit 1
fi

info "letting the chain settle for ${SETTLE}s"
sleep "$SETTLE"

# --------------------------------------------------------------- consume
step "reading $CONSUMER_STAGE"
# The reader is not a convenience: the chain back-pressures on itself, and with a
# coherent stage the reader is also what unblocks delay_sync's bootstrap.
info "waiting for the reader to collect ${FRAMES} frame(s)"
wait "$CONSUMER_PID" 2>/dev/null
CONSUMER_RC=$?
if [ "$CONSUMER_RC" -eq 124 ]; then
  warn "consumer timed out after ${CONSUMER_TIMEOUT}s waiting for frames"
fi
sed 's/^/  /' "$OUT/logs/consumer.log"

ls -l /dev/shm 2>/dev/null | grep -iE "decimator|delay_sync|HEIMDALL" > "$OUT/shm-listing.txt" 2>&1
dmesg 2>/dev/null | tail -40 > "$OUT/dmesg-tail.txt"

# ----------------------------------------------------------------- verdict
step "verdict"
count() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); [ -z "$n" ] && n=0; echo "$n"; }
frames_read=$(count "^frame " "$OUT/logs/consumer.log")
usb_fail=$(count "Failed to submit transfer" "$OUT/logs/rtl_daq.log")

echo "frames read from $CONSUMER_STAGE : $frames_read / $FRAMES"
echo "libusb submit failures         : $usb_fail"
echo "coherent (delay_sync running)  : $COHERENT"
{
  echo "frames_read: $frames_read"
  echo "frames_wanted: $FRAMES"
  echo "usb_submit_failures: $usb_fail"
  echo "coherent: $COHERENT"
  echo "num_ch: $NUM_CH"
  echo "centre_hz: $(awk -v m="$CENTRE_MHZ" 'BEGIN{printf "%d", m*1e6}')"
  echo "sample_rate_hz: $(awk -v m="$SAMPLE_RATE_MBPS" 'BEGIN{printf "%d", m*1e6}')"
  echo "gain_tenths_db: $GAIN"
} >> "$OUT/summary.txt"

if [ "$frames_read" -gt 0 ]; then
  ok "$frames_read IQ frame(s) captured with $NUM_CH channel(s)"
  # Surface the per-channel power so the run can be judged at a glance.
  grep "dBFS" "$OUT/logs/consumer.log" | tail -3 | sed 's/^/  /'
  VERDICT=0
else
  bad "no IQ frames captured"
  if [ "$usb_fail" -gt 0 ]; then
    info "libusb refused transfers despite raising the limit -- see logs/rtl_daq.log"
  fi
  VERDICT=1
fi
[ "$COHERENT" -eq 0 ] && info "reminder: not coherent, so no DoA from this run"

# --------------------------------------------------------------- bundle up
step "bundle"
# Make it readable without root: the whole point is that someone else reads it.
if [ -n "$CALLER" ]; then
  chown -R "$CALLER":"$CALLER" "$ROOT/logs" 2>/dev/null
fi
chmod -R a+rX "$ROOT/logs" 2>/dev/null
du -sh "$OUT" 2>/dev/null | sed 's/^/  /'
echo
ok "log bundle: $OUT"
info "hand over that directory, or just summary.txt + logs/consumer.log + logs/rtl_daq.log"
exit "$VERDICT"
