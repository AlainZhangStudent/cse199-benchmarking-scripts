#!/bin/bash
# volt_live_display_test.sh
# Staged voltage droop characterization: idle → CPU → GPU → combined.
# Thin orchestrator — all hardware reads via lib.sh.

BENCH_DIR="$(cd "$(dirname "$0")/benchmarks" && pwd)"
source "$BENCH_DIR/lib.sh"

kgsl_check || exit 1

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
init_stage_file "$TIMESTAMP"

mkdir -p logs/combined

VOLTAGE_FILE="logs/combined/voltage_monitor_${TIMESTAMP}.csv"

csv_init "$VOLTAGE_FILE" \
    "time,stage,vph_pwr_mv,gpu_busy_pct,cpu4_freq_mhz,note"

# ── Background high-frequency voltage logger ──────────────────────────────────
(
    while true; do
        stage=$(get_stage)
        vph=$(get_vph_mv)
        gpu=$(get_gpu_busy)
        cpu4=$(get_cpu_freq_mhz 4)
        note=$(voltage_status "$vph")
        [ "$note" = "ok" ] && note=""
        csv_append "$VOLTAGE_FILE" "$(date +%T),$stage,$vph,$gpu,$cpu4,$note"
        sleep 0.1
    done
) &
LOGGER_PID=$!

# ── Live display helper ───────────────────────────────────────────────────────
show_status() {
    local stage_label=$1
    local vph gpu cpu4 temp_c volt_st

    vph=$(get_vph_mv)
    gpu=$(get_gpu_busy)
    cpu4=$(get_cpu_freq_mhz 4)
    temp_raw=$(cat /sys/class/thermal/thermal_zone10/temp 2>/dev/null || echo 0)
    temp_c=$(awk "BEGIN {printf \"%.1f\", $temp_raw/1000}")
    volt_st=$(voltage_status "$vph")

    clear
    echo "============================================"
    echo "  Voltage Drop Test | $(date +%H:%M:%S)"
    echo "  Stage: $stage_label"
    echo "============================================"
    printf "  %-25s %s mV  [%s]\n" "vph_pwr:"     "$vph"   "$volt_st"
    printf "  %-25s %s MHz\n"      "CPU4 freq:"   "$cpu4"
    printf "  %-25s %s %%\n"       "GPU Busy:"    "$gpu"
    printf "  %-25s %s°C\n"        "CPU0 Temp:"   "$temp_c"
    printf "  %-25s %s\n"          "KGSL:"        "$([ -e /dev/kgsl-3d0 ] && echo OK || echo MISSING)"
    echo "  Logging to: $VOLTAGE_FILE"
    echo "============================================"
}

# ── Stage 1: Idle baseline ────────────────────────────────────────────────────
set_stage "idle"
echo "Recording idle baseline (10s)..."
for _ in $(seq 1 10); do show_status "IDLE BASELINE"; sleep 1; done

# ── Stage 2: CPU only ─────────────────────────────────────────────────────────
set_stage "cpu_only"
echo "Starting CPU stress (60s)..."
stress-ng --cpu 8 --timeout 60s &
STRESS_PID=$!
while kill -0 $STRESS_PID 2>/dev/null; do show_status "CPU ONLY"; sleep 1; done

echo "CPU done. Cooldown (15s)..."
set_stage "cooldown_cpu"
for _ in $(seq 1 15); do show_status "COOLDOWN"; sleep 1; done

# ── Stage 3: GPU only ─────────────────────────────────────────────────────────
set_stage "gpu_only"
echo "Starting GPU stress (60s)..."
CONTAINER=$(start_gpu_stress "${TIMESTAMP}_gpu")
for _ in $(seq 1 60); do show_status "GPU ONLY"; sleep 1; done
stop_gpu_stress "$CONTAINER"

echo "GPU done. Cooldown (15s)..."
set_stage "cooldown_gpu"
for _ in $(seq 1 15); do show_status "COOLDOWN"; sleep 1; done

# ── Stage 4: Combined ─────────────────────────────────────────────────────────
set_stage "cpu_gpu_combined"
echo "Starting combined CPU + GPU stress (60s)..."
CONTAINER=$(start_gpu_stress "${TIMESTAMP}_combined")
sleep 5
stress-ng --cpu 8 --timeout 60s &
STRESS_PID=$!
while kill -0 $STRESS_PID 2>/dev/null; do show_status "CPU + GPU"; sleep 1; done
stop_gpu_stress "$CONTAINER"

# ── Cleanup ───────────────────────────────────────────────────────────────────
kill $LOGGER_PID 2>/dev/null
rm -f "$STAGE_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Done. Results: $VOLTAGE_FILE"
echo ""
echo "Stage averages:"

for label in "idle" "cpu_only" "gpu_only" "cpu_gpu_combined"; do
    echo "--- $label ---"
    grep ",$label," "$VOLTAGE_FILE" | awk -F',' \
        '{sum+=$3; count++; if(min==""||$3<min)min=$3}
         END {printf "  Avg: %.2f mV  Min: %.2f mV\n", sum/count, min}'
done