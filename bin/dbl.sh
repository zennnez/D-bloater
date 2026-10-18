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
#   log                       print the action log
#   files | readfile F        list / read import files in /sdcard/D-bloater
#   writefile F [append]      write base64 from stdin to /sdcard/D-bloater/F
#
# Output of action commands: one line per package -> STATUS|package|message

MODDIR=${0%/*/*}
DATA=${DBL_DATA:-/data/adb/dbloater}
PATH=/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:$PATH
export PATH

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
  pm list packages --user 0 -s -f -u 2>/dev/null | while IFS= read -r l; do
    case "$l" in
      *"=$1") p=${l#package:}; echo "${p%=$1}"; break ;;
    esac
  done
}

# Map an app dir on a real partition to its place inside the module
sys_target() {
  case "$1" in
    /system/*) echo "$MODDIR/system${1#/system}" ;;
    /system_ext/*|/product/*|/vendor/*|/odm/*) echo "$MODDIR/system$1" ;;
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

do_sysrm() {
  apk=$(apk_path "$1")
  [ -n "$apk" ] || { res ERR "$1" "APK path not found"; return; }
  case "$apk" in
    /data/*) res ERR "$1" "has a user-installed update; uninstall the update first"; return ;;
    /apex/*) res ERR "$1" "APEX module, not removable"; return ;;
  esac
  dir=$(dirname "$apk")
  parent=$(dirname "$dir")
  case "${parent##*/}" in
    app|priv-app) : ;;
    *) res ERR "$1" "unsupported layout ($dir)"; return ;;
  esac
  tgt=$(sys_target "$dir") || { res ERR "$1" "partition not supported systemless ($dir); use Uninstall instead"; return; }
  case "$tgt" in
    "$MODDIR"/system/*) : ;;
    *) res ERR "$1" "refusing odd target"; return ;;
  esac
  if mkdir -p "$tgt" && : > "$tgt/.replace"; then
    echo "$dir" > "$DATA/sysrm/$1"
    res OK "$1" "queued, reboot to apply"
  else
    res ERR "$1" "could not write module overlay"
  fi
}

do_sysunrm() {
  [ -f "$DATA/sysrm/$1" ] || { res ERR "$1" "no systemless record"; return; }
  dir=$(cat "$DATA/sysrm/$1")
  tgt=$(sys_target "$dir") || { res ERR "$1" "bad record"; return; }
  case "$tgt" in
    "$MODDIR"/system/*) rm -rf "$tgt" ;;
    *) res ERR "$1" "refusing odd target"; return ;;
  esac
  rm -f "$DATA/sysrm/$1"
  res OK "$1" "restored, reboot to apply"
}

# --- import / export files on internal storage -------------------------
XDIR=${DBL_XDIR:-/sdcard/D-bloater}

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
  echo "##SYSRM"
  for f in "$DATA"/sysrm/*; do
    [ -f "$f" ] && echo "${f##*/} $(cat "$f")"
  done
  echo "##END"
}

# ---- size and running info (no awk/sed: stock Android has neither) ---------
# Folder that belongs to one package, empty when the APK sits loose in a partition dir
pkg_dir() {
  _d=${1%/*}
  _pd=${_d%/*}
  case "${_pd##*/}" in app|priv-app) echo "$_d"; return ;; esac
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
do_info() {
  echo "##SIZE"
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
  do_running
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

cmd=$1
[ $# -gt 0 ] && shift

case "$cmd" in
  scan) do_scan ;;
  info) do_info ;;
  running) do_running; echo "##END" ;;
  log) tail -n 300 "$LOG" 2>/dev/null ;;
  files) do_files ;;
  readfile) do_readfile "$1" ;;
  writefile) do_writefile "$1" "$2" ;;
  restoreall) do_restoreall ;;
  reapply) do_reapply ;;
  disable|enable|uninstall|restore|sysrm|sysunrm)
    for p in "$@"; do
      if ! valid "$p"; then
        res ERR "$p" "invalid package name"
        continue
      fi
      case "$cmd" in
        uninstall|sysrm)
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
      esac
    done ;;
  *)
    echo "usage: dbl.sh scan|info|running|disable|enable|uninstall|restore|sysrm|sysunrm|restoreall|reapply|log|files|readfile|writefile [args...]" >&2
    exit 2 ;;
esac
