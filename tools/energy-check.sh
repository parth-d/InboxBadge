#!/bin/bash
# Measures InboxBadge's CPU time over a window. Usage: tools/energy-check.sh [minutes] ["Process name to compare"]
# Leave the Mac idle (display asleep or not, note which) and note whether it is on battery.
set -u
mins=${1:-60}
compare=${2:-}
pid=$(pgrep -x InboxBadge) || { echo "InboxBadge is not running"; exit 1; }
cpu_seconds() {
  ps -o time= -p "$1" 2>/dev/null | awk '{ n = split($1, a, ":"); s = a[n]; m = a[n-1]; h = (n >= 3 ? a[n-2] : 0); printf "%.2f", h*3600 + m*60 + s }'
}
sum_cpu() {
  ps -axo time=,command= | grep -F "$1" | grep -v grep | awk '{ n = split($1, a, ":"); s = a[n]; m = a[n-1]; h = (n >= 3 ? a[n-2] : 0); t += h*3600 + m*60 + s } END { printf "%.2f", t }'
}
power() { pmset -g batt | head -1 | sed "s/Now drawing from //"; }
start_cpu=$(cpu_seconds "$pid"); start_cmp=""; [ -n "$compare" ] && start_cmp=$(sum_cpu "$compare")
echo "start: $(date '+%H:%M:%S')  source: $(power)  InboxBadge cpu: ${start_cpu}s"
sleep $((mins * 60))
pgrep -x InboxBadge | grep -qx "$pid" || { echo "InboxBadge restarted during the window; result invalid"; exit 1; }
end_cpu=$(cpu_seconds "$pid")
echo "end:   $(date '+%H:%M:%S')  source: $(power)  InboxBadge cpu: ${end_cpu}s"
awk -v a="$start_cpu" -v b="$end_cpu" -v m="$mins" 'BEGIN { d = b - a; printf "InboxBadge CPU time over %d min: %.2f s (%.4f%% of one core); gate: < 5 s per 60 min: %s\n", m, d, d / (m * 60) * 100, (d * 60 / m < 5 ? "PASS" : "FAIL") }'
if [ -n "$compare" ]; then
  end_cmp=$(sum_cpu "$compare")
  awk -v a="$start_cmp" -v b="$end_cmp" -v n="$compare" 'BEGIN { printf "%s (all processes) CPU time over the same window: %.2f s\n", n, b - a }'
fi
top -l 2 -s 5 -pid "$pid" -stats pid,command,cpu,idlew,power 2>/dev/null | tail -2
