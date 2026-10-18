#!/bin/sh
# 恢复本地挂钩：保留权限，验证语法，失败返回非零。
[ -z "$CRASHDIR" ] && CRASHDIR=$(cd "$(dirname "$0")/.." && pwd)
lock="$CRASHDIR/local/.apply.lock"
mkdir "$lock" 2>/dev/null || { echo '补丁程序已运行或目录不可写' >&2; exit 1; }
trap 'rm -rf "$lock"' EXIT
trap 'exit 1' HUP INT TERM
failed=0

inject() {
    f="$CRASHDIR/$1"
    [ -f "$f" ] || { echo "缺少文件：$1" >&2; failed=1; return 1; }
    tmp="$lock/target"
    existing=0
    grep -qF "${4:-$3}" "$f" && existing=1
    # cp -p 的元数据在写回时保留；环境变量防止 awk 转义 ANSI 文本。
    if ! cp -p "$f" "$tmp" || ! anchor="$2" hook="$3" marker="${4:-$3}" existing="$existing" replace="${5:-0}" scope="${6:-}" awk '
        BEGIN {in_scope=(ENVIRON["scope"] == "")}
        ENVIRON["scope"] != "" && /^[a-zA-Z_][a-zA-Z_0-9]*\(\)[[:space:]]*[{(]/ {in_scope=(index($0, ENVIRON["scope"] "()") == 1)}
        index($0, ENVIRON["marker"]) {if (!found) {s=$0; sub(/[^ ].*$/, "", s); print s ENVIRON["hook"]; found=1} next}
        !(ENVIRON["replace"] == "1" && index($0, ENVIRON["anchor"])) {print}
        ENVIRON["existing"] == "0" && in_scope && index($0, ENVIRON["anchor"]) {s=$0; sub(/[^ ].*$/, "", s); print s ENVIRON["hook"]; found=1}
        END {if (!found) exit 1}
    ' "$f" >"$lock/content"; then
        echo "注入失败(上游结构变化或无法写入)：$1" >&2
        failed=1; return 1
    fi
    if ! cat "$lock/content" >"$tmp" || ! sh -n "$tmp"; then
        echo "补丁语法检查失败：$1" >&2; failed=1; return 1
    fi
    if ! cmp -s "$tmp" "$f"; then
        mv -f "$tmp" "$f" || { failed=1; return 1; }
        echo "已恢复挂钩：$1"
    fi
}

inject libs/core_tools.sh 'setconfig custcorelink "$custcorelink"' \
    '[ -f "$CRASHDIR"/libs/core_upx.sh ] && . "$CRASHDIR"/libs/core_upx.sh && core_upx_fix #local-upx' '#local-upx'

recover='[ ! -f "$CRASHDIR"/local/apply.sh ] || sh "$CRASHDIR"/local/apply.sh >>"$CRASHDIR"/local/apply.log 2>&1 || echo "本地补丁恢复失败，请查看 local/apply.log" >&2 #local-upx'
inject menus/9_upgrade.sh 'init.sh >/dev/null' "$recover" '#local-upx'
task_found=0
for task in menus/task_cmd.sh task/task.sh; do
    if [ -f "$CRASHDIR/$task" ]; then
        task_found=1
        inject "$task" 'init.sh >/dev/null' "$recover" '#local-upx'
        inject "$task" '. "$CRASHDIR"/starts/core_config.sh get_core_config' \
            '. "$CRASHDIR"/starts/core_config.sh && get_core_config && "$CRASHDIR"/start.sh start #local-subconv-update' '#local-subconv-update' 1
        inject "$task" '. "$CRASHDIR"/libs/web_restore.sh && put_save' \
            '. "$CRASHDIR"/libs/subconv.sh && subconv_reload #local-subconv-reload' '#local-subconv-reload' 1
        # 修复旧版注入器已经损坏的执行位。
        chmod +x "$CRASHDIR/$task" || failed=1
    fi
done
[ "$task_found" = 1 ] || { echo '缺少任务入口' >&2; failed=1; }

inject starts/core_config.sh "Config=\$(grep -aE '^5'" \
    'if [ -f "$CRASHDIR"/libs/subconv.sh ]; then . "$CRASHDIR"/libs/subconv.sh && subconv_prepare || return 1; elif [ "$sub_only" = ON ]; then echo "仅本地组件缺失，已拒绝在线转换" >&2; return 1; fi #local-subconv-pre' '#local-subconv-pre'
inject starts/core_config.sh 'if [ "$?" != "0" ]; then' \
    '[ "$sub_only" != ON ] || { rm -f "$core_config_new"; Https=""; logger "仅本地转换失败，已阻止在线回退，现有配置保留" 31; return 1; } #local-subconv-fail' '#local-subconv-fail'
inject starts/core_config.sh 'echo -e "链接地址为：' \
    'if [ "$sub_only" = ON ]; then echo "仅本地转换请求：订阅参数已隐藏"; else echo -e "链接地址为：\033[4;32m$Https\033[0m"; fi #local-subconv-private' '#local-subconv-private' 1
inject starts/core_config.sh 'echo 可以手动复制该链接到浏览器打开并查看数据是否正常！' \
    '[ "$sub_only" = ON ] || echo 可以手动复制该链接到浏览器打开并查看数据是否正常！ #local-subconv-help' '#local-subconv-help' 1
inject starts/core_config.sh '已成功获取配置文件' \
    '[ "$(command -v subconv_after)" ] && subconv_after #local-subconv-end' '#local-subconv-end'
inject starts/bfstart.sh '. "$CRASHDIR"/libs/check_cmd.sh' \
    '[ ! -f "$CRASHDIR"/libs/subconv.sh ] || { . "$CRASHDIR"/libs/subconv.sh && subconv_before_core; } || exit 1 #local-subconv-before' '#local-subconv-before'
inject menus/6_core_config.sh '"e) $CORECFG_MENU_E"' \
    '"f) \033[33m本地转换配置文件\033[0m(subconverter)" "g) \033[36m本地转换设置\033[0m" \'
inject menus/6_core_config.sh 'read -r -p "$COMMON_INPUT_L> " num' \
    'if [ "$num" = f ] || [ "$num" = g ]; then . "$CRASHDIR"/libs/subconv.sh; if [ "$num" = f ]; then subconv_gen; else subconv_menu; fi; continue; fi #local-subconv-run' '#local-subconv-run'


# 本地维护中心：入口、实际版本、自愈意图与安全核心更新。
if [ -f "$CRASHDIR/local/manager.sh" ]; then
    chmod 755 "$CRASHDIR/local/manager.sh" || failed=1
    inject menus/8_tools.sh 'content_line "$TOOLS_MENU_TEST_ITEM"' \
        'content_line "a) 本地维护中心（状态/安全更新/自愈/空间/诊断）" #local-manager-menu' '#local-manager-menu'
    inject menus/8_tools.sh 'read -r -p "$COMMON_INPUT> " num' \
        'if [ "$num" = a ]; then sh "$CRASHDIR/local/manager.sh" menu; continue; fi #local-manager-run' '#local-manager-run' 0 tools
    inject menus/9_upgrade.sh '[ -z "$core_v" ] && core_v=$crashcore' \
        '[ ! -x "$CRASHDIR/local/manager.sh" ] || core_v=$(sh "$CRASHDIR/local/manager.sh" version) #local-manager-version' '#local-manager-version'
    inject menus/9_upgrade.sh 'core_v_new=$(eval echo' \
        'if [ -x "$CRASHDIR/local/manager.sh" ]; then lm_latest=$(sh "$CRASHDIR/local/manager.sh" latest-cached); [ -z "$lm_latest" ] || core_v_new="$lm_latest"; fi #local-manager-latest' '#local-manager-latest'
    inject start.sh '. "$CRASHDIR"/libs/logger.sh' \
        '[ ! -f "$CRASHDIR/local/manager.sh" ] || sh "$CRASHDIR/local/manager.sh" intent "$1" #local-manager-intent' '#local-manager-intent'
    inject starts/bfstart.sh '. "$CRASHDIR"/libs/check_cmd.sh' \
        '[ ! -f "$CRASHDIR/local/manager.sh" ] || sh "$CRASHDIR/local/manager.sh" boot-wait || exit 1 #local-manager-usb' '#local-manager-usb'
    inject starts/afstart.sh '. "$CRASHDIR"/libs/set_cron.sh' \
        '[ ! -f "$CRASHDIR/local/manager.sh" ] || sh "$CRASHDIR/local/manager.sh" register #local-manager-cron' '#local-manager-cron'
    inject libs/core_tools.sh 'core_webget(){' \
        'if [ "$crashcore" = meta ] && [ -z "$custcorelink" ] && [ -f "$CRASHDIR/local/manager.sh" ]; then sh "$CRASHDIR/local/manager.sh" update latest; return $?; fi #local-manager-safe-core' '#local-manager-safe-core'
    for task in menus/task_cmd.sh task/task.sh; do
        [ ! -f "$CRASHDIR/$task" ] || inject "$task" 'update_core(){' \
            '[ ! -f "$CRASHDIR/local/manager.sh" ] || { sh "$CRASHDIR/local/manager.sh" update latest; return $?; } #local-manager-safe-task' '#local-manager-safe-task'
    done
fi

# 删除旧的启动后异步拉起项，避免核心先加载规则、引擎后启动的竞争。
taskfile="$CRASHDIR/configs/task/afstart"
if [ -f "$taskfile" ]; then
    sed -i '/#local-subconv-boot/d; /本地转换引擎自启/d' "$taskfile" || failed=1
fi
for file in "$CRASHDIR"/tools/upx*; do
    [ ! -f "$file" ] || chmod +x "$file" || failed=1
done

# 不在 Windows/普通主机中创建系统文件；真机既有恢复项保持有效。
if [ -s /data/auto_start.sh ]; then
    if ! grep -q 'local/apply.sh' /data/auto_start.sh; then
        quoted=$(printf '%s' "$CRASHDIR/local/apply.sh" | sed "s/'/'\\\\''/g")
        printf "sh '%s' || echo 'ShellCrash本地补丁恢复失败' >&2 #ShellCrash-local\n" "$quoted" >>/data/auto_start.sh || failed=1
    fi
fi
[ "$failed" = 0 ] || exit 1

if [ "$1" = --repack ]; then
    . "$CRASHDIR"/libs/get_config.sh
    . "$CRASHDIR"/libs/set_config.sh
    . "$CRASHDIR"/libs/check_dir_avail.sh
    . "$CRASHDIR"/libs/logger.sh
    . "$CRASHDIR"/libs/core_upx.sh
    core_upx_fix
    exit $?
fi
exit 0
