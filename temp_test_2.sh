#!/bin/bash

LOGS_DIR="logs/combined"
BENCH_DIR="$HOME/benchmarks"
mkdir -p "$LOGS_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
SESSION_FILE="$LOGS_DIR/combined_stress_${TIMESTAMP}.log"
TEMP_FILE="logs/temp/temp_${TIMESTAMP}.csv"
POWER_FILE="logs/power/power_${TIMESTAMP}.csv"
METRICS_FILE="logs/cpu/cpu_metrics_${TIMESTAMP}.csv"
STAGE_FILE="/tmp/current_stage_${TIMESTAMP}.txt"
JOURNAL_FILE="$LOGS_DIR/journal_${TIMESTAMP}.log"
WATCHDOG_FILE="$LOGS_DIR/watchdog_${TIMESTAMP}.csv"
THERMAL_FILE="$LOGS_DIR/thermal_${TIMESTAMP}.csv"
PEAK_FILE="$LOGS_DIR/peak_summary_${TIMESTAMP}.txt"

mkdir -p logs/temp logs/power logs/cpu

# Check KGSL is loaded
if ! lsmod | grep -q msm_kgsl; then
    echo "msm_kgsl not loaded, attempting to load..."
    sudo modprobe msm_kgsl
    sleep 2
fi

if [ ! -e /dev/kgsl-3d0 ]; then
    echo "kgsl-3d0 not found, triggering udev..."
    sudo udevadm trigger --subsystem-match=kgsl
    sleep 1
fi

if [ ! -e /dev/kgsl-3d0 ]; then
    echo "FATAL: Cannot find /dev/kgsl-3d0 - GPU benchmarks will be invalid. Exiting."
    exit 1
fi

echo "KGSL confirmed: /dev/kgsl-3d0 exists"
echo "combined_cpu_gpu" > "$STAGE_FILE"
sync

# Start background loggers using correct path
"$BENCH_DIR/temp_benchmark.sh" "$TEMP_FILE" "$STAGE_FILE" &
TEMP_PID=$!

"$BENCH_DIR/power_benchmark.sh" "$POWER_FILE" "$STAGE_FILE" &
POWER_PID=$!

"$BENCH_DIR/cpu_metrics.sh" "$METRICS_FILE" "$STAGE_FILE" &
METRICS_PID=$!

# Journal logger
(
    journalctl -f --no-pager 2>/dev/null | while IFS= read -r line; do
        echo "$line" >> "$JOURNAL_FILE"
        sync "$JOURNAL_FILE"
    done
) &
JOURNAL_PID=$!

# Watchdog at 0.1s
(
    IIO0=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-08/c440000.spmi:pmic@8:adc@3100/iio:device0
    echo "time,vph_pwr_mv,gpu_busy_pct,cpu0_freq_mhz,cpu4_freq_mhz,note" > "$WATCHDOG_FILE"
    sync "$WATCHDOG_FILE"

    while true; do
        vph=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
        vph_mv=$(awk "BEGIN {printf \"%.2f\", $vph/1000}")
        gpu_busy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print $1}')
        cpu0_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
        cpu4_freq=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
        cpu0_mhz=$(awk "BEGIN {printf \"%.0f\", $cpu0_freq/1000}")
        cpu4_mhz=$(awk "BEGIN {printf \"%.0f\", $cpu4_freq/1000}")

        note=""
        if awk "BEGIN {exit !($vph_mv < 3800)}"; then note="LOW_VOLTAGE_WARNING"; fi
        if awk "BEGIN {exit !($vph_mv < 3500)}"; then note="CRITICAL_VOLTAGE"; fi

        echo "$(date +%T),$vph_mv,$gpu_busy,$cpu0_mhz,$cpu4_mhz,$note" >> "$WATCHDOG_FILE"
        sync "$WATCHDOG_FILE"
        sleep 0.1
    done
) &
WATCHDOG_PID=$!

# Thermal trip monitor
(
    echo "time,zone,type,temp_c,trip_point,event" > "$THERMAL_FILE"
    sync "$THERMAL_FILE"
    TRIP_POINTS=(65000 80000 90000 110000 118000 125000)
    declare -A PREV_TRIPS

    while true; do
        for zone in /sys/class/thermal/thermal_zone*; do
            if [ -f "$zone/temp" ]; then
                temp=$(cat "$zone/temp" 2>/dev/null || echo 0)
                type=$(cat "$zone/type" 2>/dev/null || echo "unknown")
                zone_id=$(basename "$zone")
                for trip in "${TRIP_POINTS[@]}"; do
                    key="${zone_id}_${trip}"
                    temp_c=$(awk "BEGIN {printf \"%.1f\", $temp/1000}")
                    trip_c=$(awk "BEGIN {printf \"%.1f\", $trip/1000}")
                    if [ "$temp" -ge "$trip" ] && [ "${PREV_TRIPS[$key]}" != "triggered" ]; then
                        echo "$(date +%T),$zone_id,$type,$temp_c,$trip_c,TRIP_CROSSED" >> "$THERMAL_FILE"
                        sync "$THERMAL_FILE"
                        PREV_TRIPS[$key]="triggered"
                    elif [ "$temp" -lt "$trip" ] && [ "${PREV_TRIPS[$key]}" = "triggered" ]; then
                        echo "$(date +%T),$zone_id,$type,$temp_c,$trip_c,TRIP_CLEARED" >> "$THERMAL_FILE"
                        sync "$THERMAL_FILE"
                        PREV_TRIPS[$key]=""
                    fi
                done
            fi
        done
        sleep 1
    done
) &
THERMAL_PID=$!

