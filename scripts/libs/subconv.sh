# 本地定制功能：内置 SubConverter-Extended 本地订阅转换
# 引擎可放在内置存储或外接硬盘/USB：解析顺序 sub_dir → $BINDIR/subconverter → $CRASHDIR/subconverter
# 规则模板在 $CRASHDIR/subconverter/config(小文件，随脚本走)，默认使用规则列表里的第一个模板。
# 上游同步不会覆盖本文件；挂钩注入方式见 local/apply.sh

#菜单入口不会预加载这些库，先做防御式加载(重复source无副作用)
[ -n "$__IS_LIB_LOGGER" ] || . "$CRASHDIR"/libs/logger.sh
command -v setconfig >/dev/null 2>&1 || . "$CRASHDIR"/libs/set_config.sh
command -v dir_avail >/dev/null 2>&1 || . "$CRASHDIR"/libs/check_dir_avail.sh

subconv_ver='v1.10.1' #内置引擎版本，供“更新引擎”比对

subconv_dir() { #引擎目录：优先自定义，其次数据目录(USB/外接盘)，最后脚本目录
    for d in "$sub_dir" "$BINDIR/subconverter" "$CRASHDIR/subconverter"; do
        [ -n "$d" ] && [ -f "$d/start.sh" ] && {
            echo "$d"
            return 0
        }
    done
    echo "${sub_dir:-$BINDIR/subconverter}"
}

subconv_tpl_dir() { #模板目录：本地模板缺失时跟随引擎目录
    [ -d "$CRASHDIR"/subconverter/config ] && {
        echo "$CRASHDIR"/subconverter/config
        return 0
    }
    echo "$(subconv_dir)/config"
}

subconv_exec_ok() { #$1:目录，检测该目录能否执行(外接盘常见noexec、只读或vfat无执行位)
    t="$1/.sc_exec_test.$$"
    printf '#!/bin/sh\nexit 0\n' >"$t" 2>/dev/null || {
        rm -f "$t"
        return 1
    }
    chmod +x "$t" 2>/dev/null
    "$t" >/dev/null 2>&1
    r=$?
    rm -f "$t"
    [ "$r" = 0 ]
}

subconv_ready() { #本地转换服务是否已就绪
    local port=${sub_port:-25500}
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --noproxy 127.0.0.1 --connect-timeout 2 --max-time 3 -o /dev/null "http://127.0.0.1:$port/version" && return 0
    elif command -v wget >/dev/null 2>&1; then
        wget -q -Y off -t 1 -T 2 -O /dev/null "http://127.0.0.1:$port/version" && return 0
    fi
    return 1
}

subconv_pref() { #原子生成配置，规则资源前缀必须与监听端口一致
    local dir root pref tmp port
    dir=$(subconv_dir)
    root=$(subconv_tpl_dir)
    port=${sub_port:-25500}
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || return 1
    [ -f "$dir/base/pref.example.ini" ] || return 1
    pref="$dir/base/pref.ini"
    tmp="$pref.$$"
    sc_root="$root" sc_port="$port" awk '
        /^listen=/ {print "listen=127.0.0.1"; next}
        /^port=/ {print "port=" ENVIRON["sc_port"]; next}
        /^serve_file_root=/ {print "serve_file_root=" ENVIRON["sc_root"]; next}
        /^managed_config_prefix=/ {print "managed_config_prefix=http://127.0.0.1:" ENVIRON["sc_port"]; next}
        /^skip_failed_links=/ {print "skip_failed_links=true"; next}
        {print}
    ' "$dir/base/pref.example.ini" >"$tmp" && mv -f "$tmp" "$pref" && return 0
    rm -f "$tmp"
    return 1
}

subconv_normalize_template() { # 优先使用部署包中经过校验的公开规则快照。
    local tmp="$1.normalize.$$" map="$(subconv_dir)/base/rule-map.tsv"
    sed 's#rules/ACL4SSR/#https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/#g' "$1" >"$tmp" || return 1
    if [ -s "$map" ]; then
        awk -F '\t' '
            NR==FNR {resources[$1]=$2; next}
            /^ruleset=/ {
                first=index($0,",")
                if(first) {
                    tail=substr($0,first+1); end=index(tail,",")
                    resource=end ? substr(tail,1,end-1) : tail
                    if(resource in resources) {
                        print substr($0,1,first) resources[resource] (end ? substr(tail,end) : "")
                        next
                    }
                }
            }
            {print}
        ' "$map" "$tmp" >"$tmp.local" && mv -f "$tmp.local" "$tmp" || { rm -f "$tmp" "$tmp.local"; return 1; }
    fi
    mv -f "$tmp" "$1" && return 0
    rm -f "$tmp"
    return 1
}

