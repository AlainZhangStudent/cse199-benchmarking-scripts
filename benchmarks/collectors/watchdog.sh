#!/bin/bash
# benchmarks/collectors/watchdog.sh
# High-frequency (0.1s) voltage + GPU + CPU spot logger.
# Also updates peak tracking in /tmp for live displays.
#
# Usage: watchdog.sh OUTPUT.csv [STAGE_FILE]

source "$(dirname "$0")/../lib.sh"

SESSION_FILE="${1:-logs/combined/watchdog_$(date +%Y-%m-%d_%H-%M-%S).csv}"
STAGE_FILE="${2:-/tmp/stage.txt}"
mkdir -p "$(dirname "$SESSION_FILE")"

csv_init "$SESSION_FILE" \
    "time,stage,vph_pwr_mv,gpu_busy_pct,cpu0_freq_mhz,cpu4_freq_mhz,note"

echo "[watchdog] Logging to: $SESSION_FILE"

while true; do
    stage=$(get_stage)
    vph=$(get_vph_mv)
    gpu=$(get_gpu_busy)
    cpu0=$(get_cpu_freq_mhz 0)
    cpu4=$(get_cpu_freq_mhz 4)
    note=$(voltage_status "$vph")
    [ "$note" = "ok" ] && note=""

    csv_append "$SESSION_FILE" \
        "$(date +%T),$stage,$vph,$gpu,$cpu0,$cpu4,$note"

    # Update shared peak/min state so live displays can read it
    peak_update_min_voltage "$vph"

    sleep 0.1
done