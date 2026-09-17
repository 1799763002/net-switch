# net-switch

`net-switch` 是 macOS 的网络客户端切换助手。它检查代理客户端、VPN 服务、系统代理和 `utun` 路由，帮助你在使用下一个客户端前，先把前一个客户端正常断开和退出。

[English README](README.md)

## 解决的问题

多种代理或 VPN 软件都可能修改系统代理、虚拟网卡或 VPN 服务。若直接退出或切换顺序不正确，后续软件可能无法联网、业务 VPN 无法连接，或本地代理端口仍被占用。

本工具遵循一个原则：**同一时间只让一种网络客户端接管网络**。它不会保存或上传订阅、节点、密码、VPN 账号、连接配置、服务器地址、DNS 配置或完整路由表。

## 支持的软件

- v2rayN
- ByWave
- Clash Verge
- PowerVPN
- Viscosity
- Hillstone Secure Connect
- Tailscale

默认配置中，PowerVPN 对应的 macOS VPN 服务名是 `小地球仪`。如果你的服务名称或应用标识不同，请先修改源码中的映射后再使用。

## 启动与命令

在项目目录中运行：

```bash
./net
```

首次运行会自动构建发布版。若希望在任意目录直接输入 `net`，可以把项目目录加入 `PATH`，或在已加入 `PATH` 的目录放置一个启动脚本。

常用命令：

```bash
net              # 打开中文菜单
net 看           # 查看一次当前状态
net 监看         # 每 5 秒刷新状态
net 清理         # 只检查可安全清理的代理残留
net 日志         # 查看最近事件
net clash日志    # 查看 Clash Verge 最近警告、超时与错误
net 日志目录     # 在 Finder 打开日志目录
net 诊断         # 生成脱敏诊断报告
net 模式         # 查看当前分流、兜底、直连或异常状态
net 分流         # 国内直连，海外经 Clash + Tailscale 私网 VPS
net 兜底         # 所有公网流量临时经 Tailscale Exit Node
net 直连         # 取消代理，保留 Tailscale 私网连接
net 切换 viscosity # 停止 Tailscale/Clash 后单独打开 Viscosity
net 切换 v2rayn    # 停止 Tailscale/Clash 后单独打开 v2rayN
net 切换 bywave    # 停止 Tailscale/Clash 后单独打开 ByWave
net 恢复         # 退出外部客户端并恢复 Tailscale + Clash 日常分流
net 网络诊断     # 比较默认路径和 Clash 7897 代理路径
```

交互确认统一输入 `y` 或 `yes` 继续，输入 `n`、`no` 或直接回车取消。命令行危险操作可使用 `--yes`，例如 `net stop bywave --yes`。

运行测试：

```bash
swift test
```

## 推荐切换顺序

从日常 Tailscale + Clash 分流切换到其他软件时，优先使用：

```bash
net 切换 viscosity
# 或 net 切换 v2rayn
# 或 net 切换 bywave
```

该命令会在一次 `y/yes` 确认后依次退出 Clash、取消 Exit Node、停止 Tailscale、清理受管系统代理，再只打开目标软件。目标软件不会被自动连接，请在其界面中手动选择连接。

使用结束后恢复日常网络：

```bash
net 恢复
```

它会先安全退出外部客户端，再启动 Tailscale 并恢复 Clash 分流。单独客户端正常运行时，`net` 显示“单独客户端”，不再误报为“冲突”；只有它与 Tailscale 或 Clash 同时接管网络时才显示“冲突”。

手工切换时遵循：

1. 运行 `net 看`，确认当前是谁在接管网络。
2. 回到正在使用的客户端，先点击“断开”。
3. 在 `net` 菜单中选择“安全退出软件”。
4. 所有客户端停止后，选择“检查代理残留”。
5. 仅在确认没有活动客户端、VPN 服务和 `utun` 路由时，选择“清理代理残留”。
6. 再打开下一个客户端并手动连接。

