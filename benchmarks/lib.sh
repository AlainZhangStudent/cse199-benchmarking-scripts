#!/bin/bash
# benchmarks/lib.sh
# Shared foundation — source this in every script:
#   source "$(dirname "$0")/lib.sh"         (from benchmarks/)
#   source "$(dirname "$0")/benchmarks/lib.sh"  (from root)

# ─── IIO DEVICE PATHS ────────────────────────────────────────────────────────
IIO0=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-08/c440000.spmi:pmic@8:adc@3100/iio:device0
IIO1=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-00/c440000.spmi:pmic@0:adc@3100/iio:device1

# ─── STAGE TRACKING ──────────────────────────────────────────────────────────
# Each run gets its own stage file so parallel runs don't conflict.
# Call:  init_stage_file   → sets STAGE_FILE and exports it
#        set_stage "name"  → writes to STAGE_FILE
#        get_stage         → reads from STAGE_FILE

init_stage_file() {
    local ts="${1:-$(date +%Y-%m-%d_%H-%M-%S)}"
    STAGE_FILE="/tmp/stage_${ts}.txt"
    export STAGE_FILE
    echo "idle" > "$STAGE_FILE"
}

set_stage() {
    echo "$1" > "${STAGE_FILE:-/tmp/stage.txt}"
    sync "${STAGE_FILE:-/tmp/stage.txt}"
}

get_stage() {
    cat "${STAGE_FILE:-/tmp/stage.txt}" 2>/dev/null || echo "unknown"
}

# ─── HARDWARE READS ──────────────────────────────────────────────────────────
# All return plain values — no units, no labels.
# Callers format for display or CSV.

get_vph_mv() {
    local raw
    raw=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.2f\", $raw/1000}"
}

get_vbat_mv() {
    local raw
    raw=$(cat "$IIO0/in_voltage_vbat_sns_input" 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.2f\", $raw/1000}"
}

get_usb_current_uv() {
    cat "$IIO0/in_voltage_usb_in_i_uv_input" 2>/dev/null || echo 0
}

get_gpu_busy() {
    cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print $1}'
}

get_gpu_clock_mhz() {
    cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null || echo 0
}

