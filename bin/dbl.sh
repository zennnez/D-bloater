#!/system/bin/sh
# D-bloater backend. Usage: dbl.sh <command> [package ...]
#
# Commands
#   scan                      dump package state for the WebUI
#   info                      APK size, on-disk size and running processes
#   running                   running processes only (cheap, for live refresh)
#   disable | enable          pm disable-user / pm enable (user 0)
#   uninstall                 pm uninstall -k --user 0 (APK stays on /system)
#   restore                   cmd package install-existing (undo uninstall)
#   sysrm | sysunrm           systemless removal via module overlay (reboot)
#   restoreall                undo everything D-bloater has done
#   reapply                   re-apply disabled/uninstalled state (boot)
#   nmapply                   add NoMount whiteouts for systemless removals (post-fs-data)
#   plan <pkg>                dry run of a systemless removal
#   softreboot                apply queued removals now by restarting the framework
#   revertlast                undo the newest systemless removal (boot guard)
#   (set DBL_BACKUP=1 on sysrm to save a copy of the app folder first)
#   backup | backuprestore P  copy app-folder archives to /sdcard | reinstall from one
#   usage                     raw last-used lines for the WebUI
#   graph                     device facts for the dependency graph (UIDs, roles, settings, overlays)
#   diag                      explain why a systemless removal did or did not apply
#   log                       print the action log
#   files | readfile F        list / read import files in /sdcard/D-bloater
#   writefile F [append]      write base64 from stdin to /sdcard/D-bloater/F
#
# Output of action commands: one line per package -> STATUS|package|message

MODDIR=${DBL_MODDIR:-}
if [ -z "$MODDIR" ]; then
  _m=${0%/*/*}
  if [ -f "$_m/bin/dbl.sh" ]; then
    MODDIR=$_m
  else
    MODDIR=/data/adb/modules/dbloater
  fi
fi
DATA=${DBL_DATA:-/data/adb/dbloater}
PATH=/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH
export PATH

# NoMount (VFS metamodule) helpers. KernelSU only mounts module "system/" dirs
# through a metamodule; NoMount is preferred, so rules are also added directly.
nm_bin() {
  for _b in ${DBL_NM:-} /data/adb/ksu/bin/nm /data/adb/ap/bin/nm /data/adb/modules/nomount/bin/nm; do
    [ -x "$_b" ] && { echo "$_b"; return 0; }
  done
  return 1
}
meta_name() {
  for _d in /data/adb/modules/*; do
    [ -f "$_d/metamount.sh" ] && { echo "${_d##*/}"; return 0; }
  done
  return 1
}
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "offline-boot"; }

mkdir -p "$DATA/sysrm" 2>/dev/null
LOG="$DATA/log.txt"
DIS="$DATA/disabled.list"
REM="$DATA/removed.list"
touch "$DIS" "$REM" 2>/dev/null

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }

res() {
  # res STATUS pkg message  (message is flattened to one line, no pipes)
  _m=$(printf '%s' "$3" | tr '\n|' '  ')
  echo "$1|$2|$_m"
  log "$1 $2 $_m"
}

list_add() { grep -qxF "$2" "$1" 2>/dev/null || echo "$2" >> "$1"; }
list_del() {
  [ -f "$1" ] || return 0
  grep -vxF "$2" "$1" > "$1.tmp" 2>/dev/null
  mv "$1.tmp" "$1"
}

valid() {
  case "$1" in
    ""|*[!A-Za-z0-9._]*) return 1 ;;
  esac
  return 0
}

