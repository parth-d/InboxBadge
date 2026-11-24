#!/bin/bash
# Per-minute view of InboxBadge's CPU time, thread count and idle wakeups, so quiet minutes
# (no new mail) can be told apart from busy ones. Usage: tools/energy-minutes.sh [minutes] [warmup-seconds]
set -u
mins=${1:-10}
warmup=${2:-120}
pid=$(pgrep -x InboxBadge) || { echo "InboxBadge is not running"; exit 1; }
cpu() { ps -o time= -p "$pid" | awk '{ n = split($1, a, ":"); s = a[n]; m = a[n-1]; h = (n >= 3 ? a[n-2] : 0); printf "%.2f", h*3600 + m*60 + s }'; }
sleep "$warmup"
prev=$(cpu)
for i in $(seq 1 "$mins"); do
  sleep 55
  now=$(cpu)
  threads=$(ps -M -p "$pid" | tail -n +2 | wc -l | tr -d ' ')
  idlew=$(top -l 2 -s 3 -pid "$pid" -stats idlew 2>/dev/null | tail -1 | tr -d ' ')
  sleep 2
  now=$(cpu)
  echo "$(date +%H:%M:%S) cpu_delta=$(awk -v a="$prev" -v b="$now" 'BEGIN{printf "%.2f", b-a}')s threads=$threads idlew=$idlew"
  prev=$now
done
