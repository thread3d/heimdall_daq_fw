# Xavier AGX / OGN — branch `krakensdr`

Work to run the HeIMDALL DAQ firmware on an **NVIDIA Jetson Xavier AGX** (`aarch64`, Ubuntu
20.04, Python 3.8.10) alongside the OGN receiver. Companions:
[`thread3d/KrakenSDR`](https://github.com/thread3d/KrakenSDR) holds the hardware bring-up and
measurements; [`thread3d/ogn-rf`](https://github.com/thread3d/ogn-rf) branch `krakensdr` holds the
receiver-side integration.

## Status

**The DAQ chain runs on the Xavier and produces real IQ frames on all five channels, concurrently.**

```
frame 0: type=0 chs=5 cpi=1048576 depth=32B dtype=3 fs=1.024 MHz fc=868.300 MHz block=3
         ch0=-29.4dBFS ch1=-31.4dBFS ch2=-31.7dBFS ch3=-31.1dBFS ch4=-29.3dBFS

frames read from decimator_out : 8 / 8
libusb submit failures         : 0
```

Five independent channels over one USB link, each on its own antenna, with per-channel powers that
differ the way five separate receivers should. Timestamps advance exactly one CPI (1.024 s) apart.
Samples are float32 but scaled to ±1/255 because they start life as 8-bit RTL samples (`dtype=3`).

This is the same run that used to fail: **the 16 MB `usbfs_memory_mb` cap was the entire blocker**
for multi-channel operation, and it is also what broke the earlier five-concurrent-SoapySDR-streams
attempt. One `echo 0 > /sys/module/usbcore/parameters/usbfs_memory_mb` fixes both. See
"The blocker" below, and `scripts/sudo-daq-run.sh` to run it.

**This chain is NOT coherent.** `delay_sync.py` did not run (it needs `skrf` and `numba`, neither
installable here without conda), so no phase calibration has been applied. Acquisition is proven;
direction finding is not.

## What was needed to build it

`Firmware/_daq_core/Makefile` builds five binaries. Three things had to be sorted out.

### 1. NE10 for aarch64 — its CMake guard rejects aarch64

`Makefile` picks `decimate_arm_neon` for any non-`x86_64` host, which links `-lNE10`, but only NE10
*headers* are vendored — the library is not. Upstream's `BringUpInstructions.txt` says to build
NE10 with `NE10_LINUX_TARGET_ARCH=aarch64`, but NE10's top-level `CMakeLists.txt` then fails:

```
CMake Error at CMakeLists.txt:191 (message):
  You are trying to compile for non-ARM (CMAKE_SYSTEM_PROCESSOR='aarch64')!
```

The guard is `CMAKE_SYSTEM_PROCESSOR MATCHES "^arm"`, which `aarch64` does not match — even though
NE10's own modules build for aarch64 and its docs tell you to do exactly this. Passing
`-DCMAKE_SYSTEM_PROCESSOR=armv8` does **not** help: CMake re-derives the variable from `uname` in
`CMakeDetermineSystem`, after the `-D`.

`scripts/patch-ne10-aarch64.py` widens the guard to `^(arm|aarch64)`. With that, NE10 builds and
`modules/libNE10.a` is produced. HeIMDALL only uses `ne10_fir_decimate_*` from it (the DSP module,
which is the aarch64-supported one).

```bash
scripts/build-deps-ne10.sh          # clone, patch, build, install next to decimate.out
```

### 2. The Makefile races under `-j`

`daq_util` produces `ini.o log.o iq_header.o sh_mem_util.o` but no other target declares it as a
prerequisite, so `make -j4` starts `rtl_daq` before those objects exist:

```
gcc: error: log.o: No such file or directory
```

Build serially, or `make daq_util && make -j4`.

### 3. librtlsdr must be the krakenrf fork, at runtime too

`rtl_daq` calls `rtlsdr_set_dithering` and `rtlsdr_set_sample_freq_correction_f`, which the packaged
`librtlsdr 0.6.0` does not export. Link-time `LIBRARY_PATH` is not enough — the `DT_NEEDED` is just
`librtlsdr.so.0`, so at runtime the loader finds the system copy. `LD_LIBRARY_PATH` must point at
the fork as well. `thread3d/KrakenSDR`'s `scripts/build-deps.sh` builds it.

## The blocker: `usbfs_memory_mb`

libusb caps the total size of transfer buffers a process may allocate. HeIMDALL's own
`daq_start_sm.sh` raises it to unlimited, and it needs root:

```bash
sudo sh -c 'echo 0 > /sys/module/usbcore/parameters/usbfs_memory_mb'
```

Without it `rtl_daq` logs this, repeatedly, and no data moves:

```
Failed to submit transfer 5
Please increase your allowed usbfs buffer size with the following command:
echo 0 > /sys/module/usbcore/parameters/usbfs_memory_mb
```

One channel fits inside 16 MB; five do not. **This also explains an earlier, separate mystery**: five
concurrent SoapySDR streams failed with `Failed to allocate zero-copy buffer for transfer 3` and
intermittent segfaults, and exactly four worked. Same cap, same cause. It is not a KrakenSDR fault
and not an OGN problem.

## Running it without root

`scripts/heimdall-chain-nosudo.sh` brings up as much of the chain as possible unprivileged:

```
rtl_daq.out | rebuffer.out -> decimate.out -> decimator_out (shared memory)
```

It deliberately skips what upstream's script does with sudo, and says so:

| Skipped | Why it is safe to skip for bring-up |
|---|---|
| `sysctl kernel.sched_rt_runtime_us` | only affects RT throttling |
| `usbfs_memory_mb=0` | **not skippable for 5 channels** — this is the blocker |
| `drop_caches` | performance only |
| `chrt -f 99` | scheduling priority only |
| `hw_controller.py` | needs root for I2C; drives switch matrix / noise source |
| `delay_sync.py` | imports `skrf` **and** `numba`, neither installed → no coherence |

```bash
CENTRE_MHZ=868.3 SAMPLE_RATE_MBPS=1.024 NUM_CH=1 ./scripts/heimdall-chain-nosudo.sh 6
```

## A consumer is required, and upstream ships none

The chain back-pressures on itself: `decimate.out` fills `decimator_out_A` and `_B` and then stalls,
which stalls `rebuffer` and `rtl_daq`. So "no data is moving" proves nothing until something reads
the far end. The intended reader is `delay_sync.py`, which cannot run here.

`Firmware/_daq_core/daq_consumer.c` is a minimal replacement for measurement purposes: it attaches
to `decimator_out` with `init_in_sm_buffer()`, loops `wait_buff_ready()` → read → `send_ctr_buff_free()`,
and prints the IQ header plus per-channel power in dBFS.

It is also the seam `ogn-rf` would eventually use instead of `librtlsdr` — see
[`thread3d/KrakenSDR` docs/03](https://github.com/thread3d/KrakenSDR/blob/main/docs/03-ogn-rf-integration.md).

```bash
./scripts/heimdall-chain-nosudo.sh 6      # builds and runs the consumer automatically
```

Two things worth knowing if you write your own:

- **Size the mapping exactly as the producer does**: `MAX_IQFRAME_PAYLOAD_SIZE * ch_no * 4 * 2 +
  IQ_HEADER_LENGTH`, with `MAX_IQFRAME_PAYLOAD_SIZE = 8388608`.
- **Report power in dBFS, not as a raw magnitude.** Samples are float32 but scaled to ±1/255, so a
  `ch0=%.1f` prints `0.0` and looks exactly like dead data. That cost an hour.

## Configuration used

```ini
[daq]
center_freq  = 868300000
sample_rate  = 1024000
gain         = 400          ; tenths of dB. 0 gives ~-30 dBFS of nothing useful
num_ch       = 1            ; 5 needs usbfs_memory_mb raised
cpi_size     = 1048576
[pre_processing]
decimation_ratio = 1
```

`gain = 0` (the default) is easy to mistake for a broken chain: the frames are real but sit at
−30 dBFS and look like noise floor.

## Next

1. **Raise `usbfs_memory_mb`** (needs root) and re-run with `NUM_CH=5`.
2. Provide `skrf` and `numba` to get `delay_sync.py` running — that is the step from "acquisition
   works" to "coherent", and the only route to DoA. Both are awkward on aarch64/Python 3.8 without
   conda, which is why upstream uses conda.
3. Then the ogn-rf source adapter, reading `decimator_out` instead of `librtlsdr`.

## What direction finding actually needs

Three layers, and it is worth being precise about which are satisfiable here.

### 1. Phase coherence — available now, nothing to install

The array is only coherent after `delay_sync.py` has applied its delay/phase corrections. Two
Python stages are involved and **both** must run:

| Stage | Needs | Status |
|---|---|---|
| `delay_sync.py` | `numba`, `skrf` | available in `~/miniforge3/envs/kraken` |
| `hw_controller.py` | `numpy`, `pyzmq` | available in the same env |

`delay_sync.py:462` calls `wait_buff_free()` on the `delay_sync_hwc` channel, so **it blocks forever
unless `hw_controller.py` is consuming that channel**. Starting one without the other looks like a
hang, not an error. `sudo-daq-run.sh` starts both and checks both are alive.

An existing conda environment already has exactly what upstream asks for:

```
~/miniforge3/envs/kraken/bin/python3   Python 3.9.7
  numpy 1.23.5   scipy 1.9.3   numba 0.56.4   skrf 0.26.0   plotly 5.14.0   pyargus
```

`numba 0.56.4` is the precise version upstream's README pins (`conda install numba==0.56.4`), so
this is the intended interpreter. **No installation is required** — the system `python3` simply does
not have the packages, which is why the stages were being skipped. `sudo-daq-run.sh` now auto-detects
an interpreter that can import `skrf` **and** `numba` (override with `PYTHON=...`).

`numba` really does work on this aarch64 host — the two `@njit` hot loops were compiled and executed
as a standalone check:

```
correct_iq compiled+ran  : 2.387 s      (JIT compile dominates the first call)
copy_iq    compiled+ran  : 0.502 s
njit is real numba       : CPUDispatcher
output finite            : True
```

`skrf` is only needed for the `touchstone` IQ-adjustment source (`rf.Network` on `_calibration/*.s1p`).
The default `iq_adjust_source = explicit-time-delay` never touches it — so `skrf` being present is a
bonus, not the critical dependency.

### 2. Array calibration — needs the noise source

Coherence between *cables and antennas* is measured by switching the receiver's internal noise source
into the antenna path and comparing channels. `hw_controller.py` drives that, and the timing lives in
the `[calibration]` section of `daq_chain_config.ini` (`en_iq_cal`, `cal_frame_interval`,
`cal_frame_burst_size`, `maximum_sync_fails`). It needs no I2C on a KrakenSDR: `DACController` is
only constructed when `en_adpis = 1`, which this configuration does not set.

### 3. The DoA algorithm — NOT present

Coherent IQ is not a bearing. Computing one needs the MUSIC direction-finding application, which is
a separate program that consumes the IQ stream:

- [`krakenrf/krakensdr_doa`](https://github.com/krakenrf/krakensdr_doa) — the Python/`pyargus`
  generation, matching this HeIMDALL
- [`krakenrf/krakensdr_suite`](https://github.com/krakenrf/krakensdr_suite) — the current V2
  all-C++ suite (`kraken_doa_v2`), which is what upstream ships today

Neither is cloned or built here. `pyargus` (the DOA maths) *is* already in the `kraken` environment,
so `krakensdr_doa` is the shorter path.

So the honest summary: **the coherence layer can be switched on immediately with what is already
installed**; the direction-finding application is the remaining piece, and it is a separate
build-and-run task rather than a missing dependency.