# Critical list: uninstall and systemless removal are refused for these.
# Disable (reversible, pm enable) is allowed; the UI shows a strong warning first.
# Keep in sync with PROT in webroot/index.html.
protected() {
  case "$1" in
    android|com.android.systemui|com.android.phone|com.android.settings|\
    com.android.bluetooth|com.android.shell|com.android.permissioncontroller|\
    com.android.packageinstaller|com.android.keychain|com.android.server.telecom|\
    com.android.inputdevices|com.android.externalstorage|com.android.location.fused|\
    com.android.modulemetadata|com.android.providers.*|com.android.networkstack*|\
    com.android.wifi*|com.android.internal.*|\
    com.google.android.permissioncontroller|com.google.android.packageinstaller|\
    com.google.android.wifi*)
      return 0 ;;
  esac
  return 1
}

# Path of the APK for a package (works for packages removed for user 0 too)
apk_path() {
  _l=$(pm list packages --user 0 -s -f -u 2>/dev/null | grep -E "=$1$" | head -n 1)
  _l=${_l#package:}
  echo "${_l%=$1}"
}

# Map an app dir on a real partition to its place inside the module
sys_target() {
  case "$1" in
    /system/*) echo "$MODDIR/system${1#/system}" ;;
    /system_ext/*|/product/*|/vendor/*|/odm/*) echo "$MODDIR/system$1" ;;
    # OEM partitions (OnePlus/OPPO my_*, Xiaomi mi_ext ...): NoMount maps system/<part>/ to /<part>/
    /my_*/*|/oem/*|/optics/*|/prism/*|/mi_ext/*) echo "$MODDIR/system$1" ;;
    *) return 1 ;;
  esac
}

do_disable() {
  o=$(pm disable-user --user 0 "$1" 2>&1)
  case "$o" in
    *disabled-user*|*disabled*)
      list_add "$DIS" "$1"; res OK "$1" "disabled" ;;
    *) res ERR "$1" "$o" ;;
  esac
}

do_enable() {
  o=$(pm enable --user 0 "$1" 2>&1)
  case "$o" in
    *enabled*)
      list_del "$DIS" "$1"; res OK "$1" "enabled" ;;
    *) res ERR "$1" "$o" ;;
  esac
}

do_uninstall() {
  o=$(pm uninstall -k --user 0 "$1" 2>&1)
  case "$o" in
    *Success*)
      list_add "$REM" "$1"; list_del "$DIS" "$1"; res OK "$1" "uninstalled for user 0" ;;
    *) res ERR "$1" "$o" ;;
  esac
}

do_restore() {
  o=$(cmd package install-existing --user 0 "$1" 2>&1)
  case "$o" in
    *"installed for user"*) : ;;
    *)
      o=$(pm install-existing --user 0 "$1" 2>&1)
      case "$o" in
        *"installed for user"*) : ;;
        *) res ERR "$1" "$o"; return ;;
      esac ;;
  esac
  pm enable --user 0 "$1" >/dev/null 2>&1
  list_del "$REM" "$1"; list_del "$DIS" "$1"
  res OK "$1" "restored"
}

# Work out where a package's folder is and how it would be hidden. No side effects.
# Sets R_DIR (real folder), R_TGT (path inside this module), R_UPDATE (1 if updated), R_ERR (why not).
sysrm_resolve() {
  R_DIR=""; R_TGT=""; R_UPDATE=0; R_ERR=""
  apk=$(apk_path "$1")
  [ -n "$apk" ] || { R_ERR="APK path not found"; return 1; }
  case "$apk" in
    /data/*)
      _base=$(dumpsys package "$1" 2>/dev/null | grep codePath | grep -v "/data/app" | head -n 1)
      _base=${_base#*codePath=}
      _base=$(echo "$_base" | tr -d ' \r\n')
      if [ -n "$_base" ] && [ -d "$_base" ]; then
        dir="$_base"
        R_UPDATE=1
      else
        R_ERR="has a user-installed update; uninstall the update first"
        return 1
      fi
      ;;
    /apex/*) R_ERR="APEX module, not removable"; return 1 ;;
    *) dir=$(dirname "$apk") ;;
  esac
  parent=$(dirname "$dir")
  case "${parent##*/}" in
    app|priv-app|overlay) : ;;
    *) R_ERR="unsupported layout ($dir)"; return 1 ;;
  esac
  tgt=$(sys_target "$dir") || { R_ERR="partition not supported systemless ($dir); use Uninstall instead"; return 1; }
  case "$tgt" in
    "$MODDIR"/system/*) : ;;
    *) R_ERR="refusing odd target"; return 1 ;;
  esac
  case "$dir" in
    /system/*|/system_ext/*|/product/*|/vendor/*|/odm/*) : ;;
    *) nm_bin >/dev/null || { R_ERR="$dir is only supported with NoMount (not installed)"; return 1; } ;;
  esac
  R_DIR=$dir; R_TGT=$tgt
  return 0
}

# Dry run: PLAN|package|folder|how  or  ERR|package|reason
do_plan() {
  if ! sysrm_resolve "$1"; then echo "ERR|$1|$R_ERR"; return; fi
  if [ "$R_UPDATE" = 1 ]; then
    how="user-installed update in /data will be uninstalled automatically, then hidden via NoMount"
  elif nm_bin >/dev/null; then how="NoMount whiteout rule at boot, plus module overlay"
  elif _m=$(meta_name); then how="module overlay (.replace) mounted by metamodule $_m"
  else how="module overlay only, but NO metamodule is installed so it will NOT apply"; fi
  echo "PLAN|$1|$R_DIR|$how"
}

do_sysrm() {
  sysrm_resolve "$1" || { res ERR "$1" "$R_ERR"; return; }
  if [ "$R_UPDATE" = 1 ]; then
    pm uninstall "$1" >/dev/null 2>&1
  fi
  _part="${R_DIR#/}"; _part="${_part%%/*}"
  [ -L "$MODDIR/system/$_part" ] && rm -f "$MODDIR/system/$_part"
  if mkdir -p "$R_TGT" && : > "$R_TGT/.replace"; then
    # Optional (Settings, Backups): once the rule is active the folder is hidden, so copy it now
    if [ "${DBL_BACKUP:-0}" = 1 ]; then
      mkdir -p "$DATA/backup" 2>/dev/null
      tar -cf "$DATA/backup/$1.tar" -C "$R_DIR" . 2>/dev/null || { rm -f "$DATA/backup/$1.tar"; log "backup of $1 failed (continuing)"; }
    fi
    { echo "$R_DIR"; boot_id; } > "$DATA/sysrm/$1"
    list_del "$REM" "$1"; list_del "$DIS" "$1"
    if NM=$(nm_bin); then
      "$NM" rule add --whiteout "$R_DIR" >/dev/null 2>&1
      res OK "$1" "queued (NoMount), reboot to apply"
    else
      res OK "$1" "queued, reboot to apply"
    fi
  else
    res ERR "$1" "could not write module overlay"
  fi
}

do_sysunrm() {
  [ -f "$DATA/sysrm/$1" ] || { res ERR "$1" "no systemless record"; return; }
  read -r dir < "$DATA/sysrm/$1"
  tgt=$(sys_target "$dir") || { res ERR "$1" "bad record"; return; }
  NM=$(nm_bin) && "$NM" rule del "$dir" >/dev/null 2>&1
  case "$tgt" in
    "$MODDIR"/system/*) rm -rf "$tgt" ;;
    *) res ERR "$1" "refusing odd target"; return ;;
  esac
  rm -f "$DATA/sysrm/$1" "$DATA/backup/$1.tar"
  res OK "$1" "restored, reboot to apply"
}

# --- import / export files on internal storage -------------------------
XDIR=${DBL_XDIR:-/sdcard/D-bloater}

# backup: copy the app-folder archives to internal storage (survives removing the module)
do_backup() {
  mkdir -p "$XDIR/backup" 2>/dev/null || { res ERR backup "cannot create $XDIR/backup"; return; }
  _n=0
  for f in "$DATA"/backup/*.tar; do
    [ -f "$f" ] || continue
    cp -f "$f" "$XDIR/backup/" 2>/dev/null && _n=$((_n + 1))
  done
  res OK backup "$_n archive(s) copied to $XDIR/backup"
}

# backuprestore <pkg>: reinstall the saved APKs as a normal app (needs no reboot)
do_backuprestore() {
  _t="$DATA/backup/$1.tar"
  [ -f "$_t" ] || _t="$XDIR/backup/$1.tar"
  [ -f "$_t" ] || { res ERR "$1" "no backup archive"; return; }
  _w="$DATA/restore.tmp"
  rm -rf "$_w"; mkdir -p "$_w"
  tar -xf "$_t" -C "$_w" 2>/dev/null || { rm -rf "$_w"; res ERR "$1" "could not unpack backup"; return; }
  set --
  for _f in "$_w"/*.apk; do [ -f "$_f" ] && set -- "$@" "$_f"; done
  [ $# -gt 0 ] || { rm -rf "$_w"; res ERR "$1" "no APK in backup"; return; }
  _o=$(pm install-multiple -r --user 0 "$@" 2>&1)
  rm -rf "$_w"
  case "$_o" in *Success*) res OK "${_t##*/}" "reinstalled from backup" ;; *) res ERR "${_t##*/}" "$_o" ;; esac
}

