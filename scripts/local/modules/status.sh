sc_status() {
    local running recorded counts total nonempty sum free
    running=$(sc_version)
    recorded=$(sed -n 's/^core_v=//p' "$CRASHDIR/configs/ShellCrash.cfg" | tail -1 | tr -d "'\"")
    printf 'ShellCrash 本地维护中心 v1\n'
    printf '核心实际版本：%s；配置记录：%s\n' "${running:-不可用}" "${recorded:-未知}"
    printf '核心进程：%s\n' "$(pidof CrashCore 2>/dev/null || echo 未运行)"
    if sc_api version >/dev/null; then echo '控制接口：正常'; else echo '控制接口：不可用/鉴权失败'; fi
    if subconv_ready >/dev/null 2>&1; then echo '转换引擎：就绪'; else echo '转换引擎：未就绪'; fi
    printf '仅本地转换：%s；转换后偏好常驻：%s\n' "${sub_only:-OFF}" "${sub_keep:-ON}"
    counts=$(sc_rules) && { read -r total nonempty sum <<EOF
$counts
EOF
        printf '规则集：%s/%s 非空，共 %s 条\n' "$nonempty" "$total" "$sum"
    }
    free=$(sc_free "$BINDIR")
    printf '内核目录剩余：%s KiB\n' "${free:-未知}"
    if sc_mount_ready; then printf 'USB：已挂载，剩余 %s KiB\n' "$(sc_free "$SC_DISK")"; else echo 'USB：未挂载，等待恢复'; fi
    printf '自愈：%s；空间维护：%s；保留备份：%s 份/类型\n' "${local_heal:-OFF}" "${local_maintenance:-OFF}" "${local_backup_keep:-3}"
    [ ! -f "$SC_STATE/user-stopped" ] || echo '内核：用户主动停止，自愈不会拉起'
    [ ! -f "$CRASHDIR/.dis_startup" ] || echo '自启动已关闭；自愈不会启动已停止的内核'
    [ ! -f "$SC_STATE/low-space" ] || echo '空间提示：内置盘不足 5 MiB，更新时需要 USB 暂存'
    [ ! -f "$SC_STATE/security-pending" ] || echo '控制密钥已更新，等待手动重启；暂不因接口鉴权失败自动重启'
    [ ! -f "$SC_STATE/heal-blocked" ] || echo '自愈：达到重试上限；使用维护菜单重新允许恢复'
    [ ! -f "$SC_STATE/last-update" ] || { printf '最近核心更新：'; cat "$SC_STATE/last-update"; }
    [ ! -f "$SC_DATA/latest-version" ] || { printf '官方发布缓存：'; cat "$SC_DATA/latest-version"; }
    [ ! -f "$SC_STATE/events.log" ] || { echo '最近维护事件：'; tail -n 3 "$SC_STATE/events.log"; }
    return 0
}
sc_security_report() {
    echo '安全向导：以下为只读检查，不会自动设置密码或改访问范围。'
    [ -n "$secret" ] && echo '控制接口密钥：已配置' || echo '控制接口密钥：未配置（局域网访问也需要考虑）'
    [ -n "$authentication" ] && echo '混合代理认证：已配置' || echo '混合代理认证：未配置'
    [ "$skip_cert" = OFF ] && echo '上游下载证书校验：已开启' || echo '上游下载证书校验：默认跳过'
    echo '配置目录/订阅权限：'
    ls -ld "$CRASHDIR/configs"
    for file in ShellCrash.cfg providers.cfg providers_uri.cfg command.env; do
        [ ! -f "$CRASHDIR/configs/$file" ] || ls -l "$CRASHDIR/configs/$file"
    done
    echo '安全核心更新始终校验 HTTPS 证书与 GitHub 官方资产 SHA-256，不受上游 skip_cert 影响。'
}
sc_security_harden() {
    [ "$1" = no-backup ] || sc_backup_config >/dev/null || return 1
    chmod 750 "$CRASHDIR/configs" "$CRASHDIR/configs/task" || return 1
    for file in ShellCrash.cfg providers.cfg providers_uri.cfg command.env gateway.cfg; do
        [ ! -f "$CRASHDIR/configs/$file" ] || chmod 600 "$CRASHDIR/configs/$file" || return 1
    done
    sc_log 'Security: private configuration permissions hardened'
    echo '配置权限已收紧；没有修改密码、监听地址或重启服务。'
}
sc_security_token() {
    local token backup
    command -v openssl >/dev/null || return 1
    backup=$(sc_backup_config) || return 1
    sc_security_harden no-backup >/dev/null || return 1
    token=$(openssl rand -hex 32) || return 1
    [ "${#token}" = 64 ] || return 1
    sc_cfg secret "$token" || return 1
    secret="$token"
    : >"$SC_STATE/security-pending"
    (umask 077; printf '%s\n' "$token" >"$backup/new-controller-key.txt") || return 1
    echo '新密钥已写入配置。重新启动服务后，面板需要输入此密钥：'
    printf '%s\n' "$token"
    echo '请保存密钥后自行重启服务。本操作未改变监听地址。'
    sc_log 'Security: controller key generated; restart pending'
}
sc_security_menu() {
    while :; do
        sc_security_report
        printf '\n1) 收紧配置权限（先备份）\n2) 生成控制接口强密钥并收紧权限（需重启，面板需重新登录）\n3) 开启上游下载证书校验\n0) 返回\n'
        read -r -p '选择> ' choice
        case "$choice" in
        1) sc_security_harden ;;
        2) read -r -p '确认生成新密钥？输入 yes> ' yes; [ "$yes" != yes ] || sc_security_token ;;
        3) sc_backup_config >/dev/null && sc_cfg skip_cert OFF && skip_cert=OFF && echo '已开启；证书或系统时间异常时下载将拒绝继续。' ;;
        *) return 0 ;;
        esac
    done
}