subconv_direct_rules() { #本机规则下载必须绕过核心自身的分流，防止递归代理
    local file="$1" tmp
    [ -s "$file" ] || return 0
    grep -qE 'https?://127\.0\.0\.1:[0-9]+/getruleset' "$file" || return 0
    tmp="$file.direct.$$"
    cp -p "$file" "$tmp" || return 1
    if ! awk '
        function flush(   n,i,line,space) {
            n=split(block,lines,"\n")
            for(i=1;i<n;i++) {
                line=lines[i]
                if(localurl && line ~ /^[[:space:]]+proxy:/) continue
                if(localurl && line ~ /^[[:space:]]+url:/) {
                    space=line; sub(/[^[:space:]].*$/, "", space)
                    print space "proxy: DIRECT"
                }
                print line
            }
            block=""; localurl=0
        }
        /^rule-providers:/ {section=1; print; next}
        section && /^[^[:space:]#]/ {flush(); section=0; indent=0}
        section {
            if($0 ~ /^[[:space:]]+[^[:space:]#][^:]*:/) {
                space=$0; sub(/[^[:space:]].*$/, "", space)
                if(!indent) indent=length(space)
                if(length(space)==indent) flush()
            }
            block=block $0 "\n"
            if($0 ~ /https?:\/\/127\.0\.0\.1:[0-9]+\/getruleset/) localurl=1
            next
        }
        {print}
        END {flush()}
    ' "$file" >"$tmp.content" || ! cat "$tmp.content" >"$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp" "$tmp.content"
        return 1
    fi
    rm -f "$tmp.content"
}

subconv_needed() { #已保存/正在运行的配置仍引用本机引擎时，不允许省内存停服
    grep -qE 'https?://127\.0\.0\.1:[0-9]+/getruleset' \
        "$CRASHDIR/yamls/config.yaml" "$CRASHDIR/jsons/config.json" \
        "$TMPDIR/config.yaml" "$TMPDIR/jsons/config.json" 2>/dev/null
}

subconv_reload() { #Mihomo 新版拒绝从 HOME/SAFE_PATHS 以外的临时目录加载
    local reload_file reload_tmp reload_path body
    reload_file="$BINDIR/.ShellCrash-reload.${format:-yaml}"
    reload_tmp="$reload_file.$$"
    (umask 077; cat "$TMPDIR/config.${format:-yaml}" >"$reload_tmp") || return 1
    mv -f "$reload_tmp" "$reload_file" || return 1
    reload_path=$(printf '%s' "$reload_file" | sed 's/\\/\\\\/g; s/"/\\"/g')
    body="{\"path\":\"$reload_path\"}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --noproxy 127.0.0.1 --connect-timeout 3 --max-time 40 \
            -X PUT -H "Authorization: Bearer $secret" -H 'Content-Type: application/json' \
            -d "$body" "http://127.0.0.1:${db_port:-9999}/configs" >/dev/null
    elif wget --help 2>&1 | grep -q -- '--method'; then
        wget -q -Y off --timeout=40 --method=PUT --header="Authorization: Bearer $secret" \
            --header='Content-Type: application/json' --body-data="$body" \
            -O /dev/null "http://127.0.0.1:${db_port:-9999}/configs"
    else
        logger "热更新需要 curl 或支持 PUT 的 wget" 31
        return 1
    fi
}

subconv_before_core() { #必须在核心初始化规则前启动，不能只在 afstart 里后台启动
    subconv_direct_rules "$CRASHDIR/yamls/config.yaml" || return 1
    subconv_needed || return 0
    subconv_start && return 0
    logger "当前配置依赖本地规则服务，但引擎未就绪，已停止本次内核启动" 31
    return 1
}

subconv_start() { #拉起本地转换服务，已就绪则直接返回
    local dir i
    dir=$(subconv_dir)
    [ -f "$dir/start.sh" ] || {
        logger "未找到本地转换引擎($dir)，可在【本地转换设置】里下载" 33
        return 1
    }
    subconv_ready && return 0
    subconv_exec_ok "$dir" || {
        logger "引擎目录禁止执行程序，请检查外接硬盘是否以noexec挂载：$dir" 31
        return 1
    }
    chmod +x "$dir/start.sh" "$dir/subconverter" 2>/dev/null
    #自带glibc的加载器必须有执行位，否则start.sh会报 glibc loader not found
    find "$dir/lib" "$dir/usr/lib" -name 'ld-*.so*' -exec chmod +x {} \; 2>/dev/null
    subconv_pref || return 1
    mkdir -p "$dir/logs" "$(subconv_tpl_dir)" 2>/dev/null
    [ -f "$dir/logs/run.log" ] && [ "$(wc -l <"$dir/logs/run.log")" -gt 500 ] && : >"$dir/logs/run.log" #防止外接盘日志无限增长
    if command -v nohup >/dev/null 2>&1; then
        (cd "$dir" && SUBCONVERTER_SKIP_AUTO_UPDATE=1 PREF_PATH=base/pref.ini nohup ./start.sh >>logs/run.log 2>&1 & echo $! >"$dir/logs/engine.pid")
    else #部分固件的busybox不带nohup
        (cd "$dir" && SUBCONVERTER_SKIP_AUTO_UPDATE=1 PREF_PATH=base/pref.ini ./start.sh >>logs/run.log 2>&1 & echo $! >"$dir/logs/engine.pid")
    fi
    i=0
    while [ $i -lt 30 ]; do
        subconv_ready && return 0
        i=$((i + 1))
        sleep 1
    done
    logger "本地转换引擎启动超时，可查看 $dir/logs/run.log 排查" 31
    return 1
}

subconv_pid_matches() { #不能直接信任陈旧 pidfile，也不匹配其他实例
    local p="$1" dir="$2"
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$p/cmdline" ] || return 1
    tr '\0' '\n' <"/proc/$p/cmdline" | grep -qxF "$dir/subconverter"
}

subconv_stop() {
    local dir p n candidates
    if [ "$1" != force ] && subconv_needed; then
        logger "当前规则配置依赖本地引擎，不能停止；请先切换配置" 33
        return 1
    fi
    dir=$(subconv_dir)
    if [ -f "$dir/logs/engine.pid" ]; then
        p=$(cat "$dir/logs/engine.pid")
        subconv_pid_matches "$p" "$dir" && candidates="$p"
    fi
    for p in $(pidof ld-linux-aarch64.so.1 ld-linux-x86-64.so.2 ld-linux-armhf.so.3 subconverter 2>/dev/null); do
        subconv_pid_matches "$p" "$dir" && candidates="$candidates $p"
    done
    for p in $candidates; do
        subconv_pid_matches "$p" "$dir" && kill "$p" 2>/dev/null
    done
    for p in $candidates; do
        n=0
        while subconv_pid_matches "$p" "$dir"; do
            [ "$n" -lt 5 ] || return 1
            sleep 1
            n=$((n + 1))
        done
    done
    rm -f "$dir/logs/engine.pid"
    return 0
}

subconv_after() {
    subconv_direct_rules "$CRASHDIR/yamls/config.yaml" || return 1
    if [ "$sub_keep" = OFF ]; then
        if subconv_needed; then
            logger "配置含本机rule-providers，保留引擎运行以保证规则可用" 33
        else
            subconv_stop
        fi
    fi
    return 0
}

subconv_boot() {
    [ "$sub_local" = OFF ] && ! subconv_needed && return 0
    subconv_start
}

subconv_tpl() { #输出当前模板地址：本地已有则走本机服务，否则回退远程地址
    [ -z "$i18n" ] && i18n=chs
    [ -z "$rule_link" ] && rule_link=1
    url=$(grep -aE '^5' "$CRASHDIR"/configs/servers_"$i18n".list | sed -n "${rule_link}p" | awk '{print $3}')
    [ -z "$url" ] && return 1
    name=$(echo "$url" | sed 's#.*/##; s/[?#].*//')
    if [ -f "$(subconv_tpl_dir)/$name" ]; then
        echo "http://127.0.0.1:${sub_port:-25500}/$name"
    else
        [ "$sub_only" = ON ] && return 1
        echo "$url"
    fi
}

subconv_prepare() { #仅本地时拒绝所有远程配置请求，错误必须传回调用方
    if [ "$sub_only" = ON ]; then
        if [ "$sub_local" = OFF ]; then
            logger "仅本地模式已启用，但本地转换关闭；已拒绝在线转换" 31
            return 1
        fi
        if [ -n "$Https" ]; then
            logger "仅本地模式不接受在线转换/直链配置请求，请从提供者列表本地生成" 31
            return 1
        fi
        if ! subconv_start; then
            logger "本地转换引擎不可用；仅本地模式已阻止在线回退，现有配置保留" 31
            return 1
        fi
    else
        [ "$sub_local" = OFF ] && return 0
        [ -n "$retry" ] && [ "$retry" -ge 1 ] && return 0
        subconv_start || return 0
    fi
    Config=$(subconv_tpl) || {
        logger "未找到可用本地模板；已停止转换，现有配置保留" 31
        return 1
    }
    Server="http://127.0.0.1:${sub_port:-25500}"
    export no_proxy=127.0.0.1,localhost
    export NO_PROXY=127.0.0.1,localhost
    logger "使用内置subconverter本地转换【$(basename "$Config")】" 36
    return 0
}

subconv_gen() { #把提供者列表(订阅链接/节点分享链接)本地转换成配置文件
    [ -f "$(subconv_dir)/start.sh" ] || {
        logger "未找到本地转换引擎，请先在【本地转换设置】里下载引擎" 31
        return 1
    }
    providers_link=$(grep -v '\./providers/' "$CRASHDIR"/configs/providers.cfg 2>/dev/null | awk '{print $2}' | tr '\n' '|')
    uri_link=$(grep -v '^#' "$CRASHDIR"/configs/providers_uri.cfg 2>/dev/null | awk '{ print ($1=="vmess" ? $2 : $2 "#" $1) }' | tr '\n' '|')
    Url=$(echo "$providers_link|$uri_link" | sed 's/||*/|/g; s/^|//; s/|$//')
    [ -z "$Url" ] && {
        logger "请先添加订阅链接或节点分享链接" 33
        return 1
    }
    Https=''
    setconfig Url "'$Url'"
    setconfig Https
    sub_local=ON
    retry=0
    . "$CRASHDIR"/starts/core_config.sh && get_core_config || return 1
    subconv_after
    comp_box "\033[32m本地转换完成，配置文件已更新\033[0m" \
        "$core_config"
    btm_box "1) 重启内核生效" \
        "0) 稍后"
    read -r -p "$COMMON_INPUT> " res
    [ "$res" = 1 ] && "$CRASHDIR"/start.sh restart
    return 0
}

subconv_update() { #下载规则列表内的全部模板到本地
    . "$CRASHDIR"/libs/web_get.sh
    dir=$(subconv_tpl_dir)
    mkdir -p "$dir"
    grep -aE '^5' "$CRASHDIR"/configs/servers_"$i18n".list |
        while read -r id name url note; do
            [ -z "$url" ] && continue
            file="$dir/$(echo "$url" | sed 's#.*/##; s/[?#].*//')"
            if webget "$file.tmp" "$url" echooff rediron skipceroff && [ -s "$file.tmp" ] && head -1 "$file.tmp" | grep -q '^\[custom\]'; then
                subconv_normalize_template "$file.tmp" && mv -f "$file.tmp" "$file" || return 1
                logger "已更新模板 $id $name" 32
            else
                rm -f "$file.tmp"
                logger "模板 $id $name 下载失败，保留原文件" 33
            fi
        done
    return 0
}

# 独立函数供在线更新调用：在同一文件系统准备、切换、启动验证、失败回滚。
subconv_install_package() (
    pkg="$1"
    version="$2"
    dir=$(subconv_dir)
    dir=${dir%/}
    case "$dir" in /*) ;; *) return 1 ;; esac
    [ -n "$dir" ] && [ "$dir" != / ] || return 1
    [ -s "$pkg/subconverter" ] && [ -f "$pkg/start.sh" ] &&
        [ -f "$pkg/base/pref.example.ini" ] || return 1
    stage=$(mktemp -d "$dir.sc-stage.XXXXXX") || return 1
    backup="$dir.sc-backup-$(date +%Y%m%d-%H%M%S)-${stage##*.}"
    [ ! -e "$backup" ] || { rm -rf "$stage"; return 1; }
    if ! cp -a "$pkg/." "$stage/"; then
        rm -rf "$stage"
        return 1
    fi
    if [ -d "$dir/config" ]; then
        cp -a "$dir/config" "$stage/" || { rm -rf "$stage"; return 1; }
    fi
    # 本地规则属于部署资源，在线更新引擎时一并保留。
    if [ -d "$dir/base/base/rules" ]; then
        cp -a "$dir/base/base/rules" "$stage/base/base/" || { rm -rf "$stage"; return 1; }
    fi
    if [ -f "$dir/base/rule-map.tsv" ]; then
        cp -p "$dir/base/rule-map.tsv" "$stage/base/" || { rm -rf "$stage"; return 1; }
    fi
    rm -f "$stage/subconverter-update" "$stage/update.sh" "$stage/UPDATE-README.txt" "$stage/base/pref.ini"
    chmod +x "$stage/subconverter" "$stage/start.sh" || { rm -rf "$stage"; return 1; }
    find "$stage/lib" "$stage/usr/lib" -name 'ld-*.so*' -exec chmod +x {} \; 2>/dev/null
    if ! sh -n "$stage/start.sh" || ! subconv_exec_ok "$stage"; then
        rm -rf "$stage"
        return 1
    fi
    printf '%s\n' "$version" >"$stage/.sc-version" || return 1
    subconv_stop force || { rm -rf "$stage"; return 1; }
    had_old=0
    if [ -e "$dir" ]; then
        mv "$dir" "$backup" || { rm -rf "$stage"; subconv_start; return 1; }
        had_old=1
    fi
    if ! mv "$stage" "$dir"; then
        [ "$had_old" = 0 ] || mv "$backup" "$dir"
        subconv_start
        return 1
    fi
    if subconv_start; then
        logger "引擎安装验证通过：$version，旧版备份：$backup" 32
        return 0
    fi
    subconv_stop force || return 1
    mv "$dir" "$stage" || return 1
    if [ "$had_old" = 1 ]; then
        mv "$backup" "$dir" || return 1
        subconv_start || return 1
    fi
    logger "新引擎启动失败，已回滚；失败版本保留在 $stage" 31
    return 1
)

subconv_engine_update() {
    local arch new_ver installed_ver link dir free src pkg result #下载或更新引擎本体到目标目录，保留模板与已生成配置
    case "$cpucore" in
    arm64) arch=arm64 ;;
    amd64) arch=amd64 ;;
    armv7) arch=armv7 ;;
    *)
        logger "暂不支持自动下载引擎的架构：$cpucore" 33
        return 1
        ;;
    esac
    . "$CRASHDIR"/libs/web_get.sh
    . "$CRASHDIR"/libs/check_dir_avail.sh
    webget "$TMPDIR"/sce_api "https://api.github.com/repos/Aethersailor/SubConverter-Extended/releases/latest" echooff || {
        rm -f "$TMPDIR"/sce_api
        logger "获取引擎版本信息失败" 31
        return 1
    }
    new_ver=$(grep -oE '"tag_name": *"[^"]+"' "$TMPDIR"/sce_api | head -n 1 | sed 's#.*"tag_name": *##; s#"##g')
    link=$(grep -oE 'https://[^"]*linux-'"$arch"'\.tar\.gz' "$TMPDIR"/sce_api | head -n 1)
    rm -f "$TMPDIR"/sce_api
    [ -z "$link" ] && {
        logger "未找到 $arch 架构的引擎安装包" 31
        return 1
    }
    dir=$(subconv_dir)
    installed_ver=$(cat "$dir/.sc-version" 2>/dev/null)
    [ "$new_ver" = "$installed_ver" ] && [ -f "$dir/start.sh" ] && {
        logger "引擎已是最新版本 $subconv_ver" 32
        return 0
    }
    free=$(dir_avail "$(dirname "$dir")")
    [ -n "$free" ] && [ "$free" -lt 61440 ] && {
        logger "目标目录剩余空间不足60MB：$dir" 31
        return 1
    }
    logger "正在下载引擎 $new_ver 到 $dir ..." 36
    webget "$TMPDIR"/sce.tar.gz "$link" || {
        rm -f "$TMPDIR"/sce.tar.gz
        logger "引擎下载失败" 31
        return 1
    }
    rm -rf "$TMPDIR"/sce_new
    mkdir -p "$TMPDIR"/sce_new
    tar -zxf "$TMPDIR"/sce.tar.gz -C "$TMPDIR"/sce_new || {
        rm -rf "$TMPDIR"/sce.tar.gz "$TMPDIR"/sce_new
        logger "引擎安装包解压失败" 31
        return 1
    }
    src=$(find "$TMPDIR"/sce_new -name subconverter -type f 2>/dev/null | head -n 1)
    [ -z "$src" ] && {
        rm -rf "$TMPDIR"/sce.tar.gz "$TMPDIR"/sce_new
        logger "安装包内未找到引擎文件" 31
        return 1
    }
    pkg=$(dirname "$src")
    subconv_install_package "$pkg" "$new_ver"
    result=$?
    rm -rf "$TMPDIR"/sce.tar.gz "$TMPDIR"/sce_new
    [ "$result" = 0 ] || logger "引擎更新失败，旧版保留或已恢复" 31
    return "$result"
}

subconv_pick() { #选择规则模板，独立实现，不依赖在线转换菜单
    [ -z "$i18n" ] && i18n=chs
    [ -z "$rule_link" ] && rule_link=1
    list=$(grep -aE '^5' "$CRASHDIR"/configs/servers_"$i18n".list | awk '{print $2}')
    [ -z "$list" ] && {
        logger "未找到规则模板列表，请先更新安装源" 31
        return 1
    }
    comp_box "当前模板：\033[33m$rule_link) $(echo "$list" | sed -n "${rule_link}p")\033[0m"
    list_box "$list"
    btm_box "" "0) 返回"
    read -r -p "$COMMON_INPUT> " num
    [ -z "$num" ] && return 0
    [ "$num" = 0 ] && return 0
    total=$(echo "$list" | grep -c .)
    if [ "$num" -gt 0 ] 2>/dev/null && [ "$num" -le "$total" ] 2>/dev/null; then
        rule_link=$num
        setconfig rule_link "$rule_link"
        logger "已切换规则模板：$num) $(echo "$list" | sed -n "${num}p")" 32
    else
        logger "无效编号" 31
    fi
    return 0
}

subconv_menu() { #本地转换设置菜单
    while true; do
        [ -z "$sub_local" ] && sub_local=ON
        [ -z "$sub_keep" ] && sub_keep=ON
        [ -z "$sub_only" ] && sub_only=OFF
        [ -z "$rule_link" ] && rule_link=1
        subconv_ready && status="\033[32m运行中\033[0m" || status="\033[31m未运行\033[0m"
        dir=$(subconv_dir)
        [ -f "$dir/start.sh" ] && e_ver="$subconv_ver" || e_ver="未安装"
        tpl=$(subconv_tpl)
        [ "$sub_only" = ON ] && privacy="仅本地，失败即停止" || privacy="允许在线回退"
        comp_box "模式：$privacy" \
            "本地转换：\033[32m$sub_local\033[0m	服务：$status(\033[36m${sub_port:-25500}\033[0m)	常驻：\033[33m$sub_keep\033[0m" \
            "引擎：\033[36m$e_ver\033[0m 位于 $dir" \
            "模板：\033[33m$rule_link) $(basename "$tpl" .ini)\033[0m 位于 $(subconv_tpl_dir)"
        btm_box "1) 开启/关闭本地转换" \
            "2) 切换规则模板" \
            "3) 更新全部本地模板" \
            "4) 下载/更新引擎(约50MB)" \
            "5) 启动/停止本地服务" \
            "6) 转换后是否常驻(本机规则依赖时自动保留)" \
            "7) 查看服务日志" \
            "8) 开启/关闭仅本地模式(不向公共转换服务发送订阅)" \
            "" \
            "0) 返回"
        read -r -p "$COMMON_INPUT> " num
        case "$num" in
        "" | 0)
            break
            ;;
        1)
            if [ "$sub_only" = ON ]; then
                logger "仅本地模式中不能关闭本地转换，请先通过8关闭仅本地模式" 33
                continue
            fi
            [ "$sub_local" = 'OFF' ] && sub_local=ON || sub_local=OFF
            setconfig sub_local "$sub_local"
            ;;
        2)
            subconv_pick
            ;;
        3)
            subconv_update
            ;;
        4)
            subconv_engine_update
            ;;
        5)
            if subconv_ready; then
                subconv_stop && logger "本地转换服务已停止" 33
            else
                subconv_start && logger "本地转换服务已启动" 32
            fi
            sleep 1
            ;;
        6)
            [ "$sub_keep" = 'OFF' ] && sub_keep=ON || sub_keep=OFF
            setconfig sub_keep "$sub_keep"
            ;;
        7)
            [ -f "$(subconv_dir)/logs/run.log" ] && tail -n 30 "$(subconv_dir)/logs/run.log" && sleep 3
            ;;
        8)
            if [ "$sub_only" = ON ]; then
                sub_only=OFF
            else
                sub_local=ON
                setconfig sub_local ON || continue
                sub_only=ON
            fi
            setconfig sub_only "$sub_only"
            ;;
        *)
            errornum
            ;;
        esac
    done
}
