#!/bin/sh
# Independent local maintenance entry. Configuration/credentials must never be traced.
set +x
[ "$(id -u)" = 0 ] || { echo '本地维护中心需要 root 权限'; exit 1; }
[ -n "$CRASHDIR" ] || CRASHDIR=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$CRASHDIR/configs/ShellCrash.cfg" ] || { echo 'ShellCrash 配置不存在'; exit 1; }
. "$CRASHDIR/libs/get_config.sh" || :
. "$CRASHDIR/libs/subconv.sh" || exit 1
SC_STATE=/tmp/ShellCrash-local-manager
[ ! -L "$SC_STATE" ] || { echo '维护状态目录不能是软链接'; exit 1; }
if [ -d "$SC_STATE" ]; then
    [ "$(ls -nd "$SC_STATE" | awk '{print $3}')" = 0 ] || { echo '维护状态目录不是 root 所有，拒绝使用'; exit 1; }
else
    (umask 077; mkdir "$SC_STATE") || exit 1
fi
chmod 700 "$SC_STATE" || exit 1
SC_LOCK=''
SC_DISK="${local_data:-$(dirname "${sub_dir:-$BINDIR/subconverter}")}"
SC_DATA="$SC_DISK/ShellCrash-local"
for module in common status maintenance update; do . "$CRASHDIR/local/modules/$module.sh" || exit 1; done
sc_menu() {
    while :; do
        printf '\n本地维护中心\n1) 运行状态总览\n2) 安全设置向导\n3) 官方核心安全更新（UPX + 校验 + 自动回滚）\n4) 回滚最近核心备份\n5) USB / 自愈设置\n6) 空间管理与备份轮换\n7) 生成脱敏诊断包\n8) 深度健康检查（含代理联网）\n0) 返回\n'
        read -r -p '选择> ' choice
        case "$choice" in
        1) sc_status ;;
        2) sc_security_menu ;;
        3) (sc_update latest) ;;
        4) read -r -p '将停止服务并恢复备份，确认输入 yes> ' yes; [ "$yes" != yes ] || (sc_rollback) ;;
        5)
            printf '当前自愈：%s\n1) 启用\n2) 停用\n3) 清除重试上限并尝试恢复\n0) 返回\n' "${local_heal:-OFF}"
            read -r -p '选择> ' action
            case "$action" in
            1) sc_cfg local_heal ON && local_heal=ON; sc_register_cron ;;
            2) sc_cfg local_heal OFF && local_heal=OFF ;;
            3) rm -f "$SC_STATE/heal-blocked" "$SC_STATE/heal-attempts" "$SC_STATE/user-stopped"; (sc_tick) ;;
            esac
            ;;
        6)
            sc_space
            printf '1) 立即备份配置\n2) 立即轮换与压缩超限日志\n3) 创建当前核心快照（不重启）\n0) 返回\n'
            read -r -p '选择> ' action
            case "$action" in 1) sc_backup_config ;; 2) sc_maintain ;; 3) (sc_snapshot_core) ;; esac
            ;;
        7) sc_diagnostic ;;
        8) if sc_health "$(sc_version)" network; then echo '核心、规则、引擎与代理网络检查通过'; else echo '健康检查未通过，请查看状态和最近维护事件'; fi ;;
        *) return 0 ;;
        esac
    done
}
case "${1:-menu}" in
menu) sc_menu ;;
status) sc_status ;;
version) sc_version ;;
latest-cached) [ ! -f "$SC_DATA/latest-version" ] || cat "$SC_DATA/latest-version" ;;
check) sc_release "${2:-latest}" && printf '官方目标：%s；本地实际：%s\n' "$SC_RELEASE" "$(sc_version)" ;;
security) sc_security_report ;;
update) sc_update "${2:-latest}" ;;
rollback) sc_rollback ;;
tick) sc_tick ;;
boot-wait) sc_boot_wait ;;
intent) sc_intent "$2" ;;
register) sc_register_cron ;;
space) sc_space ;;
maintain) sc_maintain ;;
backup) sc_backup_config ;;
backup-core) sc_snapshot_core ;;
diagnostics) sc_diagnostic ;;
health) sc_health "$2" "$3" ;;
*) echo '用法：manager.sh menu|status|check|update [latest|vX.Y.Z]|rollback|security|tick|space|maintain|backup|diagnostics'; exit 1 ;;
esac
