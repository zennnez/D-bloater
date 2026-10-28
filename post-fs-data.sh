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

# Purge dangling partition overlay directories that mask SAR partitions
rm -rf "$MODDIR/system/product" "$MODDIR/system/system_ext" "$MODDIR/system/vendor" "$MODDIR/system/odm" "$MODDIR/system/my_"* 2>/dev/null

# Ensure system/bin/dbl wrapper is ready so CLI works and NoMount identifies module as active
[ -x "$MODDIR/system/bin/dbl" ] || {
  mkdir -p "$MODDIR/system/bin"
  ln -sf "$MODDIR/bin/dbl.sh" "$MODDIR/system/bin/dbl" 2>/dev/null || cp -f "$MODDIR/bin/dbl.sh" "$MODDIR/system/bin/dbl"
  chmod 755 "$MODDIR/system/bin/dbl"
}

# Hide the recorded apps through NoMount before the package manager scans
sh "$MODDIR/bin/dbl.sh" nmapply >/dev/null 2>&1