safe_name() {
  case "$1" in
    ""|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *.json|*.txt) return 0 ;;
  esac
  return 1
}

do_files() {
  ls -t "$XDIR" 2>/dev/null | while IFS= read -r f; do
    safe_name "$f" || continue
    case "$f" in *.json|*.txt) [ -f "$XDIR/$f" ] && echo "$f" ;; esac
  done
}

do_readfile() {
  safe_name "$1" || { echo "invalid file name" >&2; exit 2; }
  [ -f "$XDIR/$1" ] || { echo "not found: $XDIR/$1" >&2; exit 1; }
  head -c 3000000 "$XDIR/$1"
}

# stdin = base64 chunk; second arg "append" continues a multi-chunk write
do_writefile() {
  safe_name "$1" || { echo "ERR|$1|invalid file name"; exit 2; }
  mkdir -p "$XDIR" 2>/dev/null || { echo "ERR|$1|cannot create $XDIR"; exit 1; }
  chmod 777 "$XDIR" 2>/dev/null
  if [ "$2" = append ]; then
    base64 -d >> "$XDIR/$1" 2>/dev/null
  else
    base64 -d > "$XDIR/$1" 2>/dev/null
  fi
  rc=$?
  chmod 666 "$XDIR/$1" 2>/dev/null
  if [ $rc -eq 0 ]; then
    echo "OK|$1|$XDIR/$1"
  else
    echo "ERR|$1|write failed (is base64 available?)"
    exit 1
  fi
}

