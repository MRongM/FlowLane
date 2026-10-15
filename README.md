# App Proxy

macOS 按应用配置网络代理的桌面工具。

用户可以选择应用，为它指定代理连接；未匹配的应用默认直连。目标是提供类似 Proxifier 的核心使用体验。

## 当前状态

项目已初始化，尚未实现界面或网络接管功能。

## 已确认的需求

- 面向 macOS。
- 可以从已安装的应用中选择需要代理的应用。
- 可以管理代理配置，并为不同应用指定不同代理。
- 可以启用、暂停代理规则，并查看连接状态。
- 支持多个邮箱客户端及其他普通网络应用。
- 开发者当前没有 Apple Developer 账号。

## 技术方向

优先评估 SwiftUI 界面与 sing-box 等开源网络内核的组合，通过 TUN 和进程匹配实现分流。

首版优先考虑已有 SOCKS5、HTTP CONNECT 代理的接入。应用负责管理代理与规则，需要使用用户已有的代理服务。

TUN 方案需要管理员权限。流量进入内核后，由规则决定走指定代理或直连；停止服务时必须恢复其修改的路由与 DNS 状态。

原生 Network Extension 方案作为后续选项，需要另行准备 Apple 开发者签名与相应权限。

## 开发原则

- 将界面、配置管理、规则转换和网络内核运行管理分开。
- 将代理密码保存在 macOS Keychain，避免写入仓库或日志。
- 构建和普通测试不自动修改系统网络。
- 将真实网络接管作为显式启动操作，提供明确的停止与恢复行为。
- 使用应用路径和进程信息匹配规则，并考虑浏览器、邮箱等应用的辅助进程。

## 参考资料

- [sing-box 路由规则](https://sing-box.sagernet.org/configuration/route/rule/)
- [sing-box TUN 配置](https://sing-box.sagernet.org/configuration/inbound/tun/)
- [Apple Network Extension 部署说明](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
