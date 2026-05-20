#!/bin/bash

LOGS_DIR="logs/power"
mkdir -p "$LOGS_DIR"
SESSION_FILE="${1:-$LOGS_DIR/power_$(date +%Y-%m-%d_%H-%M-%S).csv}"
STAGE_FILE="${2:-/tmp/current_stage.txt}"

IIO0=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-08/c440000.spmi:pmic@8:adc@3100/iio:device0
IIO1=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-00/c440000.spmi:pmic@0:adc@3100/iio:device1

echo "time,stage,vph_pwr_mv,vbat_sns_mv,usb_current_sense_uv,pmic_die_temp_c,board_ambient_temp_c,sdm_skin_temp_c" > "$SESSION_FILE"
echo "Power Logger | Logging to: $SESSION_FILE"

while true; do
    STAGE=$(cat "$STAGE_FILE" 2>/dev/null || echo "unknown")

    vph=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
    vbat=$(cat "$IIO0/in_voltage_vbat_sns_input" 2>/dev/null || echo 0)
    usb_i=$(cat "$IIO0/in_voltage_usb_in_i_uv_input" 2>/dev/null || echo 0)
    pmic_die=$(cat "$IIO1/in_temp_pm7325_die_temp_input" 2>/dev/null || echo 0)
    quiet=$(cat "$IIO1/in_temp_pm7325_quiet_therm_input" 2>/dev/null || echo 0)
    skin=$(cat "$IIO1/in_temp_pm7325_sdm_skin_therm_input" 2>/dev/null || echo 0)

    # Convert µV to mV, µdegC to °C
    vph_mv=$(awk "BEGIN {printf \"%.2f\", $vph/1000}")
    vbat_mv=$(awk "BEGIN {printf \"%.2f\", $vbat/1000}")
    pmic_c=$(awk "BEGIN {printf \"%.2f\", $pmic_die/1000}")
    quiet_c=$(awk "BEGIN {printf \"%.2f\", $quiet/1000}")
    skin_c=$(awk "BEGIN {printf \"%.2f\", $skin/1000}")

    echo "$(date +%T),$STAGE,$vph_mv,$vbat_mv,$usb_i,$pmic_c,$quiet_c,$skin_c" >> "$SESSION_FILE"
    sleep 1
done