do_scan() {
  echo "##ALL"
  pm list packages --user 0 -s -f -u 2>/dev/null
  echo "##INST"
  pm list packages --user 0 -s 2>/dev/null
  echo "##DIS"
  pm list packages --user 0 -s -d 2>/dev/null
  echo "##BOOT"
  boot_id
  echo "##SYSRM"
  for f in "$DATA"/sysrm/*; do
    [ -f "$f" ] || continue
    { read -r _d; read -r _b; } < "$f"
    echo "${f##*/} $_d $_b"
  done
  echo "##END"
}

# ---- size and running info (no awk/sed: stock Android has neither) ---------
# Folder that belongs to one package, empty when the APK sits loose in a partition dir
pkg_dir() {
  _d=${1%/*}
  _pd=${_d%/*}
  case "${_pd##*/}" in app|priv-app|overlay) echo "$_d"; return ;; esac
  case "$1" in */data/app/*) echo "$_d" ;; esac
}

sum_lines() {
  _t=0
  while IFS= read -r _n; do
    case "$_n" in ""|*[!0-9]*) continue ;; esac
    _t=$((_t + _n))
  done
  echo "$_t"
}

# Names of live processes; a package is "running" if one is named after it
do_running() {
  echo "##RUN"
  ps -A -o NAME 2>/dev/null || ps -A 2>/dev/null || ps 2>/dev/null
}

# Lines: "<package> <apk bytes> <on-disk KB>" (APK = base + splits, disk = whole app folder)
# Optional words choose the parts: "size", "running" (no words = both)
do_info() {
  _sz=0; _rn=0
  case " $* " in *" size "*) _sz=1 ;; esac
  case " $* " in *" running "*) _rn=1 ;; esac
  [ $((_sz + _rn)) -gt 0 ] || { _sz=1; _rn=1; }
  echo "##SIZE"
  [ "$_sz" = 1 ] || { [ "$_rn" = 1 ] && do_running; echo "##END"; return 0; }
  pm list packages --user 0 -s -f -u 2>/dev/null | while IFS= read -r l; do
    l=${l#package:}
    apk=${l%=*}
    pkg=${l##*=}
    [ -n "$pkg" ] && [ -f "$apk" ] || continue
    dir=$(pkg_dir "$apk")
    if [ -n "$dir" ]; then
      bytes=$(for f in "$dir"/*.apk; do [ -f "$f" ] && stat -c %s "$f" 2>/dev/null; done | sum_lines)
      kb=$(du -sk "$dir" 2>/dev/null)
    else
      bytes=$(stat -c %s "$apk" 2>/dev/null)
      kb=$(du -sk "$apk" 2>/dev/null)
    fi
    set -- $kb
    echo "$pkg ${bytes:-0} ${1:-0}"
  done
  [ "$_rn" = 1 ] && do_running
  echo "##END"
}

do_restoreall() {
  while IFS= read -r p; do
    [ -n "$p" ] && valid "$p" && do_enable "$p"
  done < "$DIS"
  while IFS= read -r p; do
    [ -n "$p" ] && valid "$p" && do_restore "$p"
  done < "$REM"
  for f in "$DATA"/sysrm/*; do
    [ -f "$f" ] && do_sysunrm "${f##*/}"
  done
}

