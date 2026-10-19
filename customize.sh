#!/system/bin/sh
# D-bloater installer (KernelSU / APatch / Magisk)
SKIPUNZIP=0

ui_print "- D-bloater by zennnez"

if [ -z "$KSU" ] && [ -z "$APATCH" ]; then
  ui_print "! Not running under KernelSU/APatch."
  ui_print "! The WebUI needs a manager with WebUI support (KSU, APatch or MMRL)."
fi

# Persistent state lives outside the module so updates never lose it
mkdir -p /data/adb/dbloater/sysrm

# Module updates replace the whole module dir: carry over systemless removals
OLD=/data/adb/modules/dbloater
if [ -d "$OLD/system" ]; then
  cp -af "$OLD/system" "$MODPATH/" 2>/dev/null && ui_print "- Kept existing systemless removals"
fi

# Records from older versions carry no boot id; stamp them so the WebUI can
# tell "pending a reboot" from "rebooted but not applied"
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
for f in /data/adb/dbloater/sysrm/*; do
  [ -f "$f" ] || continue
  { read -r _d; read -r _b; } < "$f"
  [ -n "$_b" ] || { echo "$_d"; echo "$BID"; } > "$f"
done

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/dbl.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755

ui_print "- Done. Open D-bloater from your manager (WebUI button)."