get_cpu_freq_mhz() {
    local cpu=$1
    local raw
    raw=$(cat /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.0f\", $raw/1000}"
}

get_cpu_freq_khz() {
    local cpu=$1
    cat /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_cur_freq 2>/dev/null || echo 0
}

get_zone_temp_c() {
    # Usage: get_zone_temp_c /sys/class/thermal/thermal_zoneN
    local zone=$1
    local raw
    raw=$(cat "$zone/temp" 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.1f\", $raw/1000}"
}

get_zone_temp_raw() {
    local zone=$1
    cat "$zone/temp" 2>/dev/null || echo 0
}

get_zone_by_type() {
    # Returns path of zone directory matching a type string (exact match)
    local type=$1
    local hit
    hit=$(grep -l "^${type}$" /sys/class/thermal/thermal_zone*/type 2>/dev/null | head -1)
    [ -n "$hit" ] && dirname "$hit"
}

get_pmic_die_c() {
    local raw
    raw=$(cat "$IIO1/in_temp_pm7325_die_temp_input" 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.2f\", $raw/1000}"
}

get_pmic_quiet_c() {
    local raw
    raw=$(cat "$IIO1/in_temp_pm7325_quiet_therm_input" 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.2f\", $raw/1000}"
}

get_pmic_skin_c() {
    local raw
    raw=$(cat "$IIO1/in_temp_pm7325_sdm_skin_therm_input" 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.2f\", $raw/1000}"
}

get_xo_therm_c() {
    local raw
    raw=$(cat "$IIO1/in_temp_xo_therm_input" 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.2f\", $raw/1000}"
}

# ─── CSV HELPERS ─────────────────────────────────────────────────────────────

csv_init() {
    # csv_init FILE HEADER...
    # Creates file with header row. Overwrites existing file.
    local file=$1; shift
    echo "$@" > "$file"
    sync "$file"
}

csv_append() {
    # csv_append FILE ROW
    local file=$1; shift
    echo "$@" >> "$file"
    sync "$file"
}

# ─── KGSL / GPU DEVICE CHECK ─────────────────────────────────────────────────
# Returns 0 (success) if GPU device is available, 1 if not.
# Tries to load the module and trigger udev before giving up.

kgsl_check() {
    if ! lsmod | grep -q msm_kgsl; then
        echo "[kgsl] msm_kgsl not loaded — attempting modprobe..."
        sudo modprobe msm_kgsl
        sleep 2
    fi

    if [ ! -e /dev/kgsl-3d0 ]; then
        echo "[kgsl] Device node missing — triggering udev..."
        sudo udevadm trigger --subsystem-match=kgsl
        sleep 1
    fi

    if [ ! -e /dev/kgsl-3d0 ]; then
        echo "[kgsl] FATAL: /dev/kgsl-3d0 not found. GPU benchmarks invalid."
        return 1
    fi

    echo "[kgsl] OK: /dev/kgsl-3d0 confirmed"
    return 0
}

# ─── VOLTAGE STATUS ──────────────────────────────────────────────────────────
# Returns a short status string for a given mV value.

voltage_status() {
    local mv=$1
    if awk "BEGIN {exit !($mv < 3500)}"; then
        echo "CRITICAL_VOLTAGE"
    elif awk "BEGIN {exit !($mv < 3800)}"; then
        echo "LOW_VOLTAGE_WARNING"
    else
        echo "ok"
    fi
}

# ─── TEMPERATURE STATUS ───────────────────────────────────────────────────────
# Returns a short status label for a raw millidegree value.

temp_status() {
    local raw=$1
    if [ "$raw" -ge 90000 ]; then
        echo "!!! CRITICAL !!!"
    elif [ "$raw" -ge 80000 ]; then
        echo "** HOT **"
    elif [ "$raw" -ge 65000 ]; then
        echo "* WARM *"
    else
        echo "ok"
    fi
}

# ─── PROCESS HEALTH CHECK ────────────────────────────────────────────────────
# Use after starting background loggers to confirm they stayed alive.
# Usage: check_pids "temp" $TEMP_PID "power" $POWER_PID ...

check_pids() {
    local failed=0
    while [ $# -ge 2 ]; do
        local name=$1
        local pid=$2
        shift 2
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "[warn] $name logger (PID $pid) is not running"
            failed=1
        else
            echo "[ok]   $name logger (PID $pid) running"
        fi
    done
    return $failed
}

# ─── FILE ACTIVITY CHECK ─────────────────────────────────────────────────────
# Confirms a CSV is non-empty after startup delay.

check_files() {
    local ok=1
    for f in "$@"; do
        if [ -s "$f" ]; then
            echo "[ok]   $f is receiving data"
        else
            echo "[warn] $f is empty or missing"
            ok=0
        fi
    done
    return $((1 - ok))
}

# ─── DOCKER GPU STRESS ───────────────────────────────────────────────────────
# Starts the Adreno OpenCL GPU stress container.
# Returns container name via stdout so caller can stop it later.
# Usage:  CONTAINER=$(start_gpu_stress "$TIMESTAMP")

GPU_IMAGE="ghcr.io/kastnerrg/cse160-opencl:gpu-adreno"

start_gpu_stress() {
    local ts="${1:-$(date +%s)}"
    local name="gpu_stress_${ts}"

    sudo docker run -d \
        --name "$name" \
        --privileged \
        --user root \
        --device=/dev/kgsl-3d0 \
        -v /home/ubuntu:/host \
        "$GPU_IMAGE" \
        /bin/bash -c "source /usr/lib/qcom-adreno/qcom-adreno-vars.sh && while true; do dlprim_flops 0:0; done" \
        > /dev/null 2>&1

    echo "$name"
}

stop_gpu_stress() {
    local name=$1
    sudo docker stop "$name" > /dev/null 2>&1
    sudo docker rm   "$name" > /dev/null 2>&1
}

# ─── PEAK TRACKER (in-memory) ─────────────────────────────────────────────────
# Lightweight peak tracking using /tmp files so subshells can update shared state.
# Keys are thermal zone type names.

peak_update_temp() {
    local type=$1
    local raw=$2
    local current
    current=$(cat "/tmp/bench_peak_${type}" 2>/dev/null || echo 0)
    if awk "BEGIN {exit !($raw > $current)}"; then
        echo "$raw"        > "/tmp/bench_peak_${type}"
        date +%T           > "/tmp/bench_peaktime_${type}"
    fi
}

peak_get_temp_c() {
    local type=$1
    local raw
    raw=$(cat "/tmp/bench_peak_${type}" 2>/dev/null || echo 0)
    awk "BEGIN {printf \"%.1f\", $raw/1000}"
}

peak_update_min_voltage() {
    local mv=$1
    local current
    current=$(cat /tmp/bench_min_voltage 2>/dev/null || echo 9999)
    if awk "BEGIN {exit !($mv < $current)}"; then
        echo "$mv"  > /tmp/bench_min_voltage
        date +%T    > /tmp/bench_min_voltage_time
    fi
}

peak_cleanup() {
    rm -f /tmp/bench_peak_* /tmp/bench_peaktime_* \
          /tmp/bench_min_voltage /tmp/bench_min_voltage_time
}