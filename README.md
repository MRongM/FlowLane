# 流径 FlowLane

每个应用，各行其径。Logo 以三条蓝绿流线组成抽象的 F，表示为应用选择独立网络路径。原图位于 [Resources/Brand/FlowLane.png](Resources/Brand/FlowLane.png)，随应用生成 Dock / Finder 图标。

macOS 原生按应用代理工具。选择 `.app`，为它指定已有的 SOCKS5 或 HTTP CONNECT 上游；未匹配和无法识别的连接默认直连。无需 Apple 开发者账号，采用 SwiftUI + 固定版本 sing-box TUN，每次启动网络接管时请求管理员授权。

当前已实现代理与应用规则管理、Keychain 密码存储、配置持久化、受控 helper、启动/停止状态和连接日志。已完成无特权的真实进程归属与代理转发验证；**完整 TUN 接管和恢复尚待用户完成最后的管理员授权验收**，不能据此宣称全机分流已经实测通过。

## 构建与打开

需要 Apple Silicon Mac、macOS 14+、Xcode 和命令行工具。本次构建环境为 macOS 26.6 / Swift 6.3.3。没有外部 Swift 包依赖；Go 仅用于独立归属诊断，Python 3 用于集成测试。

```sh
./scripts/build.sh
open "dist/FlowLane.app"
```

产物为 `dist/FlowLane.app` 和 `dist/FlowLane-macos-arm64.zip`。旧 `dist/App Proxy.app` 路径保留为新应用的兼容链接。脚本校验并下载官方 sing-box 1.14.3，以本地 ad-hoc 签名打包。无需签名身份，未公证。命令只设置本次构建的 `DEVELOPER_DIR`，不会全局切换 Xcode；打开界面不接管网络。

## 使用

1. 在“应用规则”选择 `.app`；没有代理时也能添加，规则会以“未分配代理”状态保存并保持停用。
2. 在“代理配置”添加 SOCKS5 或 HTTP CONNECT 的主机、端口和可选认证，再在规则中分配代理。密码保存在 Keychain，普通配置不保存密码。列表从上到下匹配；可选择是否包含包内 Helper / XPC。
3. 点击“启动网络接管”，通过上游端口及内核配置检查后，在 macOS 弹窗中授权。上游预检只证明 TCP 端口可达，认证或代理转发错误在运行日志中显示。
4. 点击“停止网络接管”结束会话。修改代理/规则前需先停止。停止会断开经过内核的现有连接，并显示网络恢复检查结果。

TUN 接收按系统路由送来的流量，再决定代理或直连；未选中的应用也可能经过内核。已识别且匹配的 TCP 连接在上游故障时返回错误，不自动改走直连。界面退出或心跳失效会让 helper 停止内核。

本地上游的监听进程及其整个 `.app` 包优先直连，覆盖应用规则以防代理回环，运行日志会列出这些例外。无法核实本地监听进程时拒绝启动；其 PID、可执行路径、用户或启动时间改变时停止会话，需重新启动。

## 支持范围

| 路径 | 首版策略与验证范围 |
| --- | --- |
| TCP / HTTPS / IMAP / SMTP | 按进程路径分配 SOCKS5 或 HTTP CONNECT；真实本地 TCP 转发已测，未读取或发送用户邮件 |
| 应用内 Helper / XPC | 转义且锚定的包路径匹配；包外共享服务无法自动归属 |
| 未知 / 未匹配进程 | 默认直连，不提供强制防泄漏保证 |
| UDP / QUIC | 已匹配应用拒绝；未匹配直连；本地内核拒绝测试通过，TUN 路径待测 |
| DNS | `dns_mode: disabled`，端口 53 直连；不修改系统 DNS，不提供按应用 DNS 或 DNS 隐私 |
| IPv6 | 与 IPv4 一并配置 TUN；配置校验通过，真实 IPv6 接管待授权及可用 IPv6 网络验证 |
| TLS 内容 | 不解密，不安装根证书；不观测完整 HTTPS URL、请求头或正文 |

Loopback、本地链路、绑定指定接口的应用和其他 VPN 的更高优先级路由可能绕过 TUN。WebKit 网络服务等共享进程可能被识别为包外进程或未知，不能保证随其发起应用代理。详见 [验证记录与已知限制](docs/verification.md)。

## 测试

普通测试不请求管理员授权、不启动 TUN、不修改系统路由、DNS 或代理设置：

```sh
./scripts/test.sh
python3 scripts/integration.py --helper "$PWD/dist/FlowLane.app/Contents/MacOS/AppProxyHelper"
"dist/FlowLane.app/Contents/MacOS/AppProxy" --smoke-test "$PWD/dist/ui-smoke.png"
```

Swift 测试覆盖模型、规则、Keychain、文件权限、配置编译、生命周期和 helper 边界。独立 Go 诊断以两个可执行文件各自的 TCP/UDP socket 验证真实 Darwin 归属；Python 集成测试以独立本地上游计数验证两种代理、默认直连、故障无回退和 UDP 拒绝。参考 [归属证据](docs/attribution-results.md)、[本地转发证据](docs/local-integration-results.md)。

最后的真实接管验收需要用户在本机明确启用管理员授权，详见 `scripts/privileged-acceptance.py --help` 和 [验证记录](docs/verification.md)。它与普通测试分离，运行前请保存工作；测试结束后核实恢复结果。不要向任何人提供管理员密码，也无需关闭 SIP。

## 数据、凭据与特权边界

普通配置位于 `~/Library/Application Support/App Proxy/configuration.json`（0600）；密码以代理 UUID 存于 Keychain。启动请求放入 0700 的随机会话目录，文件为 0600；helper 消费后立即删除，内核和含凭据配置仅在 root 私有临时目录存在，正常停止/失败后清理。日志有长度上限并脱敏，不保存原始配置。

helper 不提供任意 shell 执行或用户指定内核/config 接口。它验证会话所有者、父进程、文件权限及链接，按模型生成允许的配置，复制捆绑内核后校验固定 SHA-256。无常驻特权服务；本地 ad-hoc 签名不等于公证或硬化的安装信任链，每次管理员授权都在信任当前本地应用副本。

停止会关闭本会话的 utun，比较路由、DNS 和系统代理状态；发现差异会报告，不覆盖其他网络工具的配置。强制杀死监督进程或机器崩溃的边界、残留会话处理见 [helper 协议](docs/helper-protocol.md)。不要使用 `killall sing-box`，它可能影响其他网络软件。

## 代码与许可

`Sources/AppProxyKit` 保存模型、规则编译、持久化与会话边界；`Sources/AppProxy` 是 SwiftUI 界面；`Sources/AppProxyHelper` 负责特权生命周期。设计与执行记录位于 `docs/superpowers/`。

本项目采用 GPL-3.0-or-later，见 [LICENSE](LICENSE)。捆绑的 sing-box 1.14.3 许可、完整源码地址和固定摘要见 [ThirdParty/sing-box](ThirdParty/sing-box/SOURCE.md)。下载二进制、运行配置和应用产物均不进入 Git。
