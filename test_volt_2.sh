#!/bin/bash

LOGS_DIR="logs/combined"
mkdir -p "$LOGS_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
VOLTAGE_FILE="$LOGS_DIR/voltage_monitor_${TIMESTAMP}.csv"

IIO0=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-08/c440000.spmi:pmic@8:adc@3100/iio:device0

# Check KGSL is loaded before running
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
    echo "FATAL: Cannot find /dev/kgsl-3d0 - GPU benchmarks will be invalid"
    echo "Exiting."
    exit 1
fi

echo "KGSL confirmed: /dev/kgsl-3d0 exists"

echo "time,stage,vph_pwr_mv,gpu_busy_pct,cpu4_freq_mhz,note" > "$VOLTAGE_FILE"
sync "$VOLTAGE_FILE"

# Background voltage logger with sync
(
    while true; do
        vph=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
        vph_mv=$(awk "BEGIN {printf \"%.2f\", $vph/1000}")
        gpu_busy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print $1}')
        cpu4_freq=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
        cpu4_mhz=$(awk "BEGIN {printf \"%.0f\", $cpu4_freq/1000}")
        stage=$(cat /tmp/voltage_stage 2>/dev/null || echo "unknown")

        note=""
        if awk "BEGIN {exit !($vph_mv < 3800)}"; then
            note="LOW_VOLTAGE"
        fi
        if awk "BEGIN {exit !($vph_mv < 3500)}"; then
            note="CRITICAL"
        fi

        echo "$(date +%T),$stage,$vph_mv,$gpu_busy,$cpu4_mhz,$note" >> "$VOLTAGE_FILE"
        sync "$VOLTAGE_FILE"
        sleep 0.1
    done
) &
LOGGER_PID=$!

# Live display function
show_status() {
    local stage=$1
    vph=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
    vph_mv=$(awk "BEGIN {printf \"%.2f\", $vph/1000}")
    gpu_busy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print $1}')
    cpu4_freq=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    cpu4_mhz=$(awk "BEGIN {printf \"%.0f\", $cpu4_freq/1000}")
    temp=$(cat /sys/class/thermal/thermal_zone10/temp 2>/dev/null || echo 0)
    temp_c=$(awk "BEGIN {printf \"%.1f\", $temp/1000}")

    clear
    echo "============================================"
    echo "  Voltage Drop Test | $(date +%H:%M:%S)"
    echo "  Stage: $stage"
    echo "============================================"
    printf "  %-25s %s mV" "System Rail (vph_pwr):" "$vph_mv"
    if awk "BEGIN {exit !($vph_mv < 3800)}"; then
        echo "  !!! LOW VOLTAGE !!!"
    else
        echo "  OK"
    fi
    printf "  %-25s %s MHz\n" "CPU4 Frequency:" "$cpu4_mhz"
    printf "  %-25s %s %%\n" "GPU Busy:" "$gpu_busy"
    printf "  %-25s %s C\n" "CPU0 Temp:" "$temp_c"
    printf "  %-25s %s\n" "KGSL Device:" "$(ls /dev/kgsl-3d0 2>/dev/null || echo NOT FOUND)"
    echo "  Logging to: $VOLTAGE_FILE"
    echo "============================================"
}

# Stage 1 - Idle baseline
echo "idle" > /tmp/voltage_stage
echo "Recording idle baseline for 10 seconds..."
for i in $(seq 1 10); do
    show_status "IDLE BASELINE"
    sleep 1
done

# Stage 2 - CPU only
echo "cpu_only" > /tmp/voltage_stage
echo "Starting CPU stress..."
stress-ng --cpu 8 --timeout 60s &
STRESS_PID=$!

while kill -0 $STRESS_PID 2>/dev/null; do
    show_status "CPU ONLY STRESS"
    sleep 1
done

echo "CPU stress done. Cooling down 15 seconds..."
echo "cooldown_cpu" > /tmp/voltage_stage
for i in $(seq 1 15); do
    show_status "COOLDOWN"
    sleep 1
done

# Stage 3 - GPU only
echo "gpu_only" > /tmp/voltage_stage
echo "Starting GPU stress..."
sudo docker run -d \
    --name gpu_only_${TIMESTAMP} \
    --privileged \
    --user root \
    --device=/dev/kgsl-3d0 \
    ghcr.io/kastnerrg/cse160-opencl:gpu-adreno \
    /bin/bash -c "source /usr/lib/qcom-adreno/qcom-adreno-vars.sh && while true; do dlprim_flops 0:0; done"

for i in $(seq 1 60); do
    show_status "GPU ONLY STRESS"
    sleep 1
done

sudo docker stop gpu_only_${TIMESTAMP} 2>/dev/null
sudo docker rm gpu_only_${TIMESTAMP} 2>/dev/null

echo "GPU stress done. Cooling down 15 seconds..."
echo "cooldown_gpu" > /tmp/voltage_stage
for i in $(seq 1 15); do
    show_status "COOLDOWN"
    sleep 1
done

# Stage 4 - CPU + GPU combined
echo "cpu_gpu_combined" > /tmp/voltage_stage
echo "Starting combined CPU + GPU stress..."
sudo docker run -d \
    --name gpu_combined_${TIMESTAMP} \
    --privileged \
    --user root \
    --device=/dev/kgsl-3d0 \
    ghcr.io/kastnerrg/cse160-opencl:gpu-adreno \
    /bin/bash -c "source /usr/lib/qcom-adreno/qcom-adreno-vars.sh && while true; do dlprim_flops 0:0; done"

sleep 5
stress-ng --cpu 8 --timeout 60s &
STRESS_PID=$!

while kill -0 $STRESS_PID 2>/dev/null; do
    show_status "CPU + GPU COMBINED"
    sleep 1
done

sudo docker stop gpu_combined_${TIMESTAMP} 2>/dev/null
sudo docker rm gpu_combined_${TIMESTAMP} 2>/dev/null

# Stop logger
kill $LOGGER_PID 2>/dev/null
rm /tmp/voltage_stage 2>/dev/null

echo ""
echo "Done. Results saved to: $VOLTAGE_FILE"
echo ""
echo "Summary by stage:"
echo "--- IDLE ---"
grep "idle" "$VOLTAGE_FILE" | awk -F',' '{sum+=$3; count++} END {printf "  Avg voltage: %.2f mV\n", sum/count}'
echo "--- CPU ONLY ---"
grep "cpu_only" "$VOLTAGE_FILE" | awk -F',' '{sum+=$3; count++; if($3<min||min=="")min=$3} END {printf "  Avg: %.2f mV  Min: %.2f mV\n", sum/count, min}'
echo "--- GPU ONLY ---"
grep "gpu_only" "$VOLTAGE_FILE" | awk -F',' '{sum+=$3; count++; if($3<min||min=="")min=$3} END {printf "  Avg: %.2f mV  Min: %.2f mV\n", sum/count, min}'
echo "--- CPU + GPU ---"
grep "cpu_gpu_combined" "$VOLTAGE_FILE" | awk -F',' '{sum+=$3; count++; if($3<min||min=="")min=$3} END {printf "  Avg: %.2f mV  Min: %.2f mV\n", sum/count, min}'

