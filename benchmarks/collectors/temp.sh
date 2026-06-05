#!/bin/bash
# benchmarks/collectors/temp.sh
# Continuous thermal telemetry logger.
# Replaces: temp_benchmark.sh, cpu_logger.sh
#
# Usage: temp.sh OUTPUT.csv [STAGE_FILE]

source "$(dirname "$0")/../lib.sh"

SESSION_FILE="${1:-logs/temp/temp_$(date +%Y-%m-%d_%H-%M-%S).csv}"
STAGE_FILE="${2:-/tmp/stage.txt}"
mkdir -p "$(dirname "$SESSION_FILE")"

# Build the header dynamically from whatever CPU/APC zones exist on this device
ZONE_HEADERS=$(
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -f "$zone/type" ] || continue
        type=$(cat "$zone/type")
        [[ "$type" == *cpu* || "$type" == *apc* ]] && echo "$type"
    done | tr '\n' ',' | sed 's/,$//'
)

csv_init "$SESSION_FILE" \
    "time,stage,${ZONE_HEADERS},pmic_die_c,board_ambient_c,sdm_skin_c,xo_therm_c"

echo "[temp] Logging to: $SESSION_FILE"

while true; do
    stage=$(get_stage)
    row="$(date +%T),$stage"

    for zone in /sys/class/thermal/thermal_zone*; do
        [ -f "$zone/temp" ] || continue
        type=$(cat "$zone/type" 2>/dev/null)
        if [[ "$type" == *cpu* || "$type" == *apc* ]]; then
            raw=$(get_zone_temp_raw "$zone")
            if [ "$raw" -gt 0 ]; then
                row="$row,$(awk "BEGIN {printf \"%.2f\", $raw/1000}")"
            fi
        fi
    done

    row="$row,$(get_pmic_die_c),$(get_pmic_quiet_c),$(get_pmic_skin_c),$(get_xo_therm_c)"

    csv_append "$SESSION_FILE" "$row"
    sleep 1
done