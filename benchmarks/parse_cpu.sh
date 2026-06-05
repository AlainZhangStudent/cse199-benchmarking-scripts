#!/bin/bash
# benchmarks/parse_cpu.sh
# Parses stress-ng output logs into a structured CSV.
# Usage: parse_cpu.sh INPUT.log
# Output: INPUT_parsed.csv  (printed to stdout + saved)

LOG="$1"
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
    echo "Usage: $0 <stress_log.log>"
    exit 1
fi

OUTPUT="${LOG%.log}_parsed.csv"

echo "stage,stressor,bogo_ops,real_time_s,usr_time_s,sys_time_s,\
bogo_ops_per_s_real,bogo_ops_per_s_usr_sys,cpu_used_pct,rss_max_kb" \
    > "$OUTPUT"

STAGE=""
while IFS= read -r line; do
    if [[ "$line" == *"STAGE"* ]]; then
        STAGE=$(echo "$line" | sed 's/=//g' | xargs)
    fi

    if [[ "$line" == *"metrc"* ]] && \
       [[ "$line" != *"stressor"* ]] && \
       [[ "$line" != *"(secs)"* ]] && \
       [[ "$line" != *"miscellaneous"* ]] && \
       [[ "$line" != *"MB/sec"* ]]; then
        values=$(echo "$line" | awk '{print $4,$5,$6,$7,$8,$9,$10,$11,$12}' | tr ' ' ',')
        echo "$STAGE,$values" >> "$OUTPUT"
    fi
done < "$LOG"

echo "Parsed CSV saved to: $OUTPUT"
cat "$OUTPUT"