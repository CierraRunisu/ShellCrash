sc_release() {
    sc_storage || return 1
    command -v jsonfilter >/dev/null 2>&1 || { echo '需要 jsonfilter 解析官方发布信息'; return 1; }
    local request="$1" url tag file="$SC_STATE/release.$$.json" arch name expected_url
    if [ "$request" = latest ]; then url=https://api.github.com/repos/MetaCubeX/mihomo/releases/latest
    else
        printf '%s' "$request" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || return 1
        url="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/$request"
    fi
    if ! sc_https_fetch "$url" "$file" 30; then
        rm -f "$file"; echo '无法通过有效 HTTPS 获取官方发布信息'; return 1
    fi
    tag=$(jsonfilter -i "$file" -e '@.tag_name')
    printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || { rm -f "$file"; return 1; }
    case "$(uname -m)" in
    aarch64|arm64) arch=arm64 ;;
    x86_64) arch=amd64-compatible ;;
    armv7*) arch=armv7 ;;
    *) rm -f "$file"; echo '当前架构不支持安全核心更新'; return 1 ;;
    esac
    name="mihomo-linux-$arch-$tag.gz"
    SC_ASSET_URL=$(jsonfilter -i "$file" -e "@.assets[@.name=\"$name\"].browser_download_url")
    SC_ASSET_SHA=$(jsonfilter -i "$file" -e "@.assets[@.name=\"$name\"].digest" | sed 's/^sha256://')
    rm -f "$file"
    expected_url="https://github.com/MetaCubeX/mihomo/releases/download/$tag/$name"
    [ "$SC_ASSET_URL" = "$expected_url" ] || { echo '资产 URL 与官方预期不符'; return 1; }
    printf '%s' "$SC_ASSET_SHA" | grep -qE '^[0-9a-f]{64}$' || { echo '官方缺少有效 SHA-256，已拒绝更新'; return 1; }
    SC_RELEASE="$tag"
    (umask 077; printf '%s\n' "$tag" >"$SC_DATA/latest-version") || return 1
    return 0
}
sc_wait_stopped() {
    local n=0
    while pidof CrashCore >/dev/null 2>&1; do
        [ "$n" -lt 30 ] || return 1
        sleep 1; n=$((n+1))
    done
}
sc_wait_healthy() {
    local n=0
    while [ "$n" -lt "${SC_HEALTH_TRIES:-20}" ]; do
        sc_health "$1" "$2" && return 0
        sleep 2; n=$((n+1))
    done
    return 1
}
sc_core_backup() {
    local folder checksum version
    [ -s "$BINDIR/CrashCore.upx" ] || { echo '现有核心不是受支持的 UPX 存储格式' >&2; return 1; }
    folder=$(mktemp -d "$SC_DATA/backups/core-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
    chmod 700 "$folder" || return 1
    printf '%s\n' SC_LOCAL_BACKUP_V1 >"$folder/.sc-owned"
    cp -p "$BINDIR/CrashCore.upx" "$folder/core.upx" || return 1
    checksum=$(sc_sha "$BINDIR/CrashCore.upx") || return 1
    [ "$checksum" = "$(sc_sha "$folder/core.upx")" ] || return 1
    printf '%s\n' "$checksum" >"$folder/core.sha256"
    version=$(sc_version)
    printf '%s' "$version" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    printf '%s\n' "$version" >"$folder/version"
    cp -p "$CRASHDIR/configs/ShellCrash.cfg" "$folder/ShellCrash.cfg"
    cp -p "$CRASHDIR/configs/command.env" "$folder/command.env"
    chmod 600 "$folder/ShellCrash.cfg" "$folder/command.env" "$folder/core.upx"
    # The trusted digest stays on internal storage, separate from removable backups.
    (umask 077; printf '%s\t%s\t%s\n' "$checksum" "$version" "$(basename "$folder")" >>"$CRASHDIR/local/backup-index.tsv") || return 1
    chmod 600 "$CRASHDIR/local/backup-index.tsv" || return 1
    # Executable permission is restored only for actual validation/rollback.
    printf '%s\n' "$folder"
}
sc_restore_core() {
    local backup="$1" old version trusted trusted_sha trusted_version temp="$BINDIR/.sc-core-restore.$$"
    case "$backup" in "$SC_DATA/backups/core-"*) ;; *) return 1 ;; esac
    [ "$(readlink -f "$backup")" = "$backup" ] || return 1
    [ "$(cat "$backup/.sc-owned" 2>/dev/null)" = SC_LOCAL_BACKUP_V1 ] || return 1
    trusted=$(awk -F '\t' -v id="$(basename "$backup")" '$3==id {hash=$1;version=$2} END {print hash " " version}' "$CRASHDIR/local/backup-index.tsv" 2>/dev/null) || return 1
    read -r trusted_sha trusted_version <<EOF
