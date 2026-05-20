#!/bin/bash

SESSION_FILE="${1:-logs/temp/temp_$(date +%Y-%m-%d_%H-%M-%S).csv}"
STAGE_FILE="${2:-/tmp/current_stage.txt}"
mkdir -p "$(dirname "$SESSION_FILE")"

IIO1=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-00/c440000.spmi:pmic@0:adc@3100/iio:device1

# Build header from cpu/apc thermal zones
ZONE_HEADERS=$(ls /sys/class/thermal/thermal_zone*/type | xargs cat | grep -E 'cpu|apc' | tr '\n' ',' | sed 's/,$//')
echo "time,stage,$ZONE_HEADERS,pmic_die_temp_c,board_ambient_temp_c,sdm_skin_temp_c,xo_therm_temp_c" > "$SESSION_FILE"

echo "Temperature Logger | Logging to: $SESSION_FILE"

while true; do
    STAGE=$(cat "$STAGE_FILE" 2>/dev/null || echo "unknown")
    ROW_DATA="$(date +%T),$STAGE"

    # CPU and APC thermal zones
    for zone in /sys/class/thermal/thermal_zone*; do
        if [ -f "$zone/temp" ]; then
            type=$(cat "$zone/type")
            if [[ "$type" == *"cpu"* || "$type" == *"apc"* ]]; then
                raw_temp=$(cat "$zone/temp")
                if [ "$raw_temp" -gt 0 ]; then
                    temp=$(awk "BEGIN {printf \"%.2f\", $raw_temp/1000}")
                    ROW_DATA="$ROW_DATA,$temp"
                fi
            fi
        fi
    done

    # PMIC temperatures from IIO device1
    pmic_die=$(cat "$IIO1/in_temp_pm7325_die_temp_input" 2>/dev/null || echo 0)
    quiet=$(cat "$IIO1/in_temp_pm7325_quiet_therm_input" 2>/dev/null || echo 0)
    skin=$(cat "$IIO1/in_temp_pm7325_sdm_skin_therm_input" 2>/dev/null || echo 0)
    xo=$(cat "$IIO1/in_temp_xo_therm_input" 2>/dev/null || echo 0)

    pmic_c=$(awk "BEGIN {printf \"%.2f\", $pmic_die/1000}")
    quiet_c=$(awk "BEGIN {printf \"%.2f\", $quiet/1000}")
    skin_c=$(awk "BEGIN {printf \"%.2f\", $skin/1000}")
    xo_c=$(awk "BEGIN {printf \"%.2f\", $xo/1000}")

    ROW_DATA="$ROW_DATA,$pmic_c,$quiet_c,$skin_c,$xo_c"

    echo "$ROW_DATA" >> "$SESSION_FILE"
    sleep 1
done