# Peak temperature tracker
declare -A PEAK_TEMPS
declare -A PEAK_TIMES
MIN_VOLTAGE=9999
MIN_VOLT_TIME=""

(
    IIO0=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-08/c440000.spmi:pmic@8:adc@3100/iio:device0
    while true; do
        # Track peak temps
        for zone in /sys/class/thermal/thermal_zone*; do
            if [ -f "$zone/temp" ]; then
                type=$(cat "$zone/type" 2>/dev/null || echo "unknown")
                temp=$(cat "$zone/temp" 2>/dev/null || echo 0)
                temp_c=$(awk "BEGIN {printf \"%.1f\", $temp/1000}")
                current_peak=$(cat "/tmp/peak_${type}" 2>/dev/null || echo 0)
                if awk "BEGIN {exit !($temp > $current_peak)}"; then
                    echo "$temp" > "/tmp/peak_${type}"
                    echo "$(date +%T)" > "/tmp/peaktime_${type}"
                fi
            fi
        done

        # Track min voltage
        vph=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
        vph_mv=$(awk "BEGIN {printf \"%.2f\", $vph/1000}")
        current_min=$(cat /tmp/min_voltage 2>/dev/null || echo 9999)
        if awk "BEGIN {exit !($vph_mv < $current_min)}"; then
            echo "$vph_mv" > /tmp/min_voltage
            echo "$(date +%T)" > /tmp/min_voltage_time
        fi

        sleep 1
    done
) &
PEAK_PID=$!

# Live display writes to /dev/tty to avoid conflicting with piped output
(
    IIO0=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-08/c440000.spmi:pmic@8:adc@3100/iio:device0

    # Key zones to display
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

    while true; do
        {
            echo "--------------------------------------------"
            echo "  $(date +%H:%M:%S) | KGSL: $(ls /dev/kgsl-3d0 2>/dev/null && echo OK || echo MISSING)"
            echo "--------------------------------------------"
            echo "  KEY TEMPERATURES:"

            for type in "${KEY_ZONES[@]}"; do
                zone=$(grep -l "^${type}$" /sys/class/thermal/thermal_zone*/type 2>/dev/null | head -1)
                if [ -n "$zone" ]; then
                    zone_dir=$(dirname "$zone")
                    temp=$(cat "$zone_dir/temp" 2>/dev/null || echo 0)
                    temp_c=$(awk "BEGIN {printf \"%.1f\", $temp/1000}")
                    peak_raw=$(cat "/tmp/peak_${type}" 2>/dev/null || echo 0)
                    peak_c=$(awk "BEGIN {printf \"%.1f\", $peak_raw/1000}")

                    if [ "$temp" -ge 90000 ]; then
                        status="!!! CRITICAL !!!"
                    elif [ "$temp" -ge 80000 ]; then
                        status="** HOT **"
                    elif [ "$temp" -ge 65000 ]; then
                        status="* WARM *"
                    else
                        status="ok"
                    fi
                    printf "  %-25s %5s°C  (peak: %5s°C)  %s\n" "$type" "$temp_c" "$peak_c" "$status"
                fi
            done

            echo ""
            echo "  ALL CPU CORES:"
            for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
                zone=$(grep -l "^cpu${i}-thermal$" /sys/class/thermal/thermal_zone*/type 2>/dev/null | head -1)
                if [ -n "$zone" ]; then
                    zone_dir=$(dirname "$zone")
                    temp=$(cat "$zone_dir/temp" 2>/dev/null || echo 0)
                    temp_c=$(awk "BEGIN {printf \"%.1f\", $temp/1000}")
                    freq=$(cat /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
                    mhz=$(awk "BEGIN {printf \"%.0f\", $freq/1000}")
                    if [ "$i" -lt 4 ]; then cluster="eff"; else cluster="perf"; fi
                    printf "  CPU%-2d (%s): %5s°C  %4s MHz\n" "$i" "$cluster" "$temp_c" "$mhz"
                fi
            done

            echo ""
            vph=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
            vph_mv=$(awk "BEGIN {printf \"%.2f\", $vph/1000}")
            min_v=$(cat /tmp/min_voltage 2>/dev/null || echo "N/A")
            gpu_busy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print $1}')
            gpu_clk=$(cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null || echo 0)

            if awk "BEGIN {exit !($vph_mv < 3800)}"; then
                volt_status="!!! LOW VOLTAGE !!!"
            else
                volt_status="ok"
            fi

            printf "  %-25s %s mV  (min: %s mV)  %s\n" "vph_pwr" "$vph_mv" "$min_v" "$volt_status"
            printf "  %-25s %s %%\n" "GPU Busy" "$gpu_busy"
            printf "  %-25s %s MHz\n" "GPU Clock" "$gpu_clk"

            echo ""
            echo "  TRIP POINTS (cpu0-thermal):"
            current_temp=$(cat /sys/class/thermal/thermal_zone10/temp 2>/dev/null || echo 0)
            for t in 65 80 90 110 118 125; do
                if [ "$current_temp" -ge "$((t * 1000))" ]; then
                    printf "  %3d°C: CROSSED\n" "$t"
                else
                    printf "  %3d°C: ok\n" "$t"
                fi
            done
        } > /dev/tty
        sleep 2
    done
) &
DISPLAY_PID=$!

