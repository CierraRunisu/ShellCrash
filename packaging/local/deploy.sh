#!/bin/sh
# Existing ShellCrash ARM64 installation overlay; no credentials are embedded.
set +x
umask 077
PKG=$(CDPATH='' cd -- "$(dirname "$0")" && pwd) || exit 1
CRASHDIR=/userdisk/ShellCrash
DATA=''
WITH_CORE=1
CHECK=0
REGISTER=1
while [ "$#" -gt 0 ]; do
    case "$1" in
    --crashdir) [ "$#" -ge 2 ] || exit 1; CRASHDIR="$2"; shift 2 ;;
    --data) [ "$#" -ge 2 ] || exit 1; DATA="$2"; shift 2 ;;
    --no-core) WITH_CORE=0; shift ;;
    --with-core) WITH_CORE=1; shift ;;
    --no-cron) REGISTER=0; shift ;;
    --check) CHECK=1; shift ;;
    -h|--help) echo 'sh deploy.sh [--crashdir /userdisk/ShellCrash] --data /mnt/USB [--check|--no-core|--no-cron]'; exit 0 ;;
    *) echo '未知参数'; exit 1 ;;
    esac
done
fail() { echo "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail '需要 root'
case "$(uname -m)" in aarch64|arm64) ;; *) fail '此部署包仅适用于 Linux ARM64' ;; esac
case "$CRASHDIR" in /*) ;; *) fail '脚本路径必须是绝对路径' ;; esac
[ -d "$CRASHDIR" ] && [ "$(readlink -f "$CRASHDIR")" = "$CRASHDIR" ] || fail '脚本目录必须存在且不能经软链接重定向'
[ -f "$CRASHDIR/configs/ShellCrash.cfg" ] && [ -f "$CRASHDIR/libs/get_config.sh" ] || fail '请先安装原版 ShellCrash；此包整合已有安装'
export CRASHDIR
# Upstream get_config may legitimately return 1: explicitly validate its results.
. "$CRASHDIR/libs/get_config.sh" || :
[ -n "$BINDIR" ] && [ -n "$TMPDIR" ] || fail 'ShellCrash 数据/临时目录配置缺失'
[ -n "$DATA" ] || DATA="${local_data:-$(dirname "${sub_dir:-$BINDIR/subconverter}")}"
case "$DATA" in /*) ;; *) fail 'USB 路径必须是绝对路径' ;; esac
[ -d "$DATA" ] && [ "$(readlink -f "$DATA")" = "$DATA" ] || fail 'USB 路径不存在或经软链接重定向'
awk -v path="$DATA" '$2==path && $4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts || fail '--data 必须是已挂载的可写文件系统根目录'
[ "$(df -Pk "$DATA" | awk 'END {print $4}')" -gt 204800 ] || fail 'USB 需要至少 200 MiB 可用空间'
[ "$(df -Pk "$CRASHDIR" | awk 'END {print $4}')" -gt 2048 ] || fail '脚本所在分区至少需要 2 MiB 余量'
for c in awk tar gzip mktemp curl openssl crontab; do command -v "$c" >/dev/null 2>&1 || fail "缺少工具：$c"; done
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi; }
# Check every payload before executing any packaged binaries or touching installation.
[ -s "$PKG/SHA256SUMS" ] || fail '缺少包内校验清单'
while read -r digest file; do
    case "$file" in ''|/*|*..*|*\\*) fail '清单路径不合法' ;; esac
    [ -f "$PKG/$file" ] && [ ! -L "$PKG/$file" ] || fail "清单文件缺失：$file"
    [ "$(sha "$PKG/$file")" = "$digest" ] || fail "包校验失败：$file"
done <"$PKG/SHA256SUMS"
for f in "$PKG/overlay/libs/"*.sh "$PKG/overlay/local/"*.sh "$PKG/overlay/local/modules/"*.sh; do sh -n "$f" || fail '包中脚本语法错误'; done
[ "$(sha "$PKG/core/CrashCore.upx")" = 4fc611aa8de8c87248d157b77bb43a23c5de0f69b2b2e040455f8cfb94653dfe ] || fail '核心固定校验失败'
[ "$(sha "$PKG/overlay/tools/upx-linux-arm64")" = 871d65c543cfda923d8502b92a58d4934c434aead8746d7b4a7f6dad66eb3dad ] || fail 'UPX 固定校验失败'
"$PKG/core/CrashCore.upx" -v 2>/dev/null | grep -q 'v1.19.32' || fail '核心运行验证失败（USB 必须允许执行）'
"$PKG/overlay/tools/upx-linux-arm64" -t "$PKG/core/CrashCore.upx" >/dev/null 2>&1 || fail '核心 UPX 完整性检查失败'
[ "$CHECK" = 0 ] || { echo 'ARM64、挂载、空间、包内 SHA-256、核心版本与 UPX 校验通过；未修改设备。'; exit 0; }
# Serialize overlay deployment. PID-only locks require manual investigation after power loss.
LOCK="$CRASHDIR/.local-deploy.lock"
mkdir "$LOCK" 2>/dev/null || fail "部署锁存在，请确认没有其他部署后检查：$LOCK"
printf '%s\n' "$$" >"$LOCK/pid"
BACKUP=$(mktemp -d "$DATA/sc-deploy-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX") || { rmdir "$LOCK" 2>/dev/null; fail '无法创建备份'; }
chmod 700 "$BACKUP" || exit 1
PHASE=prepare
restore() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" != 0 ] && [ "$PHASE" = modifying ]; then
        for rel in $CREATED_GEO; do
            [ "$(readlink "$BINDIR/$rel" 2>/dev/null)" != "$PUBLIC_GEO/$rel" ] || rm -f "$BINDIR/$rel"
        done
        if [ "${ENGINE_TOUCHED:-0}" = 1 ]; then
            subconv_stop force >/dev/null 2>&1 || :
            if [ -d "$ENGINE_DIR" ]; then mv "$ENGINE_DIR" "$BACKUP/engine-failed" || rc=2; fi
            if [ "${ENGINE_EXISTED:-0}" = 1 ]; then
                mkdir -p "$ENGINE_DIR" && tar -xzf "$BACKUP/engine.tgz" -C "$ENGINE_DIR" || rc=2
            fi
        fi
        if tar -xzf "$BACKUP/scripts-configs.tgz" -C "$CRASHDIR" && crontab "$BACKUP/crontab"; then
            if [ "${ENGINE_TOUCHED:-0}" = 1 ] && [ "${ENGINE_EXISTED:-0}" = 1 ]; then
                . "$CRASHDIR/libs/get_config.sh" || :
                . "$CRASHDIR/libs/subconv.sh" || :
                subconv_start >/dev/null 2>&1 || rc=2
            fi
            echo "部署未完成，原脚本/配置/计划任务已恢复；备份：$BACKUP" >&2
        else echo "部署恢复失败，请手动恢复：$BACKUP" >&2; rc=2; fi
    fi
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || :
    exit "$rc"
}
trap restore EXIT
trap 'exit 1' HUP INT TERM
# Back up complete script directories and configuration; backups stay on the router USB.
set -- libs menus starts local configs start.sh
[ ! -d "$CRASHDIR/task" ] || set -- "$@" task
[ ! -d "$CRASHDIR/tools" ] || set -- "$@" tools
[ ! -d "$CRASHDIR/subconverter/config" ] || set -- "$@" subconverter/config
# local may not exist on stock installations.
mkdir -p "$CRASHDIR/local" || exit 1
tar -czf "$BACKUP/scripts-configs.tgz" -C "$CRASHDIR" "$@" || exit 1
crontab -l >"$BACKUP/crontab" 2>/dev/null || : >"$BACKUP/crontab"
PHASE=modifying
mkdir -p "$CRASHDIR/local/modules" "$CRASHDIR/tools" "$CRASHDIR/subconverter/config" || exit 1
for dir in libs local local/modules tools; do
    for src in "$PKG/overlay/$dir/"*; do
        [ -f "$src" ] || continue
        dst="$CRASHDIR/$dir/$(basename "$src")"
        cp "$src" "$dst.sc-new" && chmod 644 "$dst.sc-new" && mv -f "$dst.sc-new" "$dst" || exit 1
    done
done
chmod 755 "$CRASHDIR/local/apply.sh" "$CRASHDIR/local/manager.sh" "$CRASHDIR/tools/upx-linux-arm64" || exit 1
# Use the same protected state directory and atomic config writers as the manager.
SC_STATE=/tmp/ShellCrash-local-manager
[ ! -L "$SC_STATE" ] || exit 1
if [ -d "$SC_STATE" ]; then [ "$(ls -nd "$SC_STATE" | awk '{print $3}')" = 0 ] || exit 1
else mkdir -m 700 "$SC_STATE" || exit 1; fi
chmod 700 "$SC_STATE" || exit 1
SC_DISK="$DATA"; SC_DATA="$DATA/ShellCrash-local"; SC_LOCK=''
for module in common status maintenance update; do . "$CRASHDIR/local/modules/$module.sh" || exit 1; done
. "$CRASHDIR/libs/subconv.sh" || exit 1
sc_storage && sc_lock update || fail '已有核心更新/自愈操作，或维护存储不可用'
# Deployment lock cleanup also owns manager update lock.
# Avoid depending on the last command's status for cleanup.
restore_locked() { saved_rc=$?; sc_unlock; (exit "$saved_rc"); restore; }
trap restore_locked EXIT
# Existing engine location stays unchanged. New installs use USB; --data never moves BINDIR.
[ -n "$sub_dir" ] || sub_dir="$DATA/subconverter"
case "$sub_dir" in "$DATA"/*) ;; *) fail '引擎不在指定 USB 下；请选其现有挂载根目录作为 --data' ;; esac
[ ! -L "$sub_dir" ] || fail '引擎目录不能是软链接'
[ -d "$sub_dir" ] && [ "$(ls -nd "$sub_dir" | awk '{print $3}')" != 0 ] && fail '引擎目录不是 root 所有'
ENGINE_DIR="$sub_dir"; ENGINE_EXISTED=0; ENGINE_TOUCHED=0; RESOURCE_CHANGED=0
if [ -d "$sub_dir" ]; then
    tar -czf "$BACKUP/engine.tgz" -C "$sub_dir" . || exit 1
    ENGINE_EXISTED=1
fi
ENGINE_TOUCHED=1
# If official binary already matches, retain the running process and libraries.
if [ ! -f "$sub_dir/subconverter" ] || [ "$(sha "$sub_dir/subconverter")" != "$(sha "$PKG/subconverter-arm64/subconverter")" ]; then
    sc_cfg sub_dir "$sub_dir" || exit 1
    subconv_install_package "$PKG/subconverter-arm64" v1.10.1 || exit 1
fi
[ -d "$sub_dir/base" ] || exit 1
if [ -d "$sub_dir/base/base/rules" ]; then tar -czf "$BACKUP/previous-rules.tgz" -C "$sub_dir/base/base" rules || exit 1; fi
mkdir -p "$sub_dir/base/base/rules" || exit 1
for src in "$PKG/rules/"*.list; do
    name=$(basename "$src")
    cmp -s "$src" "$sub_dir/base/base/rules/$name" || RESOURCE_CHANGED=1
    cp "$src" "$sub_dir/base/base/rules/$name.new" && mv -f "$sub_dir/base/base/rules/$name.new" "$sub_dir/base/base/rules/$name" || exit 1
done
cp "$PKG/rule-map.tsv" "$sub_dir/base/rule-map.tsv.new" && mv -f "$sub_dir/base/rule-map.tsv.new" "$sub_dir/base/rule-map.tsv" || exit 1
for src in "$PKG/templates/"*.ini; do
    dst="$CRASHDIR/subconverter/config/$(basename "$src")"
    cmp -s "$src" "$dst" || RESOURCE_CHANGED=1
    cp "$src" "$dst.new" && mv -f "$dst.new" "$dst" || exit 1
done
sc_cfg sub_dir "$sub_dir" && sc_cfg local_data "$DATA" &&
    sc_cfg local_upx_sha256 871d65c543cfda923d8502b92a58d4934c434aead8746d7b4a7f6dad66eb3dad || exit 1
# Preserve explicit settings; enable new functions only when not configured yet.
for setting in 'sub_local ON' 'sub_only ON' 'local_heal ON' 'local_maintenance ON' 'local_backup_keep 3' 'local_usb_wait 30'; do
    set -- $setting
    grep -q "^$1=" "$CRASHDIR/configs/ShellCrash.cfg" || sc_cfg "$1" "$2" || exit 1
done
CRASHDIR="$CRASHDIR" sh "$CRASHDIR/local/apply.sh" || exit 1
# Reapplying must be safe and have no duplicate injection.
CRASHDIR="$CRASHDIR" sh "$CRASHDIR/local/apply.sh" || exit 1
. "$CRASHDIR/libs/get_config.sh" || :
# Invalidate in-memory config/rules caches only when packaged resources changed.
if [ "$RESOURCE_CHANGED" = 1 ]; then subconv_stop force || exit 1; fi
subconv_start || fail '本地转换引擎未通过启动检查'
[ "$REGISTER" = 0 ] || sc_register_cron || exit 1
# Public data stays separate from private backups; never replace existing database files.
PUBLIC_GEO="$DATA/ShellCrash-public-geodata"
if [ -e "$PUBLIC_GEO" ] || [ -L "$PUBLIC_GEO" ]; then sc_root_owned "$PUBLIC_GEO" || exit 1
else mkdir -m 755 "$PUBLIC_GEO" || exit 1; fi
chmod 755 "$PUBLIC_GEO" || exit 1
for rel in ruleset/cn.mrs cn_ip.txt cn_ipv6.txt Country.mmdb GeoSite.dat; do
    parent=$(dirname "$PUBLIC_GEO/$rel")
    [ ! -L "$parent" ] || exit 1
    mkdir -p "$parent" && chmod 755 "$parent" || exit 1
    dst="$PUBLIC_GEO/$rel"
    [ ! -L "$dst" ] || exit 1
    cp "$PKG/geodata/$rel" "$dst.new" && chmod 644 "$dst.new" && mv -f "$dst.new" "$dst" || exit 1
done
CREATED_GEO=''
seed_geo() {
    rel="$1"
    [ ! -e "$BINDIR/$rel" ] && [ ! -L "$BINDIR/$rel" ] || return 0
    mkdir -p "$(dirname "$BINDIR/$rel")" || return 1
    ln -s "$PUBLIC_GEO/$rel" "$BINDIR/$rel" || return 1
    CREATED_GEO="$CREATED_GEO $rel"
}
case "$dns_mod" in mix|route) seed_geo ruleset/cn.mrs || exit 1 ;; esac
if [ "$cn_ip_route" = ON ]; then
    seed_geo cn_ip.txt || exit 1
    [ "$ipv6_redir" != ON ] || seed_geo cn_ipv6.txt || exit 1
fi
if grep -qi 'GEOIP,CN' "$CRASHDIR/yamls/config.yaml" 2>/dev/null; then seed_geo Country.mmdb || exit 1; fi
if grep -qi 'GEOSITE,' "$CRASHDIR/yamls/config.yaml" 2>/dev/null; then seed_geo GeoSite.dat || exit 1; fi
# Features are now installed; core is a separate transaction with its own verified rollback.
PHASE=features-done
if [ "$WITH_CORE" = 1 ]; then
    current=$(sc_version)
    if [ "$current" = v1.19.32 ]; then
        sc_cfg core_v v1.19.32 || exit 1
        echo '实际核心已是 v1.19.32，保留当前进程。'
    else
        [ "$crashcore" = meta ] || fail '现有核心不是 Mihomo；功能已整合，未切换核心类型'
        sc_version_newer v1.19.32 "$current" || fail '拒绝用打包核心降级；功能已整合'
        "$PKG/core/CrashCore.upx" -t -d "$BINDIR" -f "$TMPDIR/config.yaml" >"$BACKUP/core-config-check.log" 2>&1 || fail '现有配置与打包核心不兼容；功能已整合，原核心保留'
        sc_install_core "$PKG/core/CrashCore.upx" v1.19.32 || exit 1
    fi
fi
echo "整合完成；维护菜单 crash → 8 → a；部署备份：$BACKUP"
echo '已安装 19 个本地模板、83 个公开规则快照；订阅地址和设备配置保持原设置。'
exit 0
