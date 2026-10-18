# ShellCrash ARM64 本地整合部署包（2026-10-18）

用于已经安装 ShellCrash 的 Linux ARM64 路由器，包括当前小米路由器。不包含原版的全新安装引导；不会把路由器的 master 分支替换为仓库 dev 分支。

包含：Mihomo v1.19.32（官方 ARM64，经 UPX 5.2.1 -9 压缩）、SubConverter-Extended v1.10.1 及运行库、ARM64 UPX、19 个模板、83 份公开规则快照，以及 cn.mrs、中国 IPv4/IPv6、Country.mmdb、GeoSite.dat。附来源、SHA-256、定制源码及修改补丁。

请在 USB/外接盘解压，不能在只有几 MiB 空间的 /userdisk 上解压。需要可执行、可写且能保留 Linux 权限的文件系统，USB 至少空余 200 MiB。

```sh
cd /mnt/usb-faec181f
# 将部署包上传到此目录后：
tar -xzf ShellCrash-arm64-v1.19.32-local-20261018.tar.gz
cd shellcrash-local
sh deploy.sh --data /mnt/usb-faec181f --check
sh deploy.sh --data /mnt/usb-faec181f
```

其他安装位置用 `--crashdir /绝对路径/ShellCrash`；`--data` 指现有 USB 的挂载根目录，用于引擎、规则和维护备份，**不迁移 BINDIR/核心存储目录**。已有自定义引擎路径必须位于该 USB 下。默认同时处理核心；`--no-core` 只整合功能和资源。`--no-cron` 不登记维护计划任务（一般无需指定）。不支持从这个包给其他架构部署。

安装前核对包外 `.sha256`；安装器还会核验全部包内文件、核心固定 SHA-256、UPX 完整性、架构、挂载和空间。SHA-256 用于发现损坏，与安装包一同获得的清单不是独立的发布签名。

现有实际核心已为 v1.19.32 时，保持进程，不重复替换。其他版本必须已有健康运行的 Mihomo UPX 核心，且通过配置兼容、版本递增检查，才执行安全替换；失败恢复经过内部可信索引校验的旧核心。该事务不支持首次安装核心、从其他核心切换、从 raw/gz 格式直接迁移。对应情形可先 `--no-core` 整合，再通过原菜单完成格式迁移。禁止用本包降级更新后的核心。

功能部署和核心更新是两个事务：功能阶段失败恢复原脚本、配置、计划任务和引擎；功能成功而核心更新失败时，新功能保留，旧核心由核心事务恢复。备份在 USB 的 `sc-deploy-backup-*` 下，目录 700；其中有设备配置，不能公开分享。部署备份不参与维护中心的自动轮换，请验证后自行保留或清理。

已有订阅、节点、密码、监听设置保留；已有显式 ON/OFF 设置保留。新选项缺省启用本地转换、仅本地转换、自愈和备份维护。大规则文件放在 USB，引擎更新时保留 base/base/rules 与映射（引擎工作目录是其 base 目录）。规则快照固定于 2026-10-18，不会自动追踪上游规则变更；将来可重新构建资源或选择在线模板更新。19 个内置模板只读取快照；用户自行添加的新模板不在这 83 个规则来源内时，仍按原模板处理。仅本地模式指本机转换且失败不回退远程转换服务，订阅下载、核心更新等仍可能联网。

公开地理数据保存在 USB 的 `ShellCrash-public-geodata`，与私人备份分开。已有数据文件保留；缺失时仅为当前设置所需的 cn.mrs / 中国 IPv4/IPv6 / GeoIP / GeoSite 建立到 USB 快照的链接。USB 缺失会影响这些资源，启动等待和自愈因此要求 USB 正常挂载。

部署后退出菜单重新运行 `crash`：

- `6 → g`：本地转换设置；仅本地模式开关在该菜单。
- `8 → a`：安全向导、安全更新/回滚、运行状态、USB/自愈、备份轮换、脱敏诊断。
- `sh /userdisk/ShellCrash/local/manager.sh status`：查看实际核心版本和规则状态。
- `sh /userdisk/ShellCrash/local/manager.sh health v1.19.32 network`：验证规则、转换服务及代理联网。

安全向导不会自行设密码、更改监听或开启 TLS 限制，需要在菜单明确操作。自愈尊重手动停止、禁用自启，连续失败三次暂停；维护任务每两分钟执行，不自动升级核心。配置快照按类型保留三份，保护当前回滚快照；诊断只导出白名单汇总，不包含订阅配置和原始日志。详见包内 `overlay/local/MAINTENANCE.md`。

包内不含设备配置、订阅、节点、真实 providers 缓存、日志、SSH 凭据或备份可信索引。规则来源记录于 `sources.json`、`geodata-sources.json`；模板源文件另存于 `source/`。上游脚本更新后会自动尝试恢复挂钩；若上游结构改变导致恢复失败，请查看 `local/apply.log`，需要适配后重新部署。

模板格式修复：23 个 DustinWin 来源使用了 Clash YAML 类型前缀，但下载的 .list 实际为 Surge 格式。已根据实际内容移除不兼容前缀，避免生成无效的本地 URL 规则提供器。源文件不作篡改，原始类型与格式说明保存在 sources.json。
规则格式限制：83 份快照中，YouTube Music 来源只有两条 USER-AGENT 规则；Mihomo 规则集转换不支持这类 Surge 规则，因此该来源不会产生有效 Mihomo 规则。其余来源按相应规则格式映射。
