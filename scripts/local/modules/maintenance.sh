sc_intent() {
    [ "$SC_MANAGER_RECOVERY" != 1 ] || return 0
    case "$1" in
    stop) : >"$SC_STATE/user-stopped" ;;
    start|restart) rm -f "$SC_STATE/user-stopped" "$SC_STATE/heal-blocked" "$SC_STATE/heal-attempts" "$SC_STATE/security-pending" ;;
    esac
}
sc_boot_wait() {
    local i=0
    [ "$local_heal" = ON ] || return 0
    subconv_needed || return 0
    while ! sc_mount_ready; do
        [ "$i" -lt "${local_usb_wait:-30}" ] || { sc_log 'USB startup wait expired; strict local dependencies remain enforced'; return 1; }
        sleep 1; i=$((i+1))
    done
    subconv_start >/dev/null 2>&1
}
sc_register_cron() {
    local temp="$SC_STATE/cron.$$"
    crontab -l >"$temp.original" 2>/dev/null || : >"$temp.original"
    grep -vF '#ShellCrash-local-manager' "$temp.original" >"$temp" || :
    printf '*/2 * * * * /bin/sh "%s/local/manager.sh" tick >/dev/null 2>&1 #ShellCrash-local-manager\n' "$CRASHDIR" >>"$temp"
    crontab "$temp" || { rm -f "$temp" "$temp.original"; return 1; }
    rm -f "$temp" "$temp.original"
}
sc_prune_type() {
    local type="$1" keep="${local_backup_keep:-3}" count=0 folder protected=''
    case "$keep" in ''|*[!0-9]*) keep=3 ;; esac
    [ "$keep" -ge 2 ] || keep=2
    [ "$keep" -le 20 ] || keep=20
    [ ! -f "$SC_DATA/rollback-backup" ] || protected=$(cat "$SC_DATA/rollback-backup")
    # Only remove this manager's marked, direct, non-symlink backup directories.
    find "$SC_DATA/backups" -mindepth 1 -maxdepth 1 -type d -name "$type-[0-9]*" | sort -r |
    while IFS= read -r folder; do
        [ ! -L "$folder" ] || continue
        case "$folder" in "$SC_DATA/backups/$type-"*) ;; *) continue ;; esac
        [ "$(readlink -f "$folder")" = "$folder" ] || continue
        [ "$(cat "$folder/.sc-owned" 2>/dev/null)" = SC_LOCAL_BACKUP_V1 ] || continue
        count=$((count+1))
        [ "$count" -gt "$keep" ] || continue
        [ "$folder" != "$protected" ] || continue
        rm -rf "$folder" || return 1
        sc_log "Backup rotation: removed old $type snapshot"
    done
}
sc_maintain() {
    sc_storage || return 1
    # A daily tick creates a fresh configuration snapshot before applying retention.
    sc_backup_config >/dev/null || return 1
    sc_prune_type core
    sc_prune_type config
    local dir file count=0
    if ! sc_lock_alive "$SC_STATE/update.lock"; then
        find "$SC_DATA/downloads" -mindepth 1 -maxdepth 1 -type d -name 'core.*' -mtime +1 |
        while IFS= read -r dir; do
            [ ! -L "$dir" ] && [ "$(readlink -f "$dir")" = "$dir" ] || continue
            case "$dir" in "$SC_DATA/downloads/core."*) ;; *) continue ;; esac
            [ "$(cat "$dir/.sc-owned" 2>/dev/null)" = SC_LOCAL_DOWNLOAD_V1 ] || continue
            rm -f "$dir/core.gz" "$dir/core.raw" "$dir/core.upx" "$dir/upx.log" "$dir/config-check.log" "$dir/.sc-owned"
            rmdir "$dir" 2>/dev/null || :
        done
    fi
    # Only diagnostics created by this manager; never touch legacy user backups.
    find "$SC_DATA/diagnostics" -mindepth 1 -maxdepth 1 -type f -name 'diagnostic-[0-9]*.tar.gz' | sort -r |
    while IFS= read -r file; do
        count=$((count+1))
        [ "$count" -le 5 ] || rm -f "$file"
    done
    dir=$(subconv_dir)
    file="$dir/logs/run.log"
    if [ -f "$file" ] && [ "$(wc -c <"$file")" -gt 524288 ]; then
        tail -n 300 "$file" >"$SC_STATE/engine-tail"
        # Write the existing inode because the engine may keep it open.
        cat "$SC_STATE/engine-tail" >"$file"
        rm -f "$SC_STATE/engine-tail"
        sc_log 'Space maintenance: engine log compacted'
    fi
    [ ! -f "$CRASHDIR/local/apply.log" ] || [ "$(wc -c <"$CRASHDIR/local/apply.log")" -lt 131072 ] || {
        tail -n 100 "$CRASHDIR/local/apply.log" >"$SC_STATE/apply-tail"
        cat "$SC_STATE/apply-tail" >"$CRASHDIR/local/apply.log"; rm -f "$SC_STATE/apply-tail"
    }
    printf '%s\n' "$(sc_now)" >"$SC_STATE/last-maintenance"
}
sc_space() {
    printf '内核目录剩余：%s KiB\n' "$(sc_free "$BINDIR")"
    printf '核心：'; du -k "$BINDIR/CrashCore.upx" 2>/dev/null | awk '{print $1 " KiB"}'
    printf '提供者缓存：'; du -sk "$BINDIR/providers" 2>/dev/null | awk '{print $1 " KiB"}'
    if sc_mount_ready; then
        printf 'USB 剩余：%s KiB\n' "$(sc_free "$SC_DISK")"
        [ ! -d "$SC_DATA/backups" ] || du -sk "$SC_DATA/backups" | awk '{print "维护备份：" $1 " KiB"}'
    else echo 'USB 未挂载；不会在挂载点底下新建缓存。'; fi
    echo '自动轮换仅删除本维护中心创建并标记的旧备份，始终保留最近可回退核心。'
    echo '不删除原有历史备份、订阅缓存或规则缓存。'
}
sc_tick() {
    [ "$local_heal" = ON ] || [ "$local_maintenance" = ON ] || return 0
    sc_lock tick || return 0
    trap sc_unlock EXIT
    trap 'exit 1' HUP INT TERM
    sc_lock_alive "$SC_STATE/update.lock" && return 0
    if ! sc_mount_ready; then
        if [ ! -f "$SC_STATE/usb-pending" ]; then
            : >"$SC_STATE/usb-pending"
            sc_log 'USB unavailable: waiting; no online conversion fallback or core restart'
        fi
        return 0
    fi
    if [ -f "$SC_STATE/usb-pending" ]; then
        rm -f "$SC_STATE/usb-pending" "$SC_STATE/heal-blocked" "$SC_STATE/heal-attempts"
        sc_log 'USB returned: dependency recovery enabled'
    fi
    local available
    available=$(sc_free "$BINDIR")
    if [ -n "$available" ] && [ "$available" -lt 5120 ]; then
        [ -f "$SC_STATE/low-space" ] || { : >"$SC_STATE/low-space"; sc_log 'Internal storage below 5 MiB; check space before updates'; }
    else rm -f "$SC_STATE/low-space"; fi
    if [ "$local_heal" = ON ] && [ ! -f "$SC_STATE/user-stopped" ] && [ ! -f "$SC_STATE/heal-blocked" ] &&
        { [ ! -f "$CRASHDIR/.dis_startup" ] || pidof CrashCore >/dev/null 2>&1; }; then
        local needs=0 core_bad=0 attempts=0 last=0 now
        if subconv_needed; then subconv_ready >/dev/null 2>&1 || needs=1; fi
        pidof CrashCore >/dev/null 2>&1 || needs=1
        [ -f "$SC_STATE/security-pending" ] || sc_api version >/dev/null 2>&1 || { needs=1; core_bad=1; }
        if [ "$needs" = 1 ]; then
            [ ! -f "$SC_STATE/heal-attempts" ] || read -r attempts last <"$SC_STATE/heal-attempts"
            now=$(sc_now)
            if [ "$((now-last))" -ge 120 ]; then
                if [ "$attempts" -ge 3 ]; then
                    : >"$SC_STATE/heal-blocked"; sc_log 'Self-heal paused after 3 failed attempts; manual attention required'
                    return 0
                fi
                attempts=$((attempts+1))
                printf '%s %s\n' "$attempts" "$now" >"$SC_STATE/heal-attempts"
                if subconv_needed; then
                    subconv_start >/dev/null 2>&1 || { sc_log 'Self-heal: local engine recovery failed'; return 0; }
                fi
                [ ! -f "$SC_STATE/user-stopped" ] || return 0
                if ! pidof CrashCore >/dev/null 2>&1; then
                    SC_MANAGER_RECOVERY=1 "$CRASHDIR/start.sh" start >/dev/null 2>&1
                    sleep 2
                elif [ "$core_bad" = 1 ]; then
                    SC_MANAGER_RECOVERY=1 "$CRASHDIR/start.sh" restart >/dev/null 2>&1
                    sleep 2
                fi
                if sc_health '' ''; then
                    rm -f "$SC_STATE/heal-attempts"
                    sc_log 'Self-heal: engine/core recovered'
                else sc_log 'Self-heal: recovery not yet healthy'; fi
            fi
        else rm -f "$SC_STATE/heal-attempts"; fi
    fi
    if [ "$local_maintenance" = ON ]; then
        local last=0 now
        [ ! -f "$SC_STATE/last-maintenance" ] || last=$(cat "$SC_STATE/last-maintenance")
        now=$(sc_now)
        [ "$((now-last))" -lt 86400 ] || sc_maintain
    fi
    return 0
}
sc_diagnostic() {
    sc_storage || return 1
    local dir archive file
    dir=$(mktemp -d "$SC_STATE/diagnostic.XXXXXX") || return 1
    chmod 700 "$dir"
    archive="$SC_DATA/diagnostics/diagnostic-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
    sc_status >"$dir/status.txt"
    { uname -srm; awk '/MemTotal:|MemAvailable:|MemFree:/ {print}' /proc/meminfo; } >"$dir/system.txt"
    {
        for file in libs/core_upx.sh libs/subconv.sh local/apply.sh local/manager.sh local/modules/common.sh local/modules/status.sh local/modules/maintenance.sh local/modules/update.sh starts/bfstart.sh starts/core_config.sh task/task.sh; do
            [ ! -f "$CRASHDIR/$file" ] || printf '%s %s\n' "$(sc_sha "$CRASHDIR/$file")" "$file"
        done
        [ ! -f "$BINDIR/CrashCore.upx" ] || printf '%s %s\n' "$(sc_sha "$BINDIR/CrashCore.upx")" 'active-core/CrashCore.upx'
    } >"$dir/script-checksums.txt"
    {
        [ -n "$secret" ] && echo 'controller_secret=configured' || echo 'controller_secret=missing'
        [ -n "$authentication" ] && echo 'proxy_auth=configured' || echo 'proxy_auth=missing'
        printf 'sub_only=%s\nsub_local=%s\nlocal_heal=%s\n' "$sub_only" "$sub_local" "$local_heal"
        ls -ld "$CRASHDIR/configs"
        ls -l "$CRASHDIR/configs/ShellCrash.cfg" "$CRASHDIR/task/task.sh"
    } >"$dir/security-summary.txt"
    # No raw log/config/command line/environment/subscription file is copied.
    printf '%s\n' '此包仅含白名单状态、计数和脚本摘要；不含订阅、节点、密码、UUID、原始配置、原始日志或设备主机名。' >"$dir/README.txt"
    (umask 077; tar -czf "$archive" -C "$dir" .) || return 1
    rm -f "$dir/status.txt" "$dir/system.txt" "$dir/script-checksums.txt" "$dir/security-summary.txt" "$dir/README.txt"
    rmdir "$dir"
    sc_log 'Allowlisted diagnostic package created'
    printf '%s\n' "$archive"
}