do_reapply() {
  INST=$(pm list packages --user 0 -s 2>/dev/null)
  ENAB=$(pm list packages --user 0 -s -e 2>/dev/null)
  while IFS= read -r p; do
    [ -n "$p" ] && valid "$p" && ! protected "$p" || continue
    case "$ENAB" in
      *"package:$p
"*|*"package:$p") do_disable "$p" >/dev/null ;;
    esac
  done < "$DIS"
  while IFS= read -r p; do
    [ -n "$p" ] && valid "$p" && ! protected "$p" || continue
    case "$INST" in
      *"package:$p
"*|*"package:$p") do_uninstall "$p" >/dev/null ;;
    esac
  done < "$REM"
  log "reapply done"
}

# Boot stage (post-fs-data): add NoMount whiteouts straight from our records,
# so removal does not depend on how the metamodule parses ".replace".
do_nmapply() {
  NM=$(nm_bin) || return 0
  ls "$DATA/sysrm/"* >/dev/null 2>&1 || return 0
  _i=0
  until "$NM" version >/dev/null 2>&1; do
    _i=$((_i + 1))
    [ $_i -ge 8 ] && { log "NoMount API not ready, direct rules skipped"; return 0; }
    sleep 0.5
  done
  for f in "$DATA"/sysrm/*; do
    [ -f "$f" ] || continue
    read -r _d < "$f"
    [ -n "$_d" ] && sys_target "$_d" >/dev/null || continue
    if _o=$("$NM" rule add --whiteout "$_d" 2>&1); then
      log "NoMount whiteout $_d"
    else
      log "NoMount whiteout FAILED $_d: $_o"
    fi
  done
}

# After boot: tell the log whether each systemless removal really took effect
do_sysverify() {
  _all=$(pm list packages --user 0 -s -u 2>/dev/null)
  _cur=$(boot_id)
  for f in "$DATA"/sysrm/*; do
    [ -f "$f" ] || continue
    _p=${f##*/}
    { read -r _d; read -r _b; } < "$f"
    [ -n "$_b" ] && [ "$_b" != "$_cur" ] || continue
    case "$_all" in
      *"package:$_p
