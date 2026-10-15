# 流径 FlowLane

**为每个 macOS 应用选择自己的代理连接。**

[English](README.md) · [介绍页面](https://mrongm.github.io/app-proxy/) · [下载版本](https://github.com/MRongM/app-proxy/releases/latest) · [验证记录](docs/verification.md)

![CI](https://github.com/MRongM/app-proxy/actions/workflows/ci.yml/badge.svg)

选择 `.app`，为它分配你已有的 SOCKS5 或 HTTP CONNECT 服务，未匹配流量默认直连。原生 SwiftUI 界面搭配固定版本的开源 sing-box TUN 内核，无需 Apple 开发者账号。

**当前为预览版本。** 已完成本地真实 TCP 转发、进程归属、配置、语言切换与受控运行边界验证；完整管理员 TUN 接管、IPv6 流量及恢复仍需单独验收。未知或包外共享进程可能直连，不提供强制防泄漏保证。

## 下载

需要 **macOS 14 或更新版本**：

| Mac 类型 | 下载 |
| --- | --- |
| Apple Silicon（M 系列） | [FlowLane-macos-arm64.zip](https://github.com/MRongM/app-proxy/releases/latest/download/FlowLane-macos-arm64.zip) |
| Intel | [FlowLane-macos-x86_64.zip](https://github.com/MRongM/app-proxy/releases/latest/download/FlowLane-macos-x86_64.zip) |

解压后将 `FlowLane.app` 移到“应用程序”。应用采用 **ad-hoc 签名，未公证**；如果系统阻止打开，请按 [Apple 的官方说明](https://support.apple.com/guide/mac-help/mh40616/mac)在系统设置中确认。无需关闭 SIP，也无需购买开发者账号。Release 附带 `SHA256SUMS` 校验文件。

## 使用

1. **选择应用**：没有代理配置也能添加 App；未分配代理的规则会保存并保持停用。
2. **添加和分配代理**：填写已有的 SOCKS5 / HTTP CONNECT 主机、端口与可选认证，密码存于 Keychain。规则按从上到下的顺序匹配，可包含应用包内的 Helper / XPC。
3. **明确启动**：点击“启动网络接管”，在 macOS 系统弹窗输入管理员账户的登录密码。打开应用不会自动接管网络。修改规则前先停止，停止会断开内核处理的现有连接。

TUN 接收由系统路由送来的流量，再决定代理或直连，未选中的应用也可能经过内核。已识别且匹配的 TCP 在上游失败时返回错误，不自动直连。经验证的本地上游进程及整个应用包优先直连以防回环，进程身份改变会停止会话。

## 11 种界面语言

打开应用内 **设置 → 界面语言**，或菜单 **FlowLane → 设置…**（`⌘,`）。支持“跟随系统”和手动选择，文案即时刷新，重启后保留；切换语言不会重置规则、代理、密码或正在使用的连接。

英语、简体中文、繁体中文、日语、韩语、法语、德语、西班牙语、葡萄牙语（巴西）、俄语、阿拉伯语。

系统匹配支持语言地区变体及中文简繁脚本，未覆盖的语言回退英语。阿拉伯语使用 RTL 镜像布局，文件路径、连接地址及原始日志保持 LTR。部分 macOS 原生菜单和对话框控件会在下次启动采用所选语言；管理员系统弹窗遵循 macOS 语言。内核原始日志和系统诊断详情保留原文。

标准 `.lproj` / `.strings` 资源覆盖界面、配置校验、运行错误和恢复报告。状态传输稳定消息键与参数，在界面端按当前语言渲染；测试核对所有语言的键、占位符及兼容性。详见[国际化设计](docs/superpowers/specs/2026-10-15-localization-design.md)。

## 网络支持范围

| 路径 | 策略 |
| --- | --- |
| TCP / HTTPS / IMAP / SMTP | 按进程指定 SOCKS5 / HTTP CONNECT；真实本地转发已测，未读取或发送用户邮件 |
| 应用内 Helper / XPC | 转义且锚定的应用包路径匹配；包外共享服务不能自动归属 |
| 未匹配 / 未知进程 | 默认直连 |
| UDP / QUIC | 匹配应用拒绝，其他直连；真实 TUN 路径仍待验收 |
| DNS | 端口 53 直连，`dns_mode: disabled`，不修改系统 DNS，不提供按应用 DNS 或 DNS 隐私 |
| IPv6 | 包含于 TUN 配置，真实接管需在合适网络下单独验收 |
| TLS 内容 | 不解密、不安装根证书，不观测完整 HTTPS URL、请求头及正文 |

Loopback、本地链路、应用绑定接口或其他 VPN 的高优先级路由可能绕过 TUN。进程归属来自 socket 表快照，可能存在竞态及共享网络进程限制。详见[已知限制与验证证据](docs/verification.md)。

## 构建和测试

需要 Xcode 与命令行工具，Swift 无外部包依赖；Go 用于原生归属诊断，Python 3 用于集成和网站构建。

```sh
./scripts/build.sh
./scripts/build.sh --arch arm64
./scripts/build.sh --arch x86_64
open "dist/FlowLane.app"
```

两种产物分别为 `dist/FlowLane-macos-arm64.zip` / `dist/FlowLane-macos-x86_64.zip`，应用在 `dist/<arch>/FlowLane.app`。本机兼容路径指向原生版本；跨架构构建不会替换原生启动目标。CI 分别在 ARM / Intel 原生 runner 上测试，构建不切换全局 Xcode 配置。

```sh
./scripts/test.sh
"dist/FlowLane.app/Contents/MacOS/AppProxy" --localization-audit
python3 scripts/integration.py --core "$PWD/dist/FlowLane.app/Contents/Resources/sing-box" --helper "$PWD/dist/FlowLane.app/Contents/MacOS/AppProxyHelper"
open -n -W -a "$PWD/dist/FlowLane.app" --args --smoke-test
python3 scripts/privileged-acceptance.py --self-test
```

构建和普通测试不启动 TUN、不修改系统路由、DNS 或代理。用户自行授权的真实 IPv4 验收命令为 `python3 scripts/privileged-acceptance.py --activate`，结果保存在忽略的 `dist/privileged-acceptance.json`；IPv6 / UDP 仍需单独测试。

## 数据和特权边界

普通配置保存在 `~/Library/Application Support/App Proxy/configuration.json`（0600），保留旧版本路径和 Keychain 服务。语言偏好仅写本应用的 UserDefaults。密码通过 Keychain 读取，经 0700/0600 临时会话交给 helper，读取后删除请求；正常停止/失败后清理 root 私有运行文件。日志限长并脱敏。

helper 校验用户、父进程、文件权限及固定内核摘要，拒绝链接，按允许的模型生成配置；不提供任意 shell、内核或配置输入，不安装常驻 root 服务。界面退出、心跳失效和内核故障有监督清理路径。停止只比较网络状态，不导入旧快照覆盖其他工具的设置；强制杀死整个 helper 或机器崩溃的边界见 [helper 协议](docs/helper-protocol.md)。

## GitHub 发布与介绍页

- [CI](.github/workflows/ci.yml)：原生 ARM / Intel 测试、打包及本地化资源审计。
- [Release](.github/workflows/release.yml)：校验标签与应用版本，两个原生构建通过后同时发布 ZIP 和 SHA256SUMS；手动触发默认只构建。
- [Pages](.github/workflows/pages.yml)：发布 [11 语言介绍页面](https://mrongm.github.io/app-proxy/)。本地执行 `python3 scripts/build-site.py` 后可预览 `build/site`。

源码采用 [GPL-3.0-or-later](LICENSE)。固定 **sing-box 1.14.3** 的 ARM / Intel 摘要、许可与匹配源码见 [ThirdParty/sing-box](ThirdParty/sing-box/SOURCE.md)。下载内核、含凭据运行配置和构建产物均不进入 Git。[Logo 与生成提示词](docs/branding.md)。
