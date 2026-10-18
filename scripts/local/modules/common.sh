# ShellCrash local manager common routines. Never enable shell tracing here.
sc_now() { date +%s; }
sc_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$SC_STATE/events.log"
    if [ "$(wc -c <"$SC_STATE/events.log")" -gt 131072 ]; then
        tail -n 200 "$SC_STATE/events.log" >"$SC_STATE/events.tmp" && mv "$SC_STATE/events.tmp" "$SC_STATE/events.log"
    fi
}
sc_sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else return 1; fi
}
sc_free() { df -Pk "$1" 2>/dev/null | awk 'END {print $4}'; }
sc_root_owned() { [ ! -L "$1" ] && [ "$(ls -nd "$1" 2>/dev/null | awk '{print $3}')" = 0 ]; }
sc_private_dir() { ls -ld "$1" | awk 'substr($1,5,6)!="------" {exit 1}'; }
sc_https_fetch() {
    local url="$1" output="$2" limit="${3:-30}"
    case "$url" in https://*) ;; *) return 1 ;; esac
    curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time "$limit" "$url" -o "$output" 2>/dev/null && return 0
    # Same official HTTPS URL and certificate policy through the existing local proxy.
    if [ -n "$authentication" ]; then
        curl -fLsS --proto '=https' --proto-redir '=https' --proxy "http://127.0.0.1:${mix_port:-7890}" --proxy-user "$authentication" --noproxy '' --connect-timeout 5 --max-time "$limit" "$url" -o "$output" 2>/dev/null
    else
        curl -fLsS --proto '=https' --proto-redir '=https' --proxy "http://127.0.0.1:${mix_port:-7890}" --noproxy '' --connect-timeout 5 --max-time "$limit" "$url" -o "$output" 2>/dev/null
    fi
}
sc_quote() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }
sc_cfg() (
    SC_LOCK=''
    sc_lock config || return 1
    trap sc_unlock EXIT
    case "$1" in ''|*[!a-zA-Z_0-9]*) return 1 ;; esac
    local cfg="$CRASHDIR/configs/ShellCrash.cfg" temp key="$1" value="$2"
    temp=$(mktemp "$CRASHDIR/local/.local-cfg.XXXXXX") || return 1
    cp -p "$cfg" "$temp" || { rm -f "$temp"; return 1; }
    sc_key="$key" awk 'index($0, ENVIRON["sc_key"] "=") != 1 {print}' "$cfg" >"$temp.content" || return 1
    { cat "$temp.content"; printf '%s=' "$key"; sc_quote "$value"; printf '\n'; } >"$temp"
    rm -f "$temp.content"
    sh -n "$temp" && mv -f "$temp" "$cfg" && return 0
    rm -f "$temp"; return 1
)
sc_mount_ready() {
    [ -d "$SC_DISK" ] || return 1
    awk -v path="$SC_DISK" '$2 == path && $4 ~ /(^|,)rw(,|$)/ {found=1} END {exit !found}' "${SC_MOUNTS:-/proc/mounts}"
}
sc_storage() {
    sc_mount_ready || { sc_log 'USB unavailable; no data directory created'; return 1; }
    local dir
    for dir in "$SC_DATA" "$SC_DATA/backups" "$SC_DATA/diagnostics" "$SC_DATA/downloads"; do
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            sc_root_owned "$dir" || { sc_log 'Untrusted storage directory owner/symlink; refused'; return 1; }
        else
            (umask 077; mkdir "$dir") || return 1
        fi
        chmod 700 "$dir" || return 1
        sc_private_dir "$dir" || { sc_log 'Storage filesystem cannot enforce private directory permissions'; return 1; }
    done
}
sc_pid_token() { [ -r "/proc/$1/stat" ] && awk '{print $22}' "/proc/$1/stat"; }
sc_lock_alive() {
    local pid token
    [ -f "$1/owner" ] || return 1
    read -r pid token <"$1/owner"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$token" ] && [ "$token" = "$(sc_pid_token "$pid")" ]
}
sc_lock() {
    SC_LOCK="$SC_STATE/$1.lock"
    if ! mkdir "$SC_LOCK" 2>/dev/null; then
        sc_lock_alive "$SC_LOCK" && return 1
        # A newly-created lock may not yet have its owner file; never steal it.
        if [ ! -f "$SC_LOCK/owner" ]; then
            local observed=0 now
            now=$(sc_now)
            if [ -f "$SC_LOCK.observed" ]; then observed=$(cat "$SC_LOCK.observed"); else printf '%s\n' "$now" >"$SC_LOCK.observed"; return 1; fi
            [ "$((now-observed))" -ge 10 ] || return 1
            rmdir "$SC_LOCK" 2>/dev/null || return 1
            rm -f "$SC_LOCK.observed"
            mkdir "$SC_LOCK" 2>/dev/null || return 1
            printf '%s %s\n' "$$" "$(sc_pid_token "$$")" >"$SC_LOCK/owner"
            return 0
        fi
        rm -f "$SC_LOCK/owner"
        rmdir "$SC_LOCK" 2>/dev/null || return 1
        mkdir "$SC_LOCK" 2>/dev/null || return 1
    fi
    printf '%s %s\n' "$$" "$(sc_pid_token "$$")" >"$SC_LOCK/owner"
}
sc_unlock() { [ -z "$SC_LOCK" ] || { rm -f "$SC_LOCK/owner"; rmdir "$SC_LOCK" 2>/dev/null; }; SC_LOCK=''; }
sc_api() {
    curl -fsS --noproxy 127.0.0.1 --connect-timeout 2 --max-time 8 \
        -H "Authorization: Bearer ${secret:-}" "http://127.0.0.1:${db_port:-9999}/$1" 2>/dev/null
}
sc_version() {
    local bin="${1:-$BINDIR/CrashCore.upx}"
    [ -x "$bin" ] || bin="$TMPDIR/CrashCore"
    "$bin" -v 2>/dev/null | head -1 | sed 's/ linux.*//;s/.* //'
}
sc_version_newer() {
    awk -v new="$1" -v old="$2" 'BEGIN {
        sub(/^v/, "",new); sub(/^v/, "",old)
        if(new !~ /^[0-9]+\.[0-9]+\.[0-9]+$/ || old !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 2
        split(new,a,"."); split(old,b,".")
        for(i=1;i<=3;i++) {if(a[i]+0>b[i]+0) exit 0; if(a[i]+0<b[i]+0) exit 1} exit 1
    }'
}
sc_proxy_check() {
    local code
    if [ -n "$authentication" ]; then
        code=$(curl -s --proxy "http://127.0.0.1:${mix_port:-7890}" --proxy-user "$authentication" --noproxy '' --connect-timeout 4 --max-time 12 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204)
    else
        code=$(curl -s --proxy "http://127.0.0.1:${mix_port:-7890}" --noproxy '' --connect-timeout 4 --max-time 12 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204)
    fi
    [ "$code" = 204 ]
}
sc_rules() {
    local json
    json=$(sc_api providers/rules) || return 1
    printf '%s' "$json" | grep -oE '"ruleCount"[[:space:]]*:[[:space:]]*[0-9]+' |
        awk -F: '{total++; if($2+0>0) nonempty++; sum+=$2} END {printf "%d %d %d\n",total,nonempty,sum}'
}
sc_health() {
    local version counts total nonempty sum expected
    version=$(sc_api version) || return 1
    [ -z "$1" ] || printf '%s' "$version" | grep -qF "\"$1\"" || return 1
    pidof CrashCore >/dev/null 2>&1 || return 1
    if subconv_needed; then
        subconv_ready >/dev/null 2>&1 || return 1
        counts=$(sc_rules) || return 1
        read -r total nonempty sum <<EOF
$counts
EOF
        expected=$(grep -cE '127\.0\.0\.1:[0-9]+/getruleset' "$CRASHDIR/yamls/config.yaml")
        [ "$nonempty" -ge "${expected:-0}" ] || return 1
    fi
    [ "$2" != network ] || sc_proxy_check
}
sc_backup_config() {
    sc_storage || return 1
    local folder
    folder=$(mktemp -d "$SC_DATA/backups/config-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
    chmod 700 "$folder" || return 1
    printf '%s\n' SC_LOCAL_BACKUP_V1 >"$folder/.sc-owned"
    (umask 077; tar -czf "$folder/configs.tgz" -C "$CRASHDIR" configs local) || return 1
    printf '%s\n' "$folder"
}