"*|*"package:$_p") log "SYSRM NOT APPLIED: $_p ($_d still visible to PackageManager, run: dbl.sh diag)" ;;
      *) log "SYSRM applied: $_p" ;;
    esac
  done
}

# Everything needed to see why a systemless removal did not apply
do_diag() {
  echo "boot_id: $(boot_id)"
  echo "-- metamodule (KernelSU only mounts module system/ dirs through one)"
  _found=0
  for d in /data/adb/modules/*; do
    [ -f "$d/metamount.sh" ] || continue
    _found=1
    _fl=""
    for x in disable remove skip_mount; do [ -e "$d/$x" ] && _fl="$_fl $x"; done
    echo "metamodule: ${d##*/}${_fl:+ (flags:$_fl)}"
  done
  [ $_found = 1 ] || echo "metamodule: NONE FOUND (module system/ dirs are not mounted at all)"
  for x in disable remove skip_mount; do [ -e "$MODDIR/$x" ] && echo "D-bloater has flag: $x"; done
  echo "-- NoMount"
  if NM=$(nm_bin); then
    echo "nm: $NM, version: $("$NM" version 2>&1)"
    [ -f /data/adb/nomount/disable ] && echo "NoMount SAFE MODE is on (rules skipped): remove /data/adb/nomount/disable"
    _rules=$("$NM" rule list 2>&1)
  else
    echo "nm binary not found"
    _rules=""
  fi
  echo "-- records"
  _cur=$(boot_id)
  _any=0
  _all=$(pm list packages --user 0 -s -u 2>/dev/null)
  for f in "$DATA"/sysrm/*; do
    [ -f "$f" ] || continue
    _any=1
    _p=${f##*/}
    { read -r _d; read -r _b; } < "$f"
    echo "$_p"
    echo "  dir: $_d"
    [ "$_b" = "$_cur" ] && echo "  queued this boot (reboot not done yet)" || echo "  queued before the current boot"
    _t=$(sys_target "$_d") && { [ -f "$_t/.replace" ] && echo "  overlay .replace: present" || echo "  overlay .replace: MISSING"; }
    case "$_rules" in *"$_d"*) echo "  NoMount rule: active" ;; *) echo "  NoMount rule: not active" ;; esac
    [ -d "$_d" ] && echo "  dir visible to root: yes" || echo "  dir visible to root: no (hidden)"
    case "$_all" in
      *"package:$_p
"*|*"package:$_p") echo "  PackageManager: still lists it" ;;
      *) echo "  PackageManager: gone" ;;
    esac
  done
  [ $_any = 1 ] || echo "(no systemless removals recorded)"
  if [ -f /data/adb/nomount/nomount.log ]; then
    echo "-- nomount.log (D-bloater lines)"
    grep -i "dbloater\|fatal\|safe mode" /data/adb/nomount/nomount.log | tail -n 15
  fi
  echo "-- D-bloater log (last 15)"
  tail -n 15 "$LOG" 2>/dev/null
}

# Newest queued removal is undone (used by the boot guard)
do_revertlast() {
  _f=$(ls -t "$DATA"/sysrm/* 2>/dev/null | head -n 1)
  [ -n "$_f" ] || return 1
  _p=${_f##*/}
  do_sysunrm "$_p" >/dev/null
  log "GUARD undid newest systemless removal: $_p"
}