$trusted
EOF
    [ -n "$trusted_sha" ] && [ "$(sc_sha "$backup/core.upx")" = "$trusted_sha" ] || { echo '备份与内置可信索引不符，拒绝执行'; return 1; }
    [ "$trusted_sha" = "$(cat "$backup/core.sha256")" ] || return 1
    version=$(cat "$backup/version")
    [ "$version" = "$trusted_version" ] || return 1
    printf '%s' "$version" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    chmod 700 "$backup/core.upx" || return 1
    if ! "$backup/core.upx" -t -d "$BINDIR" -f "$TMPDIR/config.yaml" >/dev/null 2>&1; then
        chmod 600 "$backup/core.upx"; echo '旧核心不兼容当前配置，未执行回滚'; return 1
    fi
    chmod 600 "$backup/core.upx"
    SC_MANAGER_RECOVERY=1 "$CRASHDIR/start.sh" stop >/dev/null 2>&1
    sc_wait_stopped || return 1
    rm -f "$BINDIR/CrashCore.upx" "$BINDIR/.sc-core-new.$$"
    cp "$backup/core.upx" "$temp" && [ "$(sc_sha "$temp")" = "$(cat "$backup/core.sha256")" ] &&
        chmod 755 "$temp" && mv -f "$temp" "$BINDIR/CrashCore.upx" || return 1
    sc_cfg core_v "$version" && sc_cfg zip_type upx || return 1
    ln -sf "$BINDIR/CrashCore.upx" "$TMPDIR/CrashCore"
    SC_MANAGER_RECOVERY=1 "$CRASHDIR/start.sh" start >/dev/null 2>&1
    sc_wait_healthy "$version" ''
}
sc_install_core() (
    # The standalone transaction is shared by verified download and rollback tests.
    candidate="$1" version="$2"
    expected=$(sc_sha "$candidate") || return 1
    [ "$(sc_version "$candidate")" = "$version" ] || return 1
    sc_health '' network || { echo '现有服务/代理网络不健康，未开始替换'; return 1; }
    backup=$(sc_core_backup) || return 1
    printf '%s\n' "$backup" >"$SC_DATA/rollback-backup"
    changed=0
    stopped=0
    temp="$BINDIR/.sc-core-new.$$"
    transaction_exit() {
        rc=$?
        trap - EXIT HUP INT TERM
        if [ "$rc" != 0 ] && [ "$stopped" = 1 ]; then
            sc_log "Core update $version failed; restoring verified backup"
            if [ "$changed" = 1 ]; then
                sc_restore_core "$backup" || { echo "回滚未能完成，备份位于：$backup" >&2; sc_log 'CRITICAL: rollback needs manual attention'; exit 2; }
            else
                SC_MANAGER_RECOVERY=1 "$CRASHDIR/start.sh" start >/dev/null 2>&1
            fi
            printf '%s rollback completed\n' "$version" >"$SC_STATE/last-update"
            echo '新版本未通过健康检查，已恢复旧核心。'
        fi
        rm -f "$temp"
        exit "$rc"
    }
    trap transaction_exit EXIT
    trap 'exit 1' HUP INT TERM
    free=$(sc_free "$BINDIR")
    required=$(( ($(wc -c <"$candidate")+1023)/1024 + 2048 ))
    old_blocks=$(du -k "$BINDIR/CrashCore.upx" | awk '{print $1}')
    [ -n "$free" ] && [ "$((free+old_blocks))" -ge "$required" ] || { echo '内置盘空间不足，保留原核心'; return 1; }
    if [ "$free" -ge "$required" ]; then
        cp "$candidate" "$temp" && [ "$(sc_sha "$temp")" = "$expected" ] || return 1
    fi
    stopped=1
    SC_MANAGER_RECOVERY=1 "$CRASHDIR/start.sh" stop >/dev/null 2>&1
    sc_wait_stopped || return 1
    changed=1
    if [ ! -s "$temp" ]; then
        rm -f "$BINDIR/CrashCore.upx"
        cp "$candidate" "$temp" || return 1
    fi
    [ "$(sc_sha "$temp")" = "$expected" ] && chmod 755 "$temp" &&
        mv -f "$temp" "$BINDIR/CrashCore.upx" || return 1
    sc_cfg core_v "$version" && sc_cfg zip_type upx || return 1
    ln -sf "$BINDIR/CrashCore.upx" "$TMPDIR/CrashCore"
    SC_MANAGER_RECOVERY=1 "$CRASHDIR/start.sh" start >/dev/null 2>&1
    sc_wait_healthy "$version" network || return 1
    printf '%s verified, installed and healthy\n' "$version" >"$SC_STATE/last-update"
    sc_log "Core update $version passed version/rule/proxy health checks"
    echo "核心 $version 更新成功；备份：$backup"
    return 0
)
sc_update_finish() {
    if [ -n "$SC_UPDATE_STAGE" ]; then
        case "$SC_UPDATE_STAGE" in "$SC_DATA/downloads/core."*)
            [ -L "$SC_UPDATE_STAGE" ] || {
                rm -f "$SC_UPDATE_STAGE/core.gz" "$SC_UPDATE_STAGE/core.raw" "$SC_UPDATE_STAGE/core.upx" "$SC_UPDATE_STAGE/upx.log" "$SC_UPDATE_STAGE/config-check.log" "$SC_UPDATE_STAGE/.sc-owned"
                rmdir "$SC_UPDATE_STAGE" 2>/dev/null || :
            }
            ;;
        esac
    fi
    sc_unlock
}
sc_update() {
    [ "$crashcore" = meta ] || { echo '此安全更新器仅处理 Mihomo；其他核心保留原入口'; return 1; }
    sc_lock update || { echo '已有维护/核心更新正在进行'; return 1; }
    trap sc_update_finish EXIT
    trap 'exit 1' HUP INT TERM
    sc_release "${1:-latest}" || return 1
    local current stage tool known actual free rc
    current=$(sc_version)
    if [ "$current" = "$SC_RELEASE" ]; then echo "已经是 $current，无需重启或重新下载。"; return 0; fi
    sc_version_newer "$SC_RELEASE" "$current" || { echo "拒绝降级：本地 $current，官方目标 $SC_RELEASE。需要旧版请使用明确的回滚入口。"; return 1; }
    free=$(sc_free "$SC_DISK")
    [ -n "$free" ] && [ "$free" -gt 204800 ] || { echo 'USB 至少需要 200 MiB 空间用于下载、压缩和备份'; return 1; }
    tool="$CRASHDIR/tools/upx-linux-$cpucore"
    known="${local_upx_sha256:-}"
    actual=$(sc_sha "$tool") || return 1
    [ -n "$known" ] && [ "$known" = "$actual" ] || { echo 'UPX 工具尚未通过已登记的可信 SHA-256 校验'; return 1; }
    stage=$(mktemp -d "$SC_DATA/downloads/core.XXXXXX") || return 1
    SC_UPDATE_STAGE="$stage"
    chmod 700 "$stage"
    printf '%s\n' SC_LOCAL_DOWNLOAD_V1 >"$stage/.sc-owned" || return 1
    echo "下载官方 $SC_RELEASE，HTTPS 与 SHA-256 校验均为强制。"
    if ! sc_https_fetch "$SC_ASSET_URL" "$stage/core.gz" 180 ||
        [ "$(sc_sha "$stage/core.gz")" != "$SC_ASSET_SHA" ]; then
        rm -f "$stage/core.gz" "$stage/.sc-owned"; rmdir "$stage"; echo '下载或官方 SHA-256 校验失败，未替换核心'; return 1
    fi
    gzip -dc "$stage/core.gz" >"$stage/core.raw" || return 1
    chmod 755 "$stage/core.raw"
    [ "$(sc_version "$stage/core.raw")" = "$SC_RELEASE" ] || return 1
    echo '开始 UPX -9 压缩；现有核心继续运行。'
    "$tool" -9 -q -o "$stage/core.upx" "$stage/core.raw" >"$stage/upx.log" 2>&1 || { echo 'UPX 压缩失败，未替换核心'; return 1; }
    chmod 755 "$stage/core.upx"
    "$tool" -t "$stage/core.upx" >/dev/null 2>&1 || return 1
    [ "$(sc_version "$stage/core.upx")" = "$SC_RELEASE" ] || return 1
    "$stage/core.upx" -t -d "$BINDIR" -f "$TMPDIR/config.yaml" >"$stage/config-check.log" 2>&1 || { echo '现有配置不兼容新核心，未替换'; return 1; }
    sc_install_core "$stage/core.upx" "$SC_RELEASE"
    rc=$?
    # Scratch artifacts may contain validation details; never export them as diagnostics.
    rm -f "$stage/core.gz" "$stage/core.raw" "$stage/core.upx" "$stage/upx.log" "$stage/config-check.log" "$stage/.sc-owned"
    rmdir "$stage"
    [ "$rc" = 0 ] && sc_maintain
    return "$rc"
}
sc_rollback() {
    sc_storage || return 1
    local backup
    backup=$(cat "$SC_DATA/rollback-backup" 2>/dev/null) || { echo '尚无核心备份；请先创建核心快照或执行安全更新。'; return 1; }
    sc_lock update || return 1
    trap sc_unlock EXIT
    sc_restore_core "$backup" || return 1
    sc_log 'Manual core rollback completed'
    echo '已恢复最近的校验备份，服务健康检查通过。'
}
sc_snapshot_core() {
    sc_storage || return 1
    sc_lock update || return 1
    trap sc_unlock EXIT
    local backup
    backup=$(sc_core_backup) || return 1
    printf '%s\n' "$backup" >"$SC_DATA/rollback-backup"
    printf '核心快照已校验：%s\n' "$backup"
}
