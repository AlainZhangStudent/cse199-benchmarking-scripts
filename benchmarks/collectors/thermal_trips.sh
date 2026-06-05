#!/bin/bash
# benchmarks/collectors/thermal_trips.sh
# Logs TRIP_CROSSED / TRIP_CLEARED events for all thermal zones.
# Also updates /tmp peak files for live display use.
#
# Usage: thermal_trips.sh OUTPUT.csv

source "$(dirname "$0")/../lib.sh"

SESSION_FILE="${1:-logs/combined/thermal_$(date +%Y-%m-%d_%H-%M-%S).csv}"
mkdir -p "$(dirname "$SESSION_FILE")"

csv_init "$SESSION_FILE" \
    "time,zone,type,temp_c,trip_point_c,event"

echo "[thermal_trips] Logging to: $SESSION_FILE"

TRIP_POINTS=(65000 80000 90000 110000 118000 125000)
declare -A PREV_TRIPS

while true; do
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -f "$zone/temp" ] || continue

        raw=$(get_zone_temp_raw "$zone")
        type=$(cat "$zone/type" 2>/dev/null || echo "unknown")
        zone_id=$(basename "$zone")

        # Update peak tracker
        peak_update_temp "$type" "$raw"

        for trip in "${TRIP_POINTS[@]}"; do
            key="${zone_id}_${trip}"
            temp_c=$(awk "BEGIN {printf \"%.1f\", $raw/1000}")
            trip_c=$(awk "BEGIN {printf \"%.1f\", $trip/1000}")

            if [ "$raw" -ge "$trip" ] && [ "${PREV_TRIPS[$key]}" != "triggered" ]; then
                csv_append "$SESSION_FILE" \
                    "$(date +%T),$zone_id,$type,$temp_c,$trip_c,TRIP_CROSSED"
                PREV_TRIPS[$key]="triggered"

            elif [ "$raw" -lt "$trip" ] && [ "${PREV_TRIPS[$key]}" = "triggered" ]; then
                csv_append "$SESSION_FILE" \
                    "$(date +%T),$zone_id,$type,$temp_c,$trip_c,TRIP_CLEARED"
                PREV_TRIPS[$key]=""
            fi
        done
    done

    sleep 1
done