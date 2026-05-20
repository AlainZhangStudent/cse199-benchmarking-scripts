#!/bin/bash

# Configuration
LOG_FILE="cpu_thermal_log.csv"
INTERVAL=1

# Initialize CSV Header if file doesn't exist
if [ ! -f "$LOG_FILE" ]; then
    echo "Timestamp,Sensor_Type,Temp_Celsius" > "$LOG_FILE"
fi

echo "Logging CPU thermal sensors to $LOG_FILE..."
echo "Press [CTRL+C] to stop."

while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    for zone in /sys/class/thermal/thermal_zone*; do
        if [ -f "$zone/temp" ]; then
            TYPE=$(cat "$zone/type")
            
            # Filter for CPU and APC sensors
            if [[ "$TYPE" == *"cpu"* || "$TYPE" == *"apc"* ]]; then
                RAW_TEMP=$(cat "$zone/temp")
                
                if [ "$RAW_TEMP" -gt 0 ]; then
                    # Standard conversion (divide by 1000)
                    TEMP=$(awk "BEGIN {print $RAW_TEMP/1000}")
                    
                    # Append data to the CSV file
                    echo "$TIMESTAMP,$TYPE,$TEMP" >> "$LOG_FILE"
                fi
            fi
        fi
    done
    
    sleep "$INTERVAL"
done
