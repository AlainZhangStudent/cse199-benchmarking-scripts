#!/bin/bash
# benchmarks/collectors/power.sh
# Continuous power and voltage telemetry logger.
# Replaces: power_benchmark.sh
#
# Usage: power.sh OUTPUT.csv [STAGE_FILE]

source "$(dirname "$0")/../lib.sh"

SESSION_FILE="${1:-logs/power/power_$(date +%Y-%m-%d_%H-%M-%S).csv}"
STAGE_FILE="${2:-/tmp/stage.txt}"
mkdir -p "$(dirname "$SESSION_FILE")"

csv_init "$SESSION_FILE" \
    "time,stage,vph_pwr_mv,vbat_sns_mv,usb_current_uv,pmic_die_c,board_ambient_c,sdm_skin_c"

echo "[power] Logging to: $SESSION_FILE"

while true; do
    stage=$(get_stage)
    vph=$(get_vph_mv)
    vbat=$(get_vbat_mv)
    usb=$(get_usb_current_uv)
    pmic=$(get_pmic_die_c)
    ambient=$(get_pmic_quiet_c)
    skin=$(get_pmic_skin_c)

    csv_append "$SESSION_FILE" \
        "$(date +%T),$stage,$vph,$vbat,$usb,$pmic,$ambient,$skin"

    sleep 1
done