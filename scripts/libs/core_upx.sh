# 本地定制功能：内置upx压缩，内核每次更新后自动压缩落盘。
# 上游同步不会覆盖本文件；挂钩注入与恢复方式见 local/apply.sh

upx_install() { #tools下没有对应架构的upx时尝试在线下载
    case "$cpucore" in
    arm64) a=arm64 ;;
    amd64) a=amd64 ;;
    386) a=i386 ;;
    armv5 | armv7) a=arm ;;
    mipsle-softfloat) a=mipsel ;;
    mips-softfloat) a=mips ;;
    *) return 1 ;;
    esac
    . "$CRASHDIR"/libs/web_get.sh
    webget "$TMPDIR"/upx_api "https://api.github.com/repos/upx/upx/releases/latest" echooff || {
        rm -f "$TMPDIR"/upx_api
        return 1
    }
    link=$(grep -oE 'https://[^"]*'"$a"'_linux\.tar\.xz' "$TMPDIR"/upx_api | head -n 1)
    rm -f "$TMPDIR"/upx_api
    [ -z "$link" ] && return 1
    logger "正在下载upx压缩工具..." 36
    webget "$TMPDIR"/upx.tar.xz "$link" || {
        rm -f "$TMPDIR"/upx.tar.xz
        return 1
    }
    rm -rf "$TMPDIR"/upx_tmp
    mkdir -p "$TMPDIR"/upx_tmp
    tar -xf "$TMPDIR"/upx.tar.xz -C "$TMPDIR"/upx_tmp 2>/dev/null ||
        xz -dc "$TMPDIR"/upx.tar.xz 2>/dev/null | tar -xf - -C "$TMPDIR"/upx_tmp 2>/dev/null
    src=$(find "$TMPDIR"/upx_tmp -name upx -type f 2>/dev/null | head -n 1)
    rm -f "$TMPDIR"/upx.tar.xz
    if [ -z "$src" ]; then
        rm -rf "$TMPDIR"/upx_tmp
        logger "设备无法解压xz安装包，请手动放置 tools/upx-linux-$cpucore" 33
        return 1
    fi
    mkdir -p "$CRASHDIR"/tools
    install_tmp="$CRASHDIR/tools/.upx-$cpucore.$$"
    if cp -f "$src" "$install_tmp" && chmod +x "$install_tmp" &&
        "$install_tmp" -V >/dev/null 2>&1 &&
        mv -f "$install_tmp" "$CRASHDIR/tools/upx-linux-$cpucore"; then
        rm -rf "$TMPDIR"/upx_tmp
        return 0
    fi
    rm -f "$install_tmp"
    rm -rf "$TMPDIR"/upx_tmp
    return 1
}

upx_find_tool() { #输出可用的upx工具路径，找不到返回1
    [ -z "$cpucore" ] && {
        . "$CRASHDIR"/libs/check_cpucore.sh && check_cpucore
    }
    for tool in "$CRASHDIR"/tools/upx-linux-"$cpucore" "$CRASHDIR"/tools/upx-"$cpucore" "$CRASHDIR"/tools/upx $(command -v upx 2>/dev/null); do
        [ -f "$tool" ] || continue
        [ -x "$tool" ] || chmod +x "$tool" 2>/dev/null
        "$tool" -V >/dev/null 2>&1 && {
            echo "$tool"
            return 0
        }
    done
    upx_install >/dev/null 2>&1 && {
        tool="$CRASHDIR"/tools/upx-linux-"$cpucore"
        "$tool" -V >/dev/null 2>&1 && {
            echo "$tool"
            return 0
        }
    }
    return 1
}

core_upx_version() { #$1:核心文件路径，输出版本号，用于压缩后校验
    if echo "$crashcore" | grep -q 'singbox'; then
        "$1" version 2>/dev/null | grep version | awk '{print $3}'
    else
        "$1" -v 2>/dev/null | head -n 1 | sed 's/ linux.*//;s/.* //'
    fi
}

core_upx_packed() { #$1:文件，判断是否已被upx压缩
    [ -f "$1" ] && grep -q 'UPX!' "$1" 2>/dev/null
}

core_upx_fix() { #把刚落盘的未压缩核心转成 $BINDIR/CrashCore.upx；configs 内 core_upx=OFF 可关闭
    local link packed src tool tmp v next_link free
    [ "$core_upx" = 'OFF' ] && return 0
    . "$CRASHDIR"/libs/check_dir_avail.sh
    link="$TMPDIR/CrashCore" #logger会重置TMPDIR，先固定内核链接路径
    packed="$BINDIR/CrashCore.upx"
    src=''
    [ -s "$BINDIR/CrashCore.raw" ] && ! core_upx_packed "$BINDIR/CrashCore.raw" && src="$BINDIR/CrashCore.raw"
    [ -z "$src" ] && [ -f "$link" ] && [ ! -L "$link" ] && ! core_upx_packed "$link" && src="$link"
    if [ -n "$src" ]; then #存在未压缩核心，压缩到临时文件并校验版本
        tool=$(upx_find_tool) || {
            logger "未找到内置upx压缩工具，核心保持未压缩存储" 33
            return 0
        }
        free=$(dir_avail "$BINDIR")
        [ -z "$free" ] || [ "$free" -lt 12288 ] && {
            logger "存储空间不足，已跳过upx压缩" 33
            return 0
        }
        logger "正在使用内置upx压缩【$crashcore】核心，请耐心等待..." 33
        tmp="$BINDIR/.core.upx.tmp"
        rm -f "$tmp"
        if ! "$tool" -9 -q -o "$tmp" "$src"; then
            rm -f "$tmp"
            logger "upx压缩失败，核心保持未压缩存储" 31
            return 0
        fi
        v=$(core_upx_version "$tmp")
        if [ -z "$v" ] || { [ -n "$core_v" ] && [ "$v" != "$core_v" ]; }; then
            rm -f "$tmp"
            logger "upx压缩后的核心校验失败，已回退未压缩存储" 31
            return 0
        fi
        if ! chmod +x "$tmp" || ! mv -f "$tmp" "$packed"; then
            rm -f "$tmp"
            logger "压缩核心替换失败，已保留原核心" 31
            return 0
        fi
    fi
    [ -s "$packed" ] || return 0 #无压缩核心可用时保留上游的存储方式
    # 内核文件统一以链接方式指向ROM中的压缩核心，避免占用/tmp内存
    next_link="$link.upx.$$"
    if ! ln -s "$packed" "$next_link" || ! mv -f "$next_link" "$link"; then
        rm -f "$next_link"
        logger "核心链接替换失败，已保留原核心文件" 31
        return 0
    fi
    setconfig zip_type upx || return 1
    zip_type=upx
    # 链接、配置与目标文件均已就绪后才能删除旧存储。
    [ "$src" = "$link" ] || [ -z "$src" ] || rm -f "$src"
    rm -f "$BINDIR/CrashCore.raw" "$BINDIR/CrashCore.gz" "$BINDIR/CrashCore.tar.gz"
    logger "upx核心就绪，大小：$(( $(wc -c <"$packed") / 1024 ))KB" 32
    return 0
}
