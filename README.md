# Rubik Pi 3 Stress & Benchmark Suite

Combined CPU + GPU stress testing, thermal characterization, and power rail monitoring for Qualcomm Snapdragon / Adreno hardware.

---

## Quick Start

```bash
# Make everything executable (first time only)
chmod +x crash_test.sh temp_live_display.sh volt_live_display_test.sh
chmod +x benchmarks/lib.sh benchmarks/parse_cpu.sh
chmod +x benchmarks/collectors/*.sh
chmod +x benchmarks/runners/*.sh
chmod +x benchmarks/views/*.sh
```

---

## Top-Level Scripts

### `volt_live_display_test.sh`
Runs a staged voltage droop test and displays real-time power rail data in the terminal. Useful for seeing how much the system voltage sags under different load conditions.

Stages: idle baseline → CPU only → GPU only → CPU + GPU combined

```bash
./volt_live_display_test.sh
```

Logs to `logs/combined/voltage_monitor_<timestamp>.csv`. After the run it prints a per-stage summary of average and minimum voltage.

---

### `temp_live_display.sh`
Runs combined CPU + GPU stress while showing a live thermal dashboard in the terminal. Tracks temperatures, trip point crossings, and peak values across all thermal zones.

```bash
./temp_live_display.sh
```

Logs to `logs/combined/`. Produces a peak temperature summary at the end of the run.

---

### `crash_test.sh`
Pushes the system as hard as possible to find instability. Runs maximum CPU and GPU load simultaneously and monitors for thermal runaway, voltage collapse, and kernel issues.

```bash
./crash_test.sh
```

Logs to `logs/combined/`. Includes watchdog telemetry at 0.1s resolution and a journal capture for kernel-level events.

---

## Benchmarks

### `benchmarks/runners/cpu_bench.sh`
Staged CPU benchmark with telemetry logging. Steps through increasing workloads and auto-parses results into a CSV.

Stages: single core → all cores → all cores + memory → all cores + memory + IO

```bash
./benchmarks/runners/cpu_bench.sh
```

Logs to `logs/cpu/`. Parsed results saved alongside the stress log.

---

## File Tree

```
cse199-benchmarking-scripts/
├── crash_test.sh
├── temp_live_display.sh
├── volt_live_display_test.sh
│
└── benchmarks/
    ├── lib.sh                  # shared functions — hardware reads, CSV helpers, GPU control
    ├── parse_cpu.sh            # parses stress-ng logs into CSV
    │
    ├── collectors/             # background telemetry loggers
    │   ├── temp.sh             # CPU/APC/PMIC thermal zones
    │   ├── power.sh            # voltage rails, PMIC temps
    │   ├── cpu_metrics.sh      # frequencies, load, memory, idle states
    │   ├── watchdog.sh         # 0.1s voltage + GPU + CPU spot logger
    │   └── thermal_trips.sh    # logs trip point crossings and clears
    │
    ├── runners/                # benchmark orchestrators
    │   └── cpu_bench.sh        # staged CPU benchmark
    │
    └── views/                  # live terminal displays
        └── temp_display.sh     # real-time thermal dashboard
```

---

## Log Output

| Script | Log Location |
|---|---|
| `crash_test.sh` | `logs/combined/` |
| `temp_live_display.sh` | `logs/combined/` |
| `volt_live_display_test.sh` | `logs/combined/` |
| `cpu_bench.sh` | `logs/cpu/` |
| temperature collector | `logs/temp/` |
| power collector | `logs/power/` |

---

## Requirements

**CPU stress**
- `stress-ng`

**GPU stress**
- `docker`
- Docker image: `ghcr.io/kastnerrg/cse160-opencl:gpu-adreno` — pull it once before running:
  ```bash
  docker pull ghcr.io/kastnerrg/cse160-opencl:gpu-adreno
  ```
- `dlprim_flops` — OpenCL FLOPS benchmark from the [DLPrimitives](https://github.com/artyom-beilis/dlprimitives) library, bundled inside the container above
- Qualcomm Adreno OpenCL runtime at `/usr/lib/qcom-adreno/` (sourced inside the container via `qcom-adreno-vars.sh`)

**System tools**
- `bash` — scripts use associative arrays (`declare -A`); they will **not** run under `sh`/`dash`
- `awk`, `coreutils` (`cat`, `date`, `sync`, etc.) — standard on most systems
- `journalctl` / systemd — used by `crash_test.sh` and `temp_live_display.sh` to capture kernel logs

**Hardware / drivers**
- Qualcomm KGSL GPU driver (`msm_kgsl`) — scripts will attempt `modprobe` if not loaded
- `/dev/kgsl-3d0` device node — scripts will attempt `udevadm trigger` if missing
- IIO PMIC device nodes at `/sys/devices/platform/soc@0/c440000.spmi/...` for voltage and temperature reads

**Permissions**
- `sudo` access for `modprobe`, `udevadm`, and `docker`

---

## Important Notes

- **Run from your project root.** All scripts create their `logs/` directory relative to the current working directory, not the script location. `cd` into the project root before running so logs land in one predictable place.
- **The live displays need a real terminal.** `temp_live_display.sh` (via `views/temp_display.sh`) writes the dashboard to `/dev/tty`. It will fail under `cron`, `nohup`, CI, or any non-interactive session. The CSV logging still works in those contexts — only the live on-screen dashboard requires a terminal.
- **Run one stress script at a time.** They share the GPU device, the PMIC sensors, and `stress-ng`. Running two at once will corrupt each other's readings.