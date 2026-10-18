#!/bin/bash
set -e
REPO=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
export LC_ALL=C
REPO=$REPO/scripts
BASE=$(pwd)/work/local-only-tests-$$
mkdir -p "$BASE"
for scenario in success engine_failure fetch_failure disabled remote_https missing_template missing_library stale_retry; do
  (
    CRASHDIR="$BASE/$scenario"; BINDIR="$CRASHDIR"; TMPDIR="$CRASHDIR/tmp"
    mkdir -p "$CRASHDIR"/{libs,starts,configs,yamls,subconverter/config,tmp}
    cp "$REPO/starts/core_config.sh" "$CRASHDIR/starts/"
    cp "$REPO/libs/subconv.sh" "$CRASHDIR/libs/"
    cp "$REPO/libs/check_target.sh" "$CRASHDIR/libs/"
    cp "$REPO/libs/set_config.sh" "$CRASHDIR/libs/"
    touch "$CRASHDIR/configs/ShellCrash.cfg" "$CRASHDIR/libs/urlencode.sh"
    printf '401 test https://converter.example.invalid ua\n501 test https://template.example.invalid/Test.ini\n' >"$CRASHDIR/configs/servers_chs.list"
    printf '[custom]\n' >"$CRASHDIR/subconverter/config/Test.ini"
    printf 'old config sentinel\n' >"$CRASHDIR/yamls/config.yaml"
    cp "$CRASHDIR/yamls/config.yaml" "$CRASHDIR/original.yaml"
    cat >"$CRASHDIR/libs/logger.sh" <<'EOF'
__IS_LIB_LOGGER=1
logger() { printf '%s\n' "$1" >>"$CRASHDIR/log"; }
EOF
    printf 'load_lang() { i18n=chs; }\n' >"$CRASHDIR/libs/i18n.sh"
    printf 'compare() { return 1; }\n' >"$CRASHDIR/libs/compare.sh"
    printf 'dir_avail() { echo 999999; }\n' >"$CRASHDIR/libs/check_dir_avail.sh"
    printf 'check_config() { return 0; }\n' >"$CRASHDIR/starts/clash_config_check.sh"
    cat >>"$CRASHDIR/libs/subconv.sh" <<'EOF'
subconv_start() { return "$START_RC"; }
EOF
    cat >"$CRASHDIR/libs/web_get_bin.sh" <<'EOF'
get_bin() { echo SERVER_LIST_FETCH >>"$CRASHDIR/trace"; return 1; }
webget() {
    case "$2" in
    http://127.0.0.1:25500/sub\?*) echo LOCAL >>"$CRASHDIR/trace" ;;
    *) echo REMOTE >>"$CRASHDIR/trace" ;;
    esac
    [ "$FETCH_RC" = 0 ] || return 1
    printf 'proxies:\n  - {name: test, type: ss, server: example.invalid, port: 1, cipher: aes-128-gcm, password: test}\n' >"$1"
}
EOF
    sub_only=ON; sub_local=ON; sub_keep=ON; crashcore=meta; core_v=v1.19.32
    Url=https://subscription.example.invalid/PRIVATE_TOKEN; Https=''; retry=0
    START_RC=0; FETCH_RC=0
    ckcmd() { return 1; }
    case "$scenario" in
    engine_failure) START_RC=1 ;;
    fetch_failure) FETCH_RC=1 ;;
    disabled) sub_local=OFF ;;
    remote_https) Https=https://converter.example.invalid/sub?url=PRIVATE_TOKEN ;;
    missing_template) rm "$CRASHDIR/subconverter/config/Test.ini" ;;
    missing_library) rm "$CRASHDIR/libs/subconv.sh" ;;
    stale_retry) retry=2 ;;
    esac
    . "$CRASHDIR/starts/core_config.sh"
    rc=0
    get_core_config >"$CRASHDIR/stdout" 2>&1 || rc=$?
    if [ "$scenario" = success ] || [ "$scenario" = stale_retry ]; then
      test "$rc" = 0
      grep -qx LOCAL "$CRASHDIR/trace"
      ! cmp -s "$CRASHDIR/original.yaml" "$CRASHDIR/yamls/config.yaml"
    else
      test "$rc" != 0
      cmp -s "$CRASHDIR/original.yaml" "$CRASHDIR/yamls/config.yaml"
    fi
    if [ -f "$CRASHDIR/trace" ]; then
      ! grep -Eq 'REMOTE|SERVER_LIST_FETCH' "$CRASHDIR/trace"
      test "$(wc -l <"$CRASHDIR/trace")" -le 1
    fi
    ! grep -q PRIVATE_TOKEN "$CRASHDIR/stdout"
    echo "PASS $scenario: no online fallback, existing config protected, output redacted"
  )
done
(
 CRASHDIR="$BASE/success"; BINDIR="$CRASHDIR"; TMPDIR="$CRASHDIR/tmp"
 . "$CRASHDIR/libs/logger.sh"
 . "$CRASHDIR/libs/set_config.sh"
 . "$CRASHDIR/libs/subconv.sh"
 sub_only=OFF; sub_local=ON; retry=0; START_RC=1; Https=''
 Server=https://converter.example.invalid
 subconv_prepare
 test "$Server" = https://converter.example.invalid
 echo 'PASS compatibility: online fallback remains available only when strict mode is off'
)
echo 'LOCAL_ONLY_ALL_TESTS_PASSED'
