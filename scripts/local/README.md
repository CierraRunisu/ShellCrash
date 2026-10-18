# 本地定制说明

上游 ShellCrash 同步（菜单"更新脚本"、定时任务 `update_scripts`、重装）会覆盖 `libs/`、`menus/`、`starts/`、`task/` 目录。
本目录、`libs/core_upx.sh`、`libs/subconv.sh`、`tools/upx-*`、`subconverter/` 都不在上游压缩包内，不会被覆盖；
上游文件里只注入了一行式挂钩，由 `local/apply.sh` 按文本锚点重新写入，可反复执行且不会冻结上游改动。

## 一、内置 upx 压缩内核
- `tools/upx-linux-arm64`：内置 upx 5.2.1（静态 aarch64）。换架构时按 `tools/upx-linux-<cpucore>` 放入即可。
- `libs/core_upx.sh`：`core_upx_fix` 完成 压缩→跑一次核心校验版本号→替换→重建软链接→写入 `zip_type=upx`。
- 挂钩位置：`libs/core_tools.sh` 的 `core_check` 末尾，所以菜单更新内核、定时 `update_core`、`/tmp` 上传内核、自定义链接导入都会被压缩。
- 统一存为 `$BINDIR/CrashCore.upx`，`$TMPDIR/CrashCore` 是指向它的软链接。
- 关闭压缩：在 `configs/ShellCrash.cfg` 加 `core_upx=OFF`。
- 注意：upx 是运行时自解压，内核常驻内存比裸文件方式略高；`-9` 压 30MB 内核在路由器上约需数分钟。

## 二、内置 subconverter 本地转换
- 引擎：SubConverter-Extended v1.10.1，约43MB，自带 glibc 与 libmihomo（官方 tindy2013/subconverter 不支持 VLESS，故改用该分支）。
- 引擎目录解析顺序：`sub_dir` → `$BINDIR/subconverter`（小闪存/USB模式下即外接硬盘）→ `$CRASHDIR/subconverter`；
  启动前实测该目录能否执行程序，noexec/只读时给出挂载提示并回退在线转换。
- 包内自带的 `subconverter-update`、`update.sh` 是上游自更新器，已删除；升级改用菜单里的"下载/更新引擎"。
- 模板：`$CRASHDIR/subconverter/config/` 内置规则列表(5xx)全部 19 个 INI 模板，默认使用第 1 个（Acl4SSR全能优化版）。
- 挂钩位置：
  - `starts/core_config.sh`：组装链接前调用 `subconv_prepare` 切到 `http://127.0.0.1:25500`，并把 `config=` 指向本机模板；转换成功后调用 `subconv_after`。
  - `menus/6_core_config.sh`：提供者菜单新增 `f) 本地转换配置文件` 与 `g) 本地转换设置`。
  - `configs/task/afstart`：开机随服务拉起引擎（该文件是用户任务文件，不受上游同步影响）。
- 引擎只监听 127.0.0.1，模板通过它自带的静态目录以 `http://127.0.0.1:25500/xxx.ini` 提供（该分支禁止 `config=` 读本地路径）。
- 转换结果：订阅链接生成 `proxy-providers`（由内核自行拉取，支持 vless/reality/hy2 等新协议），
  `vless://`、`trojan://`、`ss://` 等分享链接直接内联成 `proxies`，分组与规则取自所选 INI 模板。
- 配置里的 `rule-providers` 指向本机引擎（`/getruleset?...`），因此转换后建议保持常驻；
  低内存设备可在【本地转换设置】里把"转换后常驻"关掉（`sub_keep=OFF`），此时内核会改用 `providers/` 下的缓存规则文件。
- 失败自动回退：引擎启动失败或转换重试时，会退回上游的在线转换服务器逻辑，不会卡死。
- 相关配置项（`configs/ShellCrash.cfg`）：`sub_local=ON/OFF`、`sub_keep=ON/OFF`、`sub_port=25500`、`sub_dir=引擎目录`、`rule_link=1..19`。

## 手动操作
```sh
sh "$CRASHDIR"/local/apply.sh           # 上游同步后恢复全部挂钩
sh "$CRASHDIR"/local/apply.sh --repack  # 顺带把当前未压缩内核转成 CrashCore.upx
```

## 仅本地模式（2026-10-18 新增）

在 configs/ShellCrash.cfg 设置 sub_only=ON，同时启用 sub_local=ON。菜单入口：crash → 6 → g → 8。该模式下本地转换失败、组件或模板缺失时停止并保留旧配置，不在线回退；终端隐藏订阅参数。订阅源与远程规则仍正常联网获取。关闭 sub_only 后可恢复原在线回退兼容行为。设备已启用，旧 tar.gz 尚未重新打包。
