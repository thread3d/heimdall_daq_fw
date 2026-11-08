# Xavier AGX / OGN — branch `krakensdr`

Work to run the HeIMDALL DAQ firmware on an **NVIDIA Jetson Xavier AGX** (`aarch64`, Ubuntu
20.04, Python 3.8.10) alongside the OGN receiver. Companions:
[`thread3d/KrakenSDR`](https://github.com/thread3d/KrakenSDR) holds the hardware bring-up and
measurements; [`thread3d/ogn-rf`](https://github.com/thread3d/ogn-rf) branch `krakensdr` holds the
receiver-side integration.

## Status

**The DAQ chain runs on the Xavier and produces real IQ frames — for one channel.**

```
frame  0: type=0 chs=1 cpi=1048576 depth=32B dtype=3 fs=1.024 MHz fc=868.300 MHz block=3 cpi_idx=0
          raw[0..7] as float32: 0.0431373 -0.027451 -0.027451 -0.0431373 0.0352941 ...
          ch0=-21.3dBFS
```

Frames carry a valid sync word, the configured centre frequency, `cpi=1048576` samples at
1.024 MHz, and timestamps exactly one CPI (1.024 s) apart. Sample values are float32 but scaled to
±1/255 because they begin life as 8-bit RTL samples (`dtype=3`).

**Five channels do not work yet**, and the reason is precise: libusb's `usbfs_memory_mb` cap is
16 MB and HeIMDALL needs it unlimited. That requires root — see "The blocker" below.

Note this chain is **not coherent**: `delay_sync.py` did not run, so no phase calibration has been
applied. That is enough to prove acquisition; it is not enough for direction finding.

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
