#!/bin/bash
# benchmarks/collectors/cpu_metrics.sh
# System-level CPU telemetry: frequencies, memory, load, idle states.
#
# Usage: cpu_metrics.sh OUTPUT.csv [STAGE_FILE]

source "$(dirname "$0")/../lib.sh"

SESSION_FILE="${1:-logs/cpu/cpu_metrics_$(date +%Y-%m-%d_%H-%M-%S).csv}"
STAGE_FILE="${2:-/tmp/stage.txt}"
mkdir -p "$(dirname "$SESSION_FILE")"

csv_init "$SESSION_FILE" \
    "time,stage,\
load_1m,load_5m,load_15m,\
mem_total_kb,mem_free_kb,mem_available_kb,mem_active_kb,\
cpu0_khz,cpu1_khz,cpu2_khz,cpu3_khz,cpu4_khz,cpu5_khz,cpu6_khz,cpu7_khz,\
cpu0_idle,cpu1_idle,cpu2_idle,cpu3_idle,cpu4_idle,cpu5_idle,cpu6_idle,cpu7_idle,\
ctx_switches,procs_running,procs_blocked"

echo "[cpu_metrics] Logging to: $SESSION_FILE"

while true; do
    stage=$(get_stage)

    read load1 load5 load15 _ < /proc/loadavg

    mem_total=$(awk '/MemTotal/    {print $2}' /proc/meminfo)
    mem_free=$(awk '/MemFree/      {print $2}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    mem_active=$(awk '/^Active:/   {print $2}' /proc/meminfo)

    freqs=""
    for i in 0 1 2 3 4 5 6 7; do
        freqs="${freqs},$(get_cpu_freq_khz $i)"
    done
    freqs="${freqs#,}"

    idle_states=""
    for i in 0 1 2 3 4 5 6 7; do
        state="active"
        for s in /sys/devices/system/cpu/cpu${i}/cpuidle/state*/time; do
            usage=$(cat "$(dirname $s)/usage" 2>/dev/null || echo 0)
            name=$(cat "$(dirname $s)/name"  2>/dev/null)
            [ "$usage" -gt 0 ] && state="$name"
        done
        idle_states="${idle_states},${state}"
    done
    idle_states="${idle_states#,}"

    ctx=$(grep "^ctxt"          /proc/stat | awk '{print $2}')
    procs_r=$(grep "^procs_running" /proc/stat | awk '{print $2}')
    procs_b=$(grep "^procs_blocked" /proc/stat | awk '{print $2}')

    csv_append "$SESSION_FILE" \
        "$(date +%T),$stage,$load1,$load5,$load15,\
$mem_total,$mem_free,$mem_avail,$mem_active,\
$freqs,$idle_states,$ctx,$procs_r,$procs_b"

    sleep 1
done