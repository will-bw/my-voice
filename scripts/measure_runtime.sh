#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 PID [SECONDS]" >&2
    exit 2
fi

target_pid="$1"
sample_seconds="${2:-10}"

case "$target_pid:$sample_seconds" in
    *[!0-9:]*|:*|*:) echo "PID and SECONDS must be positive integers" >&2; exit 2 ;;
esac
if [ "$sample_seconds" -lt 1 ] || [ "$sample_seconds" -gt 300 ]; then
    echo "SECONDS must be between 1 and 300" >&2
    exit 2
fi
if ! kill -0 "$target_pid" 2>/dev/null; then
    echo "process $target_pid is not running" >&2
    exit 2
fi

echo "timestamp_epoch,cpu_percent,rss_kb"
remaining="$sample_seconds"
while [ "$remaining" -gt 0 ]; do
    timestamp="$(date +%s)"
    sample="$(ps -p "$target_pid" -o %cpu=,rss= | awk '{$1=$1; print}')"
    echo "$timestamp,$(echo "$sample" | tr ' ' ',')"
    sleep 1
    remaining=$((remaining - 1))
done

echo "top_snapshot"
top -l 1 -pid "$target_pid" -stats pid,cpu,mem,power | tail -n 2

echo "physical_footprint"
footprint -p "$target_pid" 2>/dev/null | awk '/phys_footprint:|phys_footprint_peak:/'

echo "network_totals"
nettop -P -L 1 -p "$target_pid" 2>/dev/null | tail -n 1
