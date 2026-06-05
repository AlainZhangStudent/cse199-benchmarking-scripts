#!/bin/bash
# benchmarks/views/temp_display.sh
# Real-time thermal dashboard. Reads /tmp peak files written by thermal_trips.sh
# and watchdog.sh. Run this alongside collectors — it does NOT start any load.
#
# Usage: ./views/temp_display.sh [STAGE_FILE]

source "$(dirname "$0")/../lib.sh"

STAGE_FILE="${1:-/tmp/stage.txt}"

KEY_ZONES=(
    "cpu0-thermal"
    "cpuss0-thermal"
    "cpuss1-thermal"
    "gpuss0-thermal"
    "gpuss1-thermal"
    "aoss0-thermal"
    "ddr-thermal"
    "sdm-skin-thermal"
)

# Wait for collectors to initialize
sleep 3

while true; do
    {
        echo "--------------------------------------------"
        echo "  $(date +%H:%M:%S) | Stage: $(get_stage) | KGSL: $([ -e /dev/kgsl-3d0 ] && echo OK || echo MISSING)"
        echo "--------------------------------------------"
        echo "  KEY TEMPERATURES:"

        for type in "${KEY_ZONES[@]}"; do
            zone_dir=$(get_zone_by_type "$type")
            [ -n "$zone_dir" ] || continue

            raw=$(get_zone_temp_raw "$zone_dir")
            temp_c=$(awk "BEGIN {printf \"%.1f\", $raw/1000}")
            peak_c=$(peak_get_temp_c "$type")
            status=$(temp_status "$raw")

            printf "  %-25s %5s°C  (peak: %5s°C)  %s\n" \
                "$type" "$temp_c" "$peak_c" "$status"
        done

        echo ""
        echo "  ALL CPU CORES:"
        for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
            zone_dir=$(get_zone_by_type "cpu${i}-thermal")
            [ -n "$zone_dir" ] || continue

            raw=$(get_zone_temp_raw "$zone_dir")
            temp_c=$(awk "BEGIN {printf \"%.1f\", $raw/1000}")
            mhz=$(get_cpu_freq_mhz $i)
            cluster=$( [ "$i" -lt 4 ] && echo "eff" || echo "perf" )

            printf "  CPU%-2d (%s): %5s°C  %4s MHz\n" "$i" "$cluster" "$temp_c" "$mhz"
        done

        echo ""
        vph=$(get_vph_mv)
        min_v=$(cat /tmp/bench_min_voltage 2>/dev/null || echo "N/A")
        gpu=$(get_gpu_busy)
        gpu_clk=$(get_gpu_clock_mhz)
        volt_status=$(voltage_status "$vph")

        printf "  %-25s %s mV  (min: %s mV)  %s\n" "vph_pwr" "$vph" "$min_v" "$volt_status"
        printf "  %-25s %s %%\n"  "GPU Busy"  "$gpu"
        printf "  %-25s %s MHz\n" "GPU Clock" "$gpu_clk"

        echo ""
        echo "  TRIP POINTS (cpu0-thermal):"
        zone_dir=$(get_zone_by_type "cpu0-thermal")
        raw=$(get_zone_temp_raw "${zone_dir:-/sys/class/thermal/thermal_zone10}")
        for t in 65 80 90 110 118 125; do
            if [ "$raw" -ge "$((t * 1000))" ]; then
                printf "  %3d°C: CROSSED\n" "$t"
            else
                printf "  %3d°C: ok\n" "$t"
            fi
        done

    } > /dev/tty

    sleep 2
done