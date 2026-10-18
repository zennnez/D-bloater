#!/system/bin/sh
# Wait for a completed boot, clear the bootloop counter, then re-apply
# disable / user-0 uninstall states (OTAs and app updates can undo them).
MODDIR=${0%/*}
DATA=/data/adb/dbloater

until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 3
done

echo "0" > "$DATA/bootcount"
sleep 15
sh "$MODDIR/bin/dbl.sh" reapply >/dev/null 2>&1
