# F50 IPv6 RA 路由续期 · UFI-TOOLS 插件（联通适配 / 安全增强）

> 上游项目：[Xiaol1n173/f50-ipv6-ra-refresh](https://github.com/Xiaol1n173/f50-ipv6-ra-refresh)
> 本 Fork：[cmhr0086/f50-ipv6-ra-refresh](https://github.com/cmhr0086/f50-ipv6-ra-refresh)
>
> 原项目的原理、脚本框架、UFI-TOOLS 界面与 ARM64 静态 `rdisc6` 来自上游及其依赖项目；此 Fork 增加联通适配、安全刷新策略、调度器与测试。请保留原作者署名。


> **状态（2026-10-28）**：已在中兴 F50 + 中国联通 + UFI-TOOLS 上实测 **手动 RS 接收、IPv6 默认路由续期、公网 IPv6 连通、调度器启动及首次自动检查**；Ubuntu CI **184 PASS / 0 FAIL / 0 SKIP**。[查看 CI](https://github.com/cmhr0086/f50-ipv6-ra-refresh/actions/runs/40662866017)。**长期保活、剩余 6 小时自动触发、重启后自启与高级路由重建尚未实机验证**。

这个插件用于应对部分 F50 在 IPv6 RA 默认路由到期或丢失后，出站 IPv6 无法正常工作的情况。默认只检测路由有效期并使用 `rdisc6` 发送 **Router Solicitation（RS）**，让内核自行接受 RA 并维护默认路由；**安全模式不会执行路由删除或手动替换**。

## 快速开始（推荐先看）

1. 确认 F50 已 Root，且 **UFI-TOOLS 的高级功能**已开启。这与插件的危险**高级路由修复模式**不是同一个开关。
2. 从本仓库 `main` 分支下载 [`[插件]IPv6 RA路由修复.js`](./%5B%E6%8F%92%E4%BB%B6%5DIPv6%20RA%E8%B7%AF%E7%94%B1%E4%BF%AE%E5%A4%8D.js)，在 UFI-TOOLS 的插件管理中导入。
3. 打开 **IPv6 RA路由修复**面板，点击 **安装脚本**。首次安装默认 `MODE=safe`、检查间隔 **1 小时**、续期阈值 **6 小时**，不开启自动刷新或开机自启；已有配置更新时会保留原配置，请确认模式。
4. 点击 **导入现有rdisc6**，优先从 `/data/local/tmp/rdisc6` 读取；如果没有，再使用下载或上传。确认界面显示 `rdisc6：已安装`。
5. 保持插件的**高级修复模式关闭**，点击 **手动发送 RS**，查看 `RA：已收到`、`路由：已刷新` 和剩余有效期是否回到接近 **65535 秒（18.2 小时）**；再点击 **测试公网连通**。
6. 手动验证通过后点击 **开启自动刷新**。可继续使用每 **1 小时**检查，也可选 **15 分钟**，以便更快发现意外丢失的路由。**检查不等于每次发送 RS**：有效期充足时会跳过续期。
7. 确认多轮调度正常运行后，再按需打开 **开机自启**。仅有 IPv6 远程管理通道时尤其应避免危险高级修复模式。

**判断成功的依据**：RA 收到、内核路由恢复/续期、公网连通是三件独立的事情。默认 `MODE=safe` 只通过 RS 触发内核路由更新，不会为了让界面显示“成功”而删除有效路由。

---
## 1. 这个 Fork 与上游的区别

| 项目 | 上游 | 本 Fork |
| --- | --- | --- |
| 运营商 | 移动 / 电信 | 移动 / 电信 / **中国联通**（联通、CUCC、China Unicom、Unicom） |
| 默认策略 | 每次调度直接续期，失败后删路由重建 | **安全模式**：先判断剩余有效期，只发 RS，不删不改路由 |
| 接口/网关 | 有 `sipa_eth8` / `fe80::2` 兜底 | 动态检测 `sipa_ethN`；不写死接口、前缀、网关 |
| 刷新条件 | 无阈值，按调度直接刷新 | RA 剩余有效期低于阈值（默认 6 小时）才刷新 |
| 失败重试 | 每次调度都会重试 | 最小重试间隔（默认 300 秒），避免快速重试 |
| 高级算法 | 默认执行删路由/手工 replace | **高级模式**，明确标危险、默认关闭、需确认 |
| 结果表达 | 统一写“刷新成功” | 分开记录“收到 RA / 路由已刷新 / 公网连通” |
| rdisc6 | 下载 / 上传 | 下载 / 上传 / **从 `/data/local/tmp/rdisc6` 导入** |
| 首次安装 | — | 默认**不开启**开机自启，先手动测试 |
| 状态 | `last_strategy` | 新增 `last_result` 结构化状态（面板读取） |
| 测试 | 无 | 普通 Linux 可跑的模拟测试（mocks + 184 项断言） |

> 关于根因：上游 README 描述“F50 仅收到一次 RA，65535 秒后默认路由到期”。本 Fork **不把“RA 到期”当作已经 100% 证实的唯一根因**；目前能确认的是：设备上主动发送 RS 能引出真实 RA 并恢复默认路由。安全模式因此只做“主动 RS + 回读验证”，不靠猜测网关重建路由。

## 2. 已适配的设备与运营商

本 Fork 针对以下环境编写并做了模拟测试：

- 设备：中兴 F50，原厂 Android，已 Root，运行 UFI-TOOLS
- 运营商：中国联通，APN `3gnet`
- 蜂窝接口：`sipa_eth0`（**动态，可能是其他 `sipa_ethN`，不写死**）
- 蜂窝 IPv6 前缀：`2408:8471:160e:2e9::/64`（动态，**不写死**）
- 真实上游 RA 网关：`fe80::2`（动态，由实际 RA/路由获取）
- RA Router Lifetime：65535 秒
- 内核参数：`forwarding=1`、`sipa_eth0.accept_ra=2`、`accept_ra_defrtr=1`、`router_solicitations=-1`

已在用户设备上实测有效的手动修复命令：

```sh
/data/local/tmp/rdisc6 -1 -r 2 -w 3000 sipa_eth0
```

收到来自 `fe80::2`、Router Lifetime 65535 秒的 RA 后，内核恢复：

```text
default via fe80::2 dev sipa_eth0 proto ra metric 1024 expires 65534sec
```

随后 `curl -6` 可访问公网 IPv6。**本 Fork 修改版已于 2026-10-28 在实际 F50 的 UFI-TOOLS 面板上验证：**
- **手动发送 RS 成功**，日志中确认收到来自 `fe80::2` 的 RA；
- 路由剩余有效期由约 **53091 秒**恢复至约 **65534 秒**，策略 `nd_renew`，未删除现有默认路由；
- 面板公网 IPv6 连通性检测正常；
- 开启自动刷新后，调度器显示运行中；首次自动检查发现有效期充足，正确跳过 RS。
以上是一次设备上的**功能性实测**，并不证明长期自动运行、临界阈值触发或 Android 重启自启已通过验证。

> **APN 不是运营商**：`3gnet` 只是联通 APN。脚本的运营商判断只读 `gsm.sim.operator.alpha`，不会用 `3gnet` 判断运营商。

## 3. 安全模式的工作流程（默认）

每次调度（默认 1 小时）执行：

1. 读取 `gsm.sim.operator.alpha`，识别移动/电信/联通；为空或无法识别时输出诊断并**安全跳过**。
2. 扫描 `sipa_eth0~15`，选出 `state UP` 且带全局 IPv6 地址的活动蜂窝接口。
3. 若存在多个候选：优先选择“已经有 IPv6 默认路由”的那个；仍无法唯一确定就放弃本次，**不随意选接口**。
4. 读取该接口在所有路由表中的 IPv6 默认路由，解析网关、表名、`metric`、`hoplimit`、`expires`。
5. 判断：
   - 路由不存在 → 立即尝试用 RS 恢复；
   - 路由是静态（无 `expires`）→ 无需处理；
   - 剩余有效期 ≥ 阈值（默认 21600 秒 = 6 小时）→ **不做任何修改**；
   - 剩余有效期 < 阈值 → 发送 RS 续期。
6. 通过 `rdisc6` 发送 Router Solicitation（`-1 -r 2 -w 3000`）。
7. 重新读取真实内核路由表，最多等待 `SETTLE_TRIES` 秒：
   - 原来缺失：只要路由出现即成功；
   - 原来有效期偏低：新 `expires` 必须大于旧值才算成功。
8. 只有第 7 步验证通过才记录“路由已刷新”。收到 RA 但路由没出现，记录 **失败**，不会谎报成功。

安全模式**禁止**：

- 删除当前仍然有效的 IPv6 默认路由；
- 未验证真实网关就强制替换路由；
- 重启蜂窝网络、修改 APN、重启设备；
- 修改 IPv4 路由、防火墙、下游 LAN 配置。

返回值：`0`=成功或无需操作，`1`=出错，`2`=条件不满足而跳过。

## 4. 安全模式与高级模式的区别

| 能力 | 安全模式（默认） | 高级模式（默认关闭，危险） |
| --- | --- | --- |
| 发送 RS | ✅ | ✅ |
| 路由有效期充足时不动路由 | ✅ | ✅ |
| 删除 IPv6 默认路由 | ❌ | ✅（仅删除实际读到的那一条） |
| 手工 `ip route replace` | ❌ | ✅（网关必须来自实际路由/RA） |
| 缺少 rdisc6 时手工重建 | ❌（直接报错，不改路由） | ✅（仅当已有可验证网关/表名） |
| 未知运营商 | 默认跳过；可显式开兼容模式（仅 RS） | 同左 |
| 默认值 | `MODE=safe` | 需在面板中确认开启 |

高级模式保留了上游的 `nd_rebuild` / `ra_replace` / `ra_replace_min` 算法，但：

- 必须在面板打开“高级修复模式（危险）”并再次确认；
- 删除路由前会重新读取并核对网关/表名，路由变化就取消删除；
- 删除后 RS 失败会先尝试重建；重建失败会**恢复删除前的默认路由**，尽量缩短断网时间；
- 网关只来自当前实际路由（并核对接口/表名）；`rdisc6` 输出中的 `fe80::` RA 源地址只写日志用于诊断，**不会**用来猜路由。拿不到已验证网关时直接报错，不硬编码 `fe80::2`。

“删除当前路由（高级）”按钮也只在高级模式下可用，且需要连续点击 3 次确认。

## 5. UFI-TOOLS 安装方法

1. 在 UFI-TOOLS 中启用“高级功能”（Root）。
2. 安装插件脚本 `[插件]IPv6 RA路由修复.js`。
3. 打开 `IPv6 RA路由修复` 面板，点“安装脚本”。首次安装会在设备写入：

```text
/data/xl_ipv6_ra/
├── refresh_route.sh            # 核心安全刷新脚本（由插件生成）
├── refresh_route_watch.sh      # 调度器
├── refresh_route_watch.conf    # 调度间隔（秒）
├── refresh_route.conf          # 模式/阈值/兼容开关等
├── refresh_route_watch.pid     # 调度器 PID
├── rdisc6                      # 可选，aarch64 静态二进制
├── last_strategy               # 最近一次成功策略
├── last_result                 # 最近一次执行的结构化结果
└── refresh_route.log           # 日志（超过 64KB 自动轮转）
```

4. 首次安装**不会**写开机自启，默认安全模式、1 小时间隔、6 小时阈值。
5. 先做手动测试（第 8 节），确认无异常后再决定是否“开启自动刷新”和“开机自启”。

> 如果面板提示“未知运营商”，请先确认 SIM 已注册、`getprop gsm.sim.operator.alpha` 有值；确实需要时再打开“未知运营商兼容（仅 RS）”。

## 6. rdisc6 的下载、上传与导入

`rdisc6` 是可选组件，但没有它时安全模式只能报告“无法安全续期”，**不会**删除/替换路由。

三种安装方式：

1. **导入现有文件（推荐，避免重复下载）**
   面板点“导入现有rdisc6”，依次尝试：
   `/data/local/tmp/rdisc6` → `/data/xl_cron/bin/rdisc6` → `/sdcard/rdisc6`。
   文件需大于 10KB，且校验 ELF64 Little Endian / AArch64 头，再通过限时执行检查排除无法运行、超时或异常退出。若设备缺少必要的校验命令，验证会保守失败；失败不会覆盖原有 `rdisc6`。
2. **下载**
   填下载地址（默认上游仓库的 `rdisc6`），点“下载rdisc6”。下载先写 `.new` 临时文件，校验通过才替换。
3. **上传**
   点“上传rdisc6”从本地选择文件，同样先写临时文件、校验、再替换。

校验内容：文件大小 ≥ 10KB、ELF64 小端 AArch64 文件头，以及限时执行检测（拒绝超时、信号异常退出或无法执行）。导入失败不会覆盖现有二进制；检测依赖设备可用的 `dd`、`od` 和 `timeout` 等命令。

## 7. 启用、关闭自动刷新

- **开启自动刷新**：点“开启自动刷新”。调度器写入 PID，循环执行核心脚本。
- **调度间隔**：5 分钟 / 15 分钟 / 30 分钟 / 1 小时（默认）/ 2 小时 / 6 小时。修改后若调度器在运行会自动重启应用新间隔。正常 RA 生命周期约 18.2 小时、阈值为 6 小时时，**1 小时检查足够应对自然到期**；若更关心蜂窝网络变化造成的提前丢路由，可选 **15 分钟**。并非每次检测都发送 RS。
- **刷新阈值**：3 / 6（默认）/ 12 / 18 小时。修改后立即生效（核心脚本每次运行都读配置），无需重启调度器。
- **关闭自动刷新**：点“关闭自动刷新”。只停止调度器，不修改任何路由。
- **开机自启**：默认关闭。确认手动测试正常后再打开；它只会在 `/sdcard/ufi_tools_boot.sh` 追加一行拉起调度器。
- **卸载**：连续点击 3 次“卸载”，会停止调度器、移除开机自启行、删除 `/data/xl_ipv6_ra`（含日志与配置）。

关闭自动刷新后，不会留下循环任务；调度器自身也有单实例锁，重复启动只会保留一个。

## 8. 手动验证 RA 刷新

在 F50 的 Root Shell 中：

```sh
# 1. 看当前 IPv6 默认路由（可能没有）
ip -6 route show table all | grep '^default via fe80'

# 2. 主动发送 RS（直接使用你已实测可用的二进制）
/data/local/tmp/rdisc6 -1 -r 2 -w 3000 sipa_eth0

# 3. 立刻回读：应出现 default via fe80::... dev sipa_ethX ... expires 6553xsec
ip -6 route show table all | grep '^default via fe80'

# 4. 测本机公网 IPv6（前提是系统有 ping6；没有 ping6 时不能据此判定不通）
ping6 -c 1 -W 2 2400:3200::1

# 5. 可选：直接 curl
curl -6 -sS --max-time 10 https://ipv6.icanhazip.com
```

或者在面板中：

- **手动发送 RS**：即使默认路由仍健康，也会实际发送 RS；不删除、不替换路由，结果会区分“已收到 RA / 路由未出现”。
- **立即刷新**：执行完整安全流程（受阈值判断；手动执行会跳过最小重试间隔）。
- **测试公网连通**：单独执行带超时的 `ping6`；没有 `ping6` 时显示“无法测试”，不会误报“IPv6 不通”。

面板上的三个标签必须分开看：

- `RA：已收到` 只代表 `rdisc6` 收到了 RA；
- `路由：已刷新` 只代表回读内核路由表确认路由存在或有效期变长；
- `公网：正常` 只代表连通性测试成功。

三者不能互相替代。

## 9. 日志与状态

- 日志：`/data/xl_ipv6_ra/refresh_route.log`，每行带时间戳，超过 64KB 保留后半段。
- 面板日志框显示最近 60 行，可“刷新”“清空”。
- 最近一次执行结果：`/data/xl_ipv6_ra/last_result`，包含 `RESULT`、`RA_RECEIVED`、`ROUTE_REFRESHED`、`CONNECTIVITY`、`STRATEGY`、`MESSAGE` 等字段。
- 最近一次成功策略：`/data/xl_ipv6_ra/last_strategy`（第 1 行策略 key，第 2 行 Unix 时间戳）。

命令行查看：

```sh
tail -n 60 /data/xl_ipv6_ra/refresh_route.log
timeout 2s awk '{print}' /data/xl_ipv6_ra/last_result
sh /data/xl_ipv6_ra/refresh_route.sh --status
```

`--status` 是只读的：不加锁、不写日志、不改路由。

## 10. 卸载与恢复原状

面板卸载（连续点击 3 次）会：

1. 停止调度器并清理 PID/锁；
2. 从 `/sdcard/ufi_tools_boot.sh` 删除包含 `refresh_route_watch` 的行；
3. 删除 `/data/xl_ipv6_ra`（脚本、配置、日志、rdisc6）。

手动卸载等价命令：

```sh
# 停调度器（先看 pid，确认 cmdline 是 refresh_route_watch.sh 再 kill）
P=$(cat /data/xl_ipv6_ra/refresh_route_watch.pid 2>/dev/null)
[ -n "$P" ] && grep -q refresh_route_watch "/proc/$P/cmdline" 2>/dev/null && kill "$P"
pkill -f 'refresh_route_watch[.]sh' 2>/dev/null

# 移除开机自启行
sed -i '/refresh_route_watch/d' /sdcard/ufi_tools_boot.sh

# 删除插件目录（日志/配置会一起删除，需要保留请先备份）
rm -rf /data/xl_ipv6_ra
```

本插件不会修改 APN、IPv4 路由、防火墙或下游 LAN 配置，所以卸载后这些无需恢复。若你曾在高级模式手动删除默认路由，卸载后请重启蜂窝数据或等待网关 RA，让内核重新安装默认路由。

## 11. 稳定性与安全设计

- **单实例**：核心脚本用 `mkdir` 原子锁 + `/proc/<pid>/cmdline` 存活校验；调度器另有 `.watcher.lock`。陈旧锁自动清理，PID 复用不会永久卡死。
- **异常退出清理**：退出陷阱按锁的 PID 归属清理；收到 SIGTERM 时调度器退出并清理自己的 PID/锁。SIGKILL 无法执行陷阱，需依赖下次启动清理残留锁。
- **失败冷却**：刷新失败后默认 300 秒内不再自动重试；手动“立即刷新”可绕过。
- **所有网络操作有超时**：`rdisc6` 外层 `timeout`、`ping6` 5 秒、调度器单次核心脚本 180 秒。
- **日志受限**：超过 64KB 自动保留后半段，避免塞满 `/data`。
- **输入校验**：接口名、路由表名、网关（必须在 `fe80::/10`）、阈值/间隔等都有白名单或范围校验。
- **不依赖 OpenWrt 专有命令**：只用 Android `sh`、`ip`、`getprop`、`ping6`、`rdisc6`、`awk/sed/grep/tr` 等。
- **远程管理风险**：高级模式删除/替换路由会导致 IPv6 短暂中断；如果设备只能通过 IPv6 远程管理，断网可能让你失联。默认安全模式不会删除有效路由，但仍建议先本地/旁路验证。

## 12. 测试

仓库自带可在普通 Linux（或 Windows Git Bash）运行的模拟测试，不连接真实 F50：

```sh
sh tests/run_all.sh
```

Windows Git Bash 若 `node` 不在 PATH：

```sh
RRA_NODE=/path/to/node.exe RRA_SH=/path/to/sh.exe sh tests/run_all.sh
```

测试内容：

- `node --check`：插件 JS 语法；
- `sh -n`：两个 Shell 脚本语法；
- `tools/sync-embedded.mjs --check`：插件内嵌脚本与仓库 Shell 源文件完全一致（防止只改未被调用的文件）；
- 模拟 `ip` / `getprop` / `rdisc6` / `ping6`，覆盖：
  - 联通、移动、电信及大小写/空格/逗号；
  - 剩余 12 小时自动检查不刷新、手动 RS 仍执行；剩余 2 小时自动发送 RS；
  - 路由消失后 RS 恢复；
  - `rdisc6` 返回 0 但路由未出现 → 失败；
  - 没装 `rdisc6` → 明确报错且不删/不改路由；
  - `sipa_eth0` → `sipa_eth3` 和 IPv6 前缀变化；
  - 运营商属性为空/未知 → 安全跳过；兼容模式仅 RS；
  - 多实例并发 → 第二个跳过；
  - 失败冷却、阈值可调、静态路由；
  - SIGTERM 停止调度器并清理 PID/锁文件；
  - 路由意外恢复但未确认收到 RA 时，不伪报 RA 成功；
  - 删除路由仅高级模式可用。

当前模拟测试结果：**184 项断言通过，0 失败，0 跳过**（GitHub Actions Ubuntu，2026-10-28），包含手动 RS 在路由健康时仍执行、RA 与路由状态分离、SIGTERM 清理锁等回归测试。最新完整通过记录：[GitHub Actions](https://github.com/cmhr0086/f50-ipv6-ra-refresh/actions/runs/40662866017)。

**测试边界**：模拟测试不能替代 Android 内核与 UFI-TOOLS 的实机验证；本 Fork 已完成前述 F50 手动续期、连通性、首次调度实测，尚未观察长期自动续期、重启自启以及危险高级修复模式。

## 13. 已知限制与风险

1. **实机验证范围有限**：手动 RS 和首次调度在一台联通 F50 上成功；长期保活、阈值触发、开机自启及其他运营商/固件的实际兼容性仍待验证。
2. 安全模式只能“发 RS 让内核自己修复”。如果内核收到 RA 仍不安装默认路由（例如厂商网络栈异常），安全模式会报失败而不会强改路由；此时需要人工排查或显式使用高级模式。
3. `rdisc6` 输出在不同版本/平台上可能不打印 RA 源地址；即使打印了，高级模式也只把它写进日志，不用于猜路由。路由完全丢失且拿不到已验证网关/表名时，会拒绝重建，这是有意的安全取舍。
4. 没有 `rdisc6` 时，安全模式不会做任何路由修改；请先导入/下载/上传。
5. 多候选接口只有在“恰好一个候选已有默认路由”时才会自动选择；否则跳过并提示。
6. `gsm.sim.operator.alpha` 在开机早期可能为空，调度器会跳过本次，等 SIM 注册完成后的下一次调度。
7. 只扫描 `sipa_eth0~15`；如果厂商改了接口前缀，需要改脚本中的 `IF_PREFIX`（仓库源文件 `refresh_route2.sh`，再同步嵌入插件）。
8. 高级模式会短暂中断 IPv6；远程管理设备时尤其危险。默认关闭是刻意的。
9. 调度器被 `kill -9` 时 trap 无法执行，可能留下 PID/锁文件；下次启动会自动清理陈旧锁，面板“关闭自动刷新”也会主动清理。
10. 开机自启依赖 UFI-TOOLS 的 `/sdcard/ufi_tools_boot.sh`；若该文件被系统清理，自启会失效。

## 14. 许可证与署名

- **上游仓库当前没有提供 `LICENSE` 文件**（GitHub API `license: null`）。因此本 Fork **不新增任何声称覆盖原作者代码的许可证**，也不把原代码重新授权。
- 原项目作者：**Xiaol1n173**，上游：<https://github.com/Xiaol1n173/f50-ipv6-ra-refresh>。原脚本、界面与 `rdisc6` 二进制的版权归其各自作者所有。
- 本 Fork 的修改由 cmhr0086 维护；**保留署名不等于自动获得复制、修改或再分发授权**。进一步公开再分发、打包或商用前，应向原作者确认适当授权，并遵守 `rdisc6` 等依赖的许可证。
- `rdisc6` 来自 ndisc6 项目（remlab.net，1.0.8），二进制仍受其上游许可证约束；源码获取与静态编译方法见下一节。

## 15. rdisc6 编译（aarch64 musl 静态，来自上游）

```sh
# 1. 工具链
wget https://musl.cc/aarch64-linux-musl-cross.tgz
tar xf aarch64-linux-musl-cross.tgz
export PATH=$PWD/aarch64-linux-musl-cross/bin:$PATH

# 2. 源码（官方上游 remlab.net，版本 1.0.8）
wget https://www.remlab.net/files/ndisc6/ndisc6-1.0.8.tar.bz2
tar xf ndisc6-1.0.8.tar.bz2 && cd ndisc6-1.0.8

# 3. 静态编译（只需要 rdisc6 这一个目标）
./configure --host=aarch64-linux-musl CC=aarch64-linux-musl-gcc LDFLAGS="-static"
make

# 4. 确认
file rdisc6   # 应显示: ELF 64-bit ... ARM aarch64, statically linked
```

## 16. 仓库文件

| 文件 | 说明 |
| --- | --- |
| `[插件]IPv6 RA路由修复.js` | UFI-TOOLS 插件；内嵌核心脚本与调度器 |
| `refresh_route2.sh` | 核心脚本的仓库源文件（与插件内嵌内容一致） |
| `refresh_route_watch.sh` | 调度器源文件（与插件内嵌内容一致） |
| `tools/sync-embedded.mjs` | 把两个 Shell 源文件同步进插件 JS；`--check` 只校验 |
| `tests/run_all.sh` | 静态检查 + 模拟测试入口 |
| `tests/run_tests.sh` | 184 项模拟断言 |
| `tests/check_plugin.mjs` | JS/Shell 语法、同步、安全默认值、UI/文档检查 |
| `tests/mocks/` | 模拟 `ip` / `getprop` / `rdisc6` / `ping6` |
| `rdisc6` | 上游提供的 aarch64 静态二进制（未改动） |

修改 Shell 源文件后，务必执行：

```sh
node tools/sync-embedded.mjs
```

否则插件里运行的仍是旧脚本；`tests/check_plugin.mjs` 会因同步不一致而失败。
