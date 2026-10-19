#!/bin/sh
# Offline test of bin/dbl.sh with fake pm/nm/tar/dumpsys/setprop. Run: sh tests/test_dbl.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/mod/bin" "$T/data" "$T/fx/apk" "$T/x"
cp "$HERE/bin/dbl.sh" "$T/mod/bin/"
echo apk > "$T/fx/apk/base.apk"
REALTAR=$(command -v tar)

cat > "$T/bin/pm" <<'X'
#!/bin/sh
case "$*" in
  install-multiple*) echo "pm $*" >> "$FAKE_LOG"; echo Success ;;
  *"-s -f -u"*)
    echo "package:/product/priv-app/Foo/Foo.apk=com.foo.app"
    echo "package:/system/app/Bar/Bar.apk=com.bar.app"
    echo "package:/my_product/app/Baz/Baz.apk=com.baz.app"
    echo "package:/data/app/Dat/base.apk=com.dat.app" ;;
  *) echo "package:com.foo.app"; echo "package:com.bar.app"; echo "package:com.baz.app" ;;
esac
X
cat > "$T/bin/nm" <<'X'
#!/bin/sh
echo "nm $*" >> "$FAKE_LOG"
case "$*" in version) echo v2.1.1 ;; "rule list") echo "/product/priv-app/Foo (whiteout)" ;; esac
exit 0
X
cat > "$T/bin/tar" <<X
#!/bin/sh
# the app folders do not exist on a CI box: archive a fixture instead
if [ "\$1" = -cf ]; then exec $REALTAR -cf "\$2" -C "$T/fx/apk" .; fi
exec $REALTAR "\$@"
X
cat > "$T/bin/dumpsys" <<'X'
#!/bin/sh
echo '      package=com.foo.app totalTimeUsed="00:01" lastTimeUsed="2026-10-12 10:22:01" appLaunchCount=3'
echo 'unrelated line'
X
cat > "$T/bin/cmd" <<'X'
#!/bin/sh
case "$*" in
  *role*HOME) echo com.foo.app ;;
  *role*SMS) echo "Error: no such role" ;;
  *"overlay list"*) printf 'com.bar.app\n[x] com.bar.overlay\n--- com.bar.other\n' ;;
esac
X
cat > "$T/bin/settings" <<'X'
#!/bin/sh
case "$*" in *default_input_method) echo com.ime/.Latin ;; *) echo null ;; esac
X
cat > "$T/bin/setprop" <<'X'
#!/bin/sh
echo "setprop $*" >> "$FAKE_LOG"
X
chmod +x "$T"/bin/*

export PATH="$T/bin:$PATH" DBL_DATA="$T/data" DBL_XDIR="$T/x" FAKE_LOG="$T/calls"
: > "$T/calls"
D="sh $T/mod/bin/dbl.sh"
FAIL=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAIL=1; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (wanted '$2' in: $1)" ;; esac; }
no()  { case "$1" in *"$2"*) bad "$3 (found '$2' in: $1)" ;; *) ok "$3" ;; esac; }

# without NoMount: partitions that need it are refused, others get a warning
o=$($D plan com.baz.app); has "$o" "only supported with NoMount" "plan refuses /my_* without NoMount"
o=$($D plan com.foo.app); has "$o" "NO metamodule" "plan warns when nothing can mount"
o=$($D plan com.dat.app); has "$o" "user-installed update" "plan refuses data apps"
o=$($D plan com.android.systemui); has "$o" "critical" "plan refuses protected packages"

export DBL_NM="$T/bin/nm"
o=$($D plan com.baz.app); has "$o" "PLAN|com.baz.app|/my_product/app/Baz|NoMount" "plan allows /my_* with NoMount"

o=$($D sysrm com.baz.app); has "$o" "queued" "sysrm without backup"
[ ! -f "$T/data/backup/com.baz.app.tar" ] && ok "no backup by default" || bad "backup made while off"
$D sysunrm com.baz.app >/dev/null
export DBL_BACKUP=1
o=$($D sysrm com.foo.app); has "$o" "queued (NoMount)" "sysrm queues"
[ -f "$T/mod/system/product/priv-app/Foo/.replace" ] && ok "overlay marker written" || bad "overlay marker"
[ "$(wc -l < "$T/data/sysrm/com.foo.app")" = 2 ] && ok "record has dir + boot id" || bad "record format"
[ -f "$T/data/backup/com.foo.app.tar" ] && ok "backup archive made" || bad "backup archive"
sleep 1
$D sysrm com.bar.app >/dev/null
[ -f "$T/mod/system/app/Bar/.replace" ] && ok "second overlay" || bad "second overlay"

o=$($D scan); has "$o" "##BOOT" "scan has boot id"; has "$o" "com.foo.app /product/priv-app/Foo" "scan lists records"

: > "$T/calls"; $D nmapply
has "$(cat "$T/calls")" "rule add --whiteout /product/priv-app/Foo" "nmapply adds whiteout"

o=$(DBL_NM=/nonexistent $D softreboot); has "$o" "ERR|softreboot|needs NoMount" "softreboot refuses without NoMount"
no "$(cat "$T/calls")" "ctl.restart" "no restart without NoMount"
$D softreboot
has "$(cat "$T/calls")" "setprop ctl.restart zygote" "softreboot restarts framework"
[ "$(sed -n 2p "$T/data/sysrm/com.foo.app")" = soft ] && ok "records marked soft" || bad "soft mark"
o=$($D scan); has "$o" "com.bar.app /system/app/Bar soft" "scan shows soft mark"

$D revertlast
[ ! -f "$T/data/sysrm/com.bar.app" ] && ok "revertlast removed newest record" || bad "revertlast record"
[ ! -d "$T/mod/system/app/Bar" ] && ok "revertlast removed newest overlay" || bad "revertlast overlay"
[ -f "$T/data/sysrm/com.foo.app" ] && ok "older record kept" || bad "older record kept"

o=$($D backup); has "$o" "1 archive" "backup copies archives"
[ -f "$T/x/backup/com.foo.app.tar" ] && ok "backup on sdcard" || bad "backup on sdcard"
: > "$T/calls"; o=$($D backuprestore com.foo.app); has "$o" "reinstalled from backup" "backuprestore"
has "$(cat "$T/calls")" "install-multiple" "backuprestore uses pm"

o=$($D usage); has "$o" "lastTimeUsed" "usage lines"; no "$o" "unrelated" "usage filtered"

o=$($D graph)
has "$o" "HOME com.foo.app" "graph lists role holders"; no "$o" "Error" "graph drops role errors"
has "$o" "default_input_method=com.ime/.Latin" "graph lists settings"; has "$o" "[x] com.bar.overlay" "graph lists overlays"
has "$o" "package:com.foo.app" "graph lists uids"

o=$($D diag); has "$o" "NoMount rule" "diag runs"

$D sysunrm com.foo.app >/dev/null
[ ! -f "$T/data/backup/com.foo.app.tar" ] && ok "sysunrm drops backup" || bad "sysunrm backup"

$D delbackup com.foo.app >/dev/null
[ ! -f "$T/x/backup/com.foo.app.tar" ] && ok "delbackup removes archive" || bad "delbackup failed"

[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