# Apply queued removals now: add the rules, then restart the framework so the
# package manager rescans. Records are marked "soft" so the UI can tell it ran.
do_softreboot() {
  # A framework restart does not remount anything, so only NoMount rules can apply it
  NM=$(nm_bin) || { res ERR softreboot "needs NoMount (module overlays are only mounted at boot); do a full reboot"; return 1; }
  do_nmapply
  "$NM" rule list 2>/dev/null | grep -q . || { res ERR softreboot "no NoMount rules are active; do a full reboot"; return 1; }
  for f in "$DATA"/sysrm/*; do
    [ -f "$f" ] || continue
    read -r _d < "$f"
    { echo "$_d"; echo soft; } > "$f.tmp"
    touch -r "$f" "$f.tmp" 2>/dev/null
    mv "$f.tmp" "$f"
  done
  log "soft reboot (framework restart)"
  setprop ctl.restart zygote
}

# Raw usage lines; the WebUI picks out package + last used time
do_usage() {
  echo "##USAGE"
  dumpsys usagestats 2>/dev/null | grep "lastTimeUsed" | head -n 6000
  echo "##END"
}

# Device facts for the WebUI dependency graph: shared user IDs, default-app roles,
# settings that name an app as keyboard / accessibility service / assistant, overlays
do_graph() {
  echo "##UID"
  pm list packages -U 2>/dev/null
  echo "##ROLE"
  for _r in HOME DIALER SMS BROWSER ASSISTANT EMERGENCY CALL_REDIRECTION CALL_SCREENING NOTES SYSTEM_GALLERY SYSTEM_WELLBEING; do
    cmd role get-role-holders --user 0 "android.app.role.$_r" 2>/dev/null | while read -r _h; do
      case "$_h" in ""|*[!A-Za-z0-9._]*) ;; *) echo "$_r $_h" ;; esac
    done
  done
  echo "##SET"
  for _k in default_input_method enabled_input_methods enabled_accessibility_services enabled_notification_listeners assistant voice_interaction_service voice_recognition_service autofill_service; do
    echo "$_k=$(settings get secure "$_k" 2>/dev/null)"
  done
  echo "##OVL"
  cmd overlay list --user 0 2>/dev/null
  echo "##END"
}

cmd=$1
[ $# -gt 0 ] && shift

case "$cmd" in
  scan) do_scan ;;
  info) do_info "$@" ;;
  running) do_running; echo "##END" ;;
  log) tail -n 300 "$LOG" 2>/dev/null ;;
  files) do_files ;;
  readfile) do_readfile "$1" ;;
  writefile) do_writefile "$1" "$2" ;;
  restoreall) do_restoreall ;;
  reapply) do_reapply; do_sysverify ;;
  nmapply) do_nmapply ;;
  revertlast) do_revertlast ;;
  softreboot) do_softreboot ;;
  usage) do_usage ;;
  graph) do_graph ;;
  backup) do_backup ;;
  diag) do_diag ;;
  disable|enable|uninstall|restore|sysrm|sysunrm|plan|backuprestore)
    for p in "$@"; do
      if ! valid "$p"; then
        res ERR "$p" "invalid package name"
        continue
      fi
      case "$cmd" in
        uninstall|sysrm|plan)
          # Critical packages may only be disabled, never uninstalled or hidden
          if protected "$p"; then
            res ERR "$p" "critical system package: only disable is allowed"
            continue
          fi ;;
      esac
      case "$cmd" in
        disable) do_disable "$p" ;;
        enable) do_enable "$p" ;;
        uninstall) do_uninstall "$p" ;;
        restore) do_restore "$p" ;;
        sysrm) do_sysrm "$p" ;;
        sysunrm) do_sysunrm "$p" ;;
        plan) do_plan "$p" ;;
        backuprestore) do_backuprestore "$p" ;;
      esac
    done ;;
  *)
    echo "usage: dbl.sh scan|info|running|disable|enable|uninstall|restore|sysrm|sysunrm|restoreall|reapply|diag|plan|softreboot|backup|backuprestore|usage|graph|log|files|readfile|writefile [args...]" >&2
    exit 2 ;;
esac