不要同时让多个代理或 VPN 接管网络，也不要强制结束客户端或手动删除 DNS、路由、厂商后台服务。

## 重要保护规则

- **v2rayN**：检测到 TUN 路由时显示“受保护”。工具不会自动退出 v2rayN 或清理网络，手动停止需要一次 `y/yes` 确认。
- **ByWave**：识别 `7893` 系统代理和本地 TUN 状态；确认退出后先通过本地 Mihomo API 停用 TUN，再正常退出应用，并保留其 root 后台辅助服务。辅助服务待命时显示为“应用已退出”，不会误报为客户端运行中。
- **Clash Verge**：退出时检查应用进程与 `7897` 系统代理是否都已释放。
- **PowerVPN**：当指定 macOS VPN 服务仍连接时，工具拒绝退出。
- **Viscosity**：先通过 AppleScript 断开连接，再退出应用；第一次使用可能要求 macOS 授予自动化权限。
- **Hillstone Secure Connect**：本工具仅依据本机生命周期日志判断连接状态。连接中或状态不明时会拒绝退出；其厂商后台服务不会被停止，也不会被当作残留。
- **Tailscale**：后端已经停止且没有可识别的 Tailscale 路由时，即使 macOS 网络扩展仍显示挂载，也视为已停止。
- **模式切换**：分流模式保持 Tailscale 私网在线但取消 Exit Node；兜底模式关闭 Clash 系统代理后启用 Exit Node；直连模式保留 Tailnet 私网但不代理公网。切换前会预检，失败自动恢复此前 Exit Node、Clash 和系统代理状态。
- **单独客户端切换**：`net 切换 <软件>` 会同时处理系统代理和 Tailscale 虚拟网卡路由；普通“清理系统代理”只处理 10808/7893/7897，不会取消 Exit Node。切换失败会尝试恢复操作前的 Tailscale、Clash 和系统代理状态。
- **Tailscale 关闭保护**：取消 Exit Node 和关闭 Tailscale 是两个独立动作；彻底关闭必须使用一次 `y/yes` 确认。
- **后台守护**：Tailscale 仅作为私网连接时不会阻止无主代理残留清理；模式切换期间通过事务锁暂停自动修复。
- 外部状态探测均有超时保护；即使 Tailscale 或其他客户端命令异常，`net` 菜单也不会永久卡住。
- 安装守护时会自动移除旧版 `com.chenlang.net-switch` 守护，避免重复进程和重复探测。
- 菜单中的“强制清理系统代理”允许在客户端仍运行时关闭 10808/7893/7897 对应的 HTTP、HTTPS 和 SOCKS 设置；执行前只需一次 `y/yes` 确认。
- v2rayN 不再使用特殊保护状态；正常退出失败时会先终止残留核心，再报告结果。

## 日志与隐私

日志保存在：

```text
~/Library/Logs/net-switch/
```

日志保留 30 天，记录命令调用、菜单选择、模式切换、操作编号、耗时、脱敏前后状态、拒绝原因、回滚结果和异常。主要事件文件为 `events-YYYY-MM-DD.log`；`launchd.log` 可能为空，这是正常情况。`net 诊断` 只摘录 Clash Verge 最近 24 小时的警告与错误并进行脱敏，更早历史会明确省略。

`net 诊断` 会在同一目录生成脱敏报告，仅包含客户端名称、概括性 VPN 状态、代理残留数量、端口是否监听、守护状态和已脱敏的近期异常。

提交 Issue 时，请附上脱敏诊断报告、macOS 版本、客户端版本和复现步骤。不要提交订阅链接、节点地址、密码、账号、VPN 配置或完整路由输出。

## 参与改进

公开仓库中不应提交 `.build/`、日志、诊断报告或任何本机配置；这些内容已经被 `.gitignore` 排除。提交代码前可运行：

```bash
swift test
```

## 许可证

[MIT](LICENSE)
