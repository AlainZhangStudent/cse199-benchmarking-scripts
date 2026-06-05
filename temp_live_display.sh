#!/bin/bash
# temp_live_display.sh
# Combined CPU + GPU thermal characterization with live dashboard.
# Thin orchestrator — all logic lives in benchmarks/

BENCH_DIR="$(cd "$(dirname "$0")/benchmarks" && pwd)"
source "$BENCH_DIR/lib.sh"

kgsl_check || exit 1

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
init_stage_file "$TIMESTAMP"
peak_cleanup

mkdir -p logs/temp logs/power logs/cpu logs/combined

TEMP_FILE="logs/temp/temp_${TIMESTAMP}.csv"
POWER_FILE="logs/power/power_${TIMESTAMP}.csv"
METRICS_FILE="logs/cpu/cpu_metrics_${TIMESTAMP}.csv"
SESSION_FILE="logs/combined/combined_stress_${TIMESTAMP}.log"
WATCHDOG_FILE="logs/combined/watchdog_${TIMESTAMP}.csv"
THERMAL_FILE="logs/combined/thermal_${TIMESTAMP}.csv"
JOURNAL_FILE="logs/combined/journal_${TIMESTAMP}.log"
PEAK_FILE="logs/combined/peak_summary_${TIMESTAMP}.txt"

# ── Start collectors ──────────────────────────────────────────────────────────
"$BENCH_DIR/collectors/temp.sh"          "$TEMP_FILE"     "$STAGE_FILE" > /dev/null 2>&1 &
TEMP_PID=$!

"$BENCH_DIR/collectors/power.sh"         "$POWER_FILE"    "$STAGE_FILE" > /dev/null 2>&1 &
POWER_PID=$!

"$BENCH_DIR/collectors/cpu_metrics.sh"   "$METRICS_FILE"  "$STAGE_FILE" > /dev/null 2>&1 &
METRICS_PID=$!

"$BENCH_DIR/collectors/watchdog.sh"      "$WATCHDOG_FILE" "$STAGE_FILE" > /dev/null 2>&1 &
WATCHDOG_PID=$!

"$BENCH_DIR/collectors/thermal_trips.sh" "$THERMAL_FILE"               > /dev/null 2>&1 &
THERMAL_PID=$!

( journalctl -f --no-pager 2>/dev/null >> "$JOURNAL_FILE" ) &
JOURNAL_PID=$!

sleep 2
check_pids \
    "temp"     $TEMP_PID \
    "power"    $POWER_PID \
    "metrics"  $METRICS_PID \
    "watchdog" $WATCHDOG_PID \
    "thermal"  $THERMAL_PID
sleep 1
check_files "$TEMP_FILE" "$POWER_FILE" "$METRICS_FILE"

# ── Stress + display ──────────────────────────────────────────────────────────
set_stage "combined_cpu_gpu"
echo "Starting GPU stress..." | tee "$SESSION_FILE"
CONTAINER=$(start_gpu_stress "$TIMESTAMP")
sleep 5

"$BENCH_DIR/views/temp_display.sh" "$STAGE_FILE" &
DISPLAY_PID=$!

echo "Starting CPU stress (120s)..." | tee -a "$SESSION_FILE"
stress-ng --cpu 8 --timeout 120s --metrics 2>&1 | tee -a "$SESSION_FILE"

# ── Teardown ──────────────────────────────────────────────────────────────────
kill $DISPLAY_PID 2>/dev/null
sleep 0.5

echo "Completed: $(date)" | tee -a "$SESSION_FILE"
stop_gpu_stress "$CONTAINER"

set_stage "completed"
kill $TEMP_PID $POWER_PID $METRICS_PID $WATCHDOG_PID $THERMAL_PID $JOURNAL_PID 2>/dev/null
rm -f "$STAGE_FILE"

# ── Peak summary ──────────────────────────────────────────────────────────────
{
    echo "============================================"
    echo "  PEAK TEMPERATURE SUMMARY | Run: $TIMESTAMP"
    echo "============================================"

    for zone in /sys/class/thermal/thermal_zone*; do
        [ -f "$zone/type" ] || continue
        type=$(cat "$zone/type" 2>/dev/null)
        raw=$(cat "/tmp/bench_peak_${type}" 2>/dev/null || echo 0)
        [ "$raw" -gt 0 ] || continue
        peak_c=$(awk "BEGIN {printf \"%.1f\", $raw/1000}")
        peak_time=$(cat "/tmp/bench_peaktime_${type}" 2>/dev/null || echo "N/A")
        printf "  %-30s peak: %6s°C  at %s\n" "$type" "$peak_c" "$peak_time"
    done

    echo ""
    min_v=$(cat /tmp/bench_min_voltage 2>/dev/null || echo "N/A")
    min_t=$(cat /tmp/bench_min_voltage_time 2>/dev/null || echo "N/A")
    echo "  Min vph_pwr voltage: ${min_v} mV  at ${min_t}"
    echo "============================================"
} | tee "$PEAK_FILE"

peak_cleanup

echo ""
echo "Files:"
echo "  Stress log:    $SESSION_FILE"
echo "  Temperature:   $TEMP_FILE"
echo "  Power:         $POWER_FILE"
echo "  CPU metrics:   $METRICS_FILE"
echo "  Watchdog:      $WATCHDOG_FILE"
echo "  Thermal trips: $THERMAL_FILE"
echo "  Peak summary:  $PEAK_FILE"
echo "  Journal:       $JOURNAL_FILE"