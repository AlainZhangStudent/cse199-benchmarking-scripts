#!/bin/bash

LOGS_DIR="logs/cpu"
mkdir -p "$LOGS_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
SESSION_FILE="$LOGS_DIR/cpu_stress_${TIMESTAMP}.log"
TEMP_FILE="logs/temp/temp_${TIMESTAMP}.csv"
POWER_FILE="logs/power/power_${TIMESTAMP}.csv"
METRICS_FILE="logs/cpu/cpu_metrics_${TIMESTAMP}.csv"
STAGE_FILE="/tmp/current_stage_${TIMESTAMP}.txt"

mkdir -p logs/temp logs/power logs/cpu

echo "idle" > "$STAGE_FILE"

# Start all loggers in background
./temp_benchmark.sh "$TEMP_FILE" "$STAGE_FILE" &
TEMP_PID=$!

./power_benchmark.sh "$POWER_FILE" "$STAGE_FILE" &
POWER_PID=$!

./cpu_metrics.sh "$METRICS_FILE" "$STAGE_FILE" &
METRICS_PID=$!

echo "CPU Benchmark | Logging to: $SESSION_FILE"
echo "Started: $(date)" | tee "$SESSION_FILE"

echo "=== STAGE 1: Single Core ===" | tee -a "$SESSION_FILE"
echo "stage1_single_core" > "$STAGE_FILE"
stress-ng --cpu 1 --timeout 60s --metrics 2>&1 | tee -a "$SESSION_FILE"

echo "=== STAGE 2: All Cores ===" | tee -a "$SESSION_FILE"
echo "stage2_all_cores" > "$STAGE_FILE"
stress-ng --cpu 0 --timeout 60s --metrics 2>&1 | tee -a "$SESSION_FILE"

echo "=== STAGE 3: All Cores + Memory ===" | tee -a "$SESSION_FILE"
echo "stage3_all_cores_memory" > "$STAGE_FILE"
stress-ng --cpu 0 --vm 4 --vm-bytes 70% --timeout 60s --metrics 2>&1 | tee -a "$SESSION_FILE"

echo "=== STAGE 4: All Cores + Memory + IO ===" | tee -a "$SESSION_FILE"
echo "stage4_all_cores_memory_io" > "$STAGE_FILE"
stress-ng --cpu 0 --vm 4 --vm-bytes 70% --hdd 1 --timeout 60s --metrics 2>&1 | tee -a "$SESSION_FILE"

echo "completed" > "$STAGE_FILE"
echo "Completed: $(date)" | tee -a "$SESSION_FILE"

# Stop all background loggers
kill $TEMP_PID $POWER_PID $METRICS_PID 2>/dev/null
rm "$STAGE_FILE"

# Auto parse stress results
./parse_cpu.sh "$SESSION_FILE"

echo "Done. Files:"
echo "  Stress:      $SESSION_FILE"
echo "  Temperature: $TEMP_FILE"
echo "  Power:       $POWER_FILE"
echo "  Metrics:     $METRICS_FILE"
echo "  Parsed CSV:  ${SESSION_FILE%.log}_parsed.csv"
