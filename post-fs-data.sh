#!/system/bin/sh
# Bootloop guard: if boot never completed 3 times in a row while systemless
# removals exist, undo the newest one (repeats until the boot works).
MODDIR=${0%/*}
DATA=/data/adb/dbloater
mkdir -p "$DATA" 2>/dev/null

CNT=$(cat "$DATA/bootcount" 2>/dev/null)
[ -n "$CNT" ] || CNT=0
CNT=$((CNT + 1))
echo "$CNT" > "$DATA/bootcount"

if [ "$CNT" -ge 3 ] && ls "$DATA/sysrm/"* >/dev/null 2>&1; then
  echo "0" > "$DATA/bootcount"
  echo "$(date '+%F %T') GUARD boot failed $CNT times, undoing the newest systemless removal" >> "$DATA/log.txt"
  sh "$MODDIR/bin/dbl.sh" revertlast >/dev/null 2>&1
fi

# Hide the recorded apps through NoMount before the package manager scans
sh "$MODDIR/bin/dbl.sh" nmapply >/dev/null 2>&1