echo "Combined CPU+GPU Stress | Logging to: $SESSION_FILE"
echo "Started: $(date)" | tee "$SESSION_FILE"
sync "$SESSION_FILE"

echo "Starting GPU stress in Docker..." | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"

sudo docker run -d \
    --name gpu_stress_${TIMESTAMP} \
    --privileged \
    --user root \
    --device=/dev/kgsl-3d0 \
    -v /home/ubuntu:/host \
    ghcr.io/kastnerrg/cse160-opencl:gpu-adreno \
    /bin/bash -c "source /usr/lib/qcom-adreno/qcom-adreno-vars.sh && while true; do dlprim_flops 0:0; done"

echo "Waiting for Docker to initialize..." | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"
sleep 5

echo "Starting CPU stress..." | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"

stress-ng --cpu 8 --timeout 120s --metrics 2>&1 | while IFS= read -r line; do
    echo "$line" >> "$SESSION_FILE"
    sync "$SESSION_FILE"
done

# Kill display BEFORE printing completion to avoid ASCII corruption
kill $DISPLAY_PID 2>/dev/null
sleep 0.5

echo "CPU stress completed: $(date)" | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"

sudo docker stop gpu_stress_${TIMESTAMP} 2>/dev/null
sudo docker rm gpu_stress_${TIMESTAMP} 2>/dev/null

echo "Completed: $(date)" | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"

# Stop all background processes
kill $TEMP_PID $POWER_PID $METRICS_PID $JOURNAL_PID $WATCHDOG_PID $THERMAL_PID $PEAK_PID 2>/dev/null
rm "$STAGE_FILE"

# Generate peak summary
echo "============================================" | tee "$PEAK_FILE"
echo "  PEAK TEMPERATURE SUMMARY" | tee -a "$PEAK_FILE"
echo "  Run: $TIMESTAMP" | tee -a "$PEAK_FILE"
echo "============================================" | tee -a "$PEAK_FILE"

for zone in /sys/class/thermal/thermal_zone*; do
    if [ -f "$zone/type" ]; then
        type=$(cat "$zone/type" 2>/dev/null)
        peak_raw=$(cat "/tmp/peak_${type}" 2>/dev/null || echo 0)
        peak_c=$(awk "BEGIN {printf \"%.1f\", $peak_raw/1000}")
        peak_time=$(cat "/tmp/peaktime_${type}" 2>/dev/null || echo "N/A")
        if [ "$peak_raw" -gt 0 ]; then
            printf "  %-30s peak: %6s°C  at %s\n" "$type" "$peak_c" "$peak_time" | tee -a "$PEAK_FILE"
        fi
    fi
done

echo "" | tee -a "$PEAK_FILE"
min_v=$(cat /tmp/min_voltage 2>/dev/null || echo "N/A")
min_v_time=$(cat /tmp/min_voltage_time 2>/dev/null || echo "N/A")
echo "  Min vph_pwr voltage: ${min_v} mV  at ${min_v_time}" | tee -a "$PEAK_FILE"
echo "============================================" | tee -a "$PEAK_FILE"

# Cleanup temp files
rm -f /tmp/peak_* /tmp/peaktime_* /tmp/min_voltage /tmp/min_voltage_time

echo ""
echo "Done. Files:"
echo "  Stress log:    $SESSION_FILE"
echo "  Temperature:   $TEMP_FILE"
echo "  Power:         $POWER_FILE"
echo "  Metrics:       $METRICS_FILE"
echo "  Watchdog:      $WATCHDOG_FILE"
echo "  Thermal trips: $THERMAL_FILE"
echo "  Peak summary:  $PEAK_FILE"
echo "  Journal:       $JOURNAL_FILE"
