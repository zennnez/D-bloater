#!/system/bin/sh
# Bootloop guard: if boot never completed 3 times in a row while systemless
# removals exist, disable the module so the next boot is clean.
MODDIR=${0%/*}
DATA=/data/adb/dbloater
mkdir -p "$DATA" 2>/dev/null

CNT=$(cat "$DATA/bootcount" 2>/dev/null)
[ -n "$CNT" ] || CNT=0
CNT=$((CNT + 1))
echo "$CNT" > "$DATA/bootcount"

if [ "$CNT" -ge 3 ] && ls "$DATA/sysrm/"* >/dev/null 2>&1; then
  touch "$MODDIR/disable"
  echo "0" > "$DATA/bootcount"
  echo "$(date '+%F %T') GUARD boot failed $CNT times, module disabled (re-enable it in your manager)" >> "$DATA/log.txt"
fi
