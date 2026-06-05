#!/bin/bash
# benchmarks/runners/cpu_bench.sh
# Staged CPU benchmark: single core → all cores → +memory → +IO
# Launches collectors, runs stages, parses results.
#
# Usage: ./runners/cpu_bench.sh

source "$(dirname "$0")/../lib.sh"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
init_stage_file "$TIMESTAMP"

mkdir -p logs/temp logs/power logs/cpu

TEMP_FILE="logs/temp/temp_${TIMESTAMP}.csv"
POWER_FILE="logs/power/power_${TIMESTAMP}.csv"
METRICS_FILE="logs/cpu/cpu_metrics_${TIMESTAMP}.csv"
SESSION_FILE="logs/cpu/cpu_stress_${TIMESTAMP}.log"

# ── Start collectors ──────────────────────────────────────────────────────────
"$(dirname "$0")/../collectors/temp.sh"        "$TEMP_FILE"    "$STAGE_FILE" &
TEMP_PID=$!

"$(dirname "$0")/../collectors/power.sh"       "$POWER_FILE"   "$STAGE_FILE" &
POWER_PID=$!

"$(dirname "$0")/../collectors/cpu_metrics.sh" "$METRICS_FILE" "$STAGE_FILE" &
METRICS_PID=$!

# Confirm collectors started
sleep 2
check_pids "temp" $TEMP_PID "power" $POWER_PID "cpu_metrics" $METRICS_PID
sleep 1
check_files "$TEMP_FILE" "$POWER_FILE" "$METRICS_FILE"

# ── Benchmark stages ──────────────────────────────────────────────────────────
echo "CPU Benchmark | $(date)" | tee "$SESSION_FILE"

echo "=== STAGE 1: Single Core ===" | tee -a "$SESSION_FILE"
set_stage "stage1_single_core"
stress-ng --cpu 1 --timeout 60s --metrics 2>&1 | tee -a "$SESSION_FILE"

echo "=== STAGE 2: All Cores ===" | tee -a "$SESSION_FILE"
set_stage "stage2_all_cores"
stress-ng --cpu 0 --timeout 60s --metrics 2>&1 | tee -a "$SESSION_FILE"

echo "=== STAGE 3: All Cores + Memory ===" | tee -a "$SESSION_FILE"
set_stage "stage3_memory"
stress-ng --cpu 0 --vm 4 --vm-bytes 70% --timeout 60s --metrics 2>&1 | tee -a "$SESSION_FILE"

echo "=== STAGE 4: All Cores + Memory + IO ===" | tee -a "$SESSION_FILE"
set_stage "stage4_io"
stress-ng --cpu 0 --vm 4 --vm-bytes 70% --hdd 1 --timeout 60s --metrics 2>&1 | tee -a "$SESSION_FILE"

# ── Cleanup ───────────────────────────────────────────────────────────────────
set_stage "completed"
kill $TEMP_PID $POWER_PID $METRICS_PID 2>/dev/null
rm -f "$STAGE_FILE"

echo "Completed: $(date)" | tee -a "$SESSION_FILE"

# Auto-parse
"$(dirname "$0")/../parse_cpu.sh" "$SESSION_FILE"

echo ""
echo "Files:"
echo "  Stress log:  $SESSION_FILE"
echo "  Temperature: $TEMP_FILE"
echo "  Power:       $POWER_FILE"
echo "  Metrics:     $METRICS_FILE"
echo "  Parsed CSV:  ${SESSION_FILE%.log}_parsed.csv"