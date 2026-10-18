#!/bin/bash
set -e
REPO=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
export LC_ALL=C
BASE=$(pwd)/work/manager-tests-$$
mkdir -p "$BASE"
CRASHDIR="$BASE/sc"; BINDIR="$CRASHDIR"; TMPDIR="$BASE/tmp"
SC_DISK="$BASE/usb"; SC_DATA="$SC_DISK/ShellCrash-local"; SC_STATE="$BASE/state"
mkdir -p "$CRASHDIR"/{configs/task,local,libs,starts,task,tools} "$SC_DISK" "$SC_STATE" "$TMPDIR"
touch "$CRASHDIR/task/task.sh"
for module in common status maintenance update; do . "$REPO/scripts/local/modules/$module.sh"; done
sc_mount_ready() { [ "${MOUNTED:-1}" = 1 ]; }
sc_root_owned() { [ ! -L "$1" ]; } # Windows fixture has no Linux uid=0 semantics.
sc_private_dir() { return 0; } # Real Linux modes are checked separately on the router.
sc_pid_token() { [ "$1" = "$$" ] && echo TOKEN; }
sc_free() { echo "${FREE:-999999}"; }
subconv_needed() { return 0; }
subconv_ready() { [ -f "$BASE/engine-alive" ]; }
subconv_dir() { echo "$BASE/engine"; }
subconv_start() { echo engine-start >>"$BASE/actions"; touch "$BASE/engine-alive"; }
pidof() { [ -f "$BASE/core-alive" ] && echo 123; }
sc_api() { [ -f "$BASE/core-alive" ] && echo '{"version":"v1.19.32"}'; }
sc_health() { [ -f "$BASE/core-alive" ] && [ -f "$BASE/engine-alive" ]; }
sc_storage
printf 'secret=PRIVATE_SENTINEL\n' >"$CRASHDIR/configs/ShellCrash.cfg"
printf 'command=test\n' >"$CRASHDIR/configs/command.env"
printf 'raw subscription PRIVATE_SENTINEL\n' >"$CRASHDIR/configs/providers.cfg"
printf '#!/bin/sh\ncase "$1" in stop) rm -f "$CORE_FLAG" ;; *) touch "$CORE_FLAG" ;; esac\nprintf "%%s\\n" "$1" >>"$ACTION_FILE"\n' >"$CRASHDIR/start.sh"
chmod +x "$CRASHDIR/start.sh"
export CORE_FLAG="$BASE/core-alive" ACTION_FILE="$BASE/actions"
touch "$BASE/core-alive" "$BASE/engine-alive"
val="a b'c\$(echo NOT_EXECUTED)"
sc_cfg quoted_test "$val"
. "$CRASHDIR/configs/ShellCrash.cfg"
test "$quoted_test" = "$val"
echo 'PASS atomic config shell quoting'
(sc_lock testlock; sc_unlock)
mkdir "$SC_STATE/stale.lock"; echo '999999 invalid' >"$SC_STATE/stale.lock/owner"
(sc_lock stale; sc_unlock)
mkdir "$SC_STATE/orphan.lock"; echo 1 >"$SC_STATE/orphan.lock.observed"
(sc_lock orphan; sc_unlock)
echo 'PASS live/stale/orphan lock handling'
sc_version_newer v1.19.32 v1.19.9
! sc_version_newer v1.19.28 v1.19.32
! sc_version_newer v1.19.32 v1.19.32
! sc_version_newer v1.19.33-alpha v1.19.32
echo 'PASS stable version comparison and downgrade prevention'
for n in 01 02 03 04 05; do mkdir "$SC_DATA/backups/core-202601$n"; echo SC_LOCAL_BACKUP_V1 >"$SC_DATA/backups/core-202601$n/.sc-owned"; done
mkdir "$SC_DATA/backups/core-20269999"
echo "$SC_DATA/backups/core-20260101" >"$SC_DATA/rollback-backup"
local_backup_keep=2
sc_prune_type core
test -d "$SC_DATA/backups/core-20260101"
test -d "$SC_DATA/backups/core-20260104"
test -d "$SC_DATA/backups/core-20260105"
test -d "$SC_DATA/backups/core-20269999"
test ! -d "$SC_DATA/backups/core-20260102"
test ! -d "$SC_DATA/backups/core-20260103"
echo 'PASS backup rotation retains newest, protected rollback and unowned directories'
local_heal=ON; local_maintenance=OFF
MOUNTED=0
(sc_tick)
test -f "$SC_STATE/usb-pending"
test ! -f "$BASE/actions"
MOUNTED=1
rm "$BASE/engine-alive" "$BASE/core-alive"
(sc_tick)
test -f "$BASE/engine-alive"; test -f "$BASE/core-alive"
test ! -f "$SC_STATE/usb-pending"
echo 'PASS absent USB waits and returned USB restores engine/core'
rm "$BASE/actions" "$BASE/core-alive"
: >"$SC_STATE/user-stopped"
(sc_tick)
test ! -f "$BASE/actions"
SC_MANAGER_RECOVERY=1 sc_intent start
test -f "$SC_STATE/user-stopped"
sc_intent start
test ! -f "$SC_STATE/user-stopped"
touch "$CRASHDIR/.dis_startup"
(sc_tick)
test ! -f "$BASE/actions"
rm "$CRASHDIR/.dis_startup"
echo 'PASS deliberate user stop is respected'
echo '3 0' >"$SC_STATE/heal-attempts"
(sc_tick)
test -f "$SC_STATE/heal-blocked"
echo 'PASS recovery retry limit'
touch "$BASE/core-alive" "$BASE/engine-alive"
sc_status() { echo 'status: no private input copied'; }
secret=PRIVATE_SENTINEL; authentication=PRIVATE_SENTINEL; sub_only=ON; sub_local=ON
diag=$(sc_diagnostic)
mkdir "$BASE/diag"
tar -xzf "$diag" -C "$BASE/diag"
! grep -R -q PRIVATE_SENTINEL "$BASE/diag"
echo 'PASS diagnostic allowlist excludes secret, auth and raw subscription data'
make_core() { printf '#!/bin/sh\ncase "$1" in -v) echo "Mihomo Meta %s linux arm64" ;; -t) exit 0 ;; esac\n' "$2" >"$1"; chmod +x "$1"; }
make_core "$BINDIR/CrashCore.upx" v1.19.32
make_core "$BASE/new.upx" v1.20.0
cp "$BINDIR/CrashCore.upx" "$BASE/original.upx"
sc_health() { return 0; }
sc_wait_healthy() { [ "$1" != v1.20.0 ]; }
if sc_install_core "$BASE/new.upx" v1.20.0; then echo 'FAIL accepted unhealthy core'; exit 1; fi
cmp "$BASE/original.upx" "$BINDIR/CrashCore.upx"
grep -q 'restoring verified backup' "$SC_STATE/events.log"
echo 'PASS failed core health triggers verified rollback'
sc_wait_healthy() { return 0; }
sc_install_core "$BASE/new.upx" v1.20.0
test "$(sc_version)" = v1.20.0
echo 'PASS successful core transaction'
make_core "$BINDIR/CrashCore.upx" v1.19.32
(mv() { case "$*" in *'.sc-core-new.'*) return 1 ;; esac; command mv "$@"; }; if sc_install_core "$BASE/new.upx" v1.20.0; then exit 1; fi)
cmp "$BASE/original.upx" "$BINDIR/CrashCore.upx"
echo 'PASS promotion I/O failure also rolls back'
FREE=0
if sc_install_core "$BASE/new.upx" v1.20.0; then exit 1; fi
cmp "$BASE/original.upx" "$BINDIR/CrashCore.upx"
FREE=999999
echo 'PASS disk-space failure keeps current core'
backup=$(cat "$SC_DATA/rollback-backup")
printf '#tampered\n' >>"$backup/core.upx"
sc_sha "$backup/core.upx" >"$backup/core.sha256"
if sc_restore_core "$backup"; then echo 'FAIL trusted index bypass'; exit 1; fi
cmp "$BASE/original.upx" "$BINDIR/CrashCore.upx"
echo 'PASS tampered USB backup rejected using internal trusted index'
cpucore=arm64; crashcore=meta
make_core "$CRASHDIR/tools/upx-linux-arm64" v5.2.1
local_upx_sha256=$(sc_sha "$CRASHDIR/tools/upx-linux-arm64")
sc_release() { SC_RELEASE=v1.20.0; SC_ASSET_URL=https://example.invalid/asset.gz; SC_ASSET_SHA=$(printf '%064d' 0); }
curl() { while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then printf tampered >"$2"; return 0; fi; shift; done; return 1; }
if (sc_update latest); then echo 'FAIL accepted wrong digest'; exit 1; fi
cmp "$BASE/original.upx" "$BINDIR/CrashCore.upx"
test "$(find "$SC_DATA/downloads" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 0
echo 'PASS SHA-256 mismatch blocks install and cleans download scratch'
orphan="$SC_DATA/downloads/core.orphan"
mkdir "$orphan"
echo SC_LOCAL_DOWNLOAD_V1 >"$orphan/.sc-owned"
printf scratch >"$orphan/core.raw"
touch -t 202001010000 "$orphan"
mkdir "$SC_DATA/downloads/core.unowned"
touch -t 202001010000 "$SC_DATA/downloads/core.unowned"
sc_maintain
test ! -d "$orphan"
test -d "$SC_DATA/downloads/core.unowned"
echo 'PASS orphan scratch cleanup is limited to marked inactive downloads'
echo 'MANAGER_ALL_TESTS_PASSED'
