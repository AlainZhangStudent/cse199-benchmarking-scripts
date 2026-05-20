#!/bin/bash

SESSION_FILE="${1:-logs/cpu/cpu_metrics_$(date +%Y-%m-%d_%H-%M-%S).csv}"
STAGE_FILE="${2:-/tmp/current_stage.txt}"
mkdir -p "$(dirname "$SESSION_FILE")"

# Build header
echo "time,stage,\
load_avg_1m,load_avg_5m,load_avg_15m,\
mem_total_kb,mem_free_kb,mem_available_kb,mem_active_kb,\
cpu0_freq_khz,cpu1_freq_khz,cpu2_freq_khz,cpu3_freq_khz,\
cpu4_freq_khz,cpu5_freq_khz,cpu6_freq_khz,cpu7_freq_khz,\
cpu0_idle_state,cpu1_idle_state,cpu2_idle_state,cpu3_idle_state,\
cpu4_idle_state,cpu5_idle_state,cpu6_idle_state,cpu7_idle_state,\
ctx_switches,processes_running,processes_blocked" > "$SESSION_FILE"

echo "CPU Metrics Logger | Logging to: $SESSION_FILE"

while true; do
    STAGE=$(cat "$STAGE_FILE" 2>/dev/null || echo "unknown")

    # Load average
    read load1 load5 load15 rest < /proc/loadavg

    # Memory
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    mem_active=$(awk '/^Active:/ {print $2}' /proc/meminfo)

    # Per-core frequencies
    freqs=""
    for i in 0 1 2 3 4 5 6 7; do
        freq=$(cat /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
        freqs="$freqs,$freq"
    done
    freqs="${freqs#,}"

    # Per-core idle state (which idle state is currently active)
    idle_states=""
    for i in 0 1 2 3 4 5 6 7; do
        # Find the deepest active idle state
        state="active"
        for s in /sys/devices/system/cpu/cpu${i}/cpuidle/state*/time; do
            name=$(cat "$(dirname $s)/name" 2>/dev/null)
            usage=$(cat "$(dirname $s)/usage" 2>/dev/null || echo 0)
            if [ "$usage" -gt 0 ]; then
                state="$name"
            fi
        done
        idle_states="$idle_states,$state"
    done
    idle_states="${idle_states#,}"

    # Context switches and process states from /proc/stat
    ctx=$(grep "^ctxt" /proc/stat | awk '{print $2}')
    procs_running=$(grep "^procs_running" /proc/stat | awk '{print $2}')
    procs_blocked=$(grep "^procs_blocked" /proc/stat | awk '{print $2}')

    echo "$(date +%T),$STAGE,$load1,$load5,$load15,$mem_total,$mem_free,$mem_avail,$mem_active,$freqs,$idle_states,$ctx,$procs_running,$procs_blocked" >> "$SESSION_FILE"

    sleep 1
done
