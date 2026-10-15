# 验证记录

本记录区分无需特权的独立验证和需要用户授权的 TUN 验收。所有普通测试、构建和 UI 冒烟运行均不得启用 TUN 或修改系统网络。

## 环境

- Apple Silicon，macOS 26.6，Swift 6.3.3，已安装 Xcode。
- 构建命令使用局部 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，不修改全局 `xcode-select`。
- sing-box 固定 v1.14.3，官方 archive SHA-256 `0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5`。
- 解包可执行文件 SHA-256 `28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2`，helper 在复制到私有目录后再次验证。

## 独立证据

2026-10-15 最终核对结果：

| 命令/检查 | 结果 |
| --- | --- |
| `scripts/test.sh` | Swift 44/44，Go 诊断测试与四个真实 TCP/UDP 归属观测通过；本地集成通过 |
| `scripts/build.sh` | Release 构建、捆绑固定内核、ad-hoc 签名与 `codesign --verify --deep --strict` 通过 |
| `scripts/integration.py --helper ...` | 产品 Swift 编译器与两种代理、Helper/精确路径规则的实际内核校验通过；进程分流各重复三轮通过 |
| `scripts/privileged-acceptance.py --self-test` | 请求协议、权限、一次性执行文件、进程身份与会话归属防护测试通过；未调用 sudo/TUN |
| `AppProxy --smoke-test ...` | 代理/规则增改删、持久化重读、实际窗口创建通过；已检查窗口截图；网络未启动 |
| 独立代码审查 | 已修复 SOCKS5 长度崩溃、等待授权取消、本地上游回环与双栈监听、验收脚本跨会话信号防护；无剩余 Critical/Important 项 |

所有本地集成与验收脚本自测的 IPv4/IPv6 路由、DNS、系统代理快照比较均无变化；临时进程和凭据文件清理完成。原始系统网络内容不写入仓库，只报告比较结果。

- `swift test`：代理/规则校验、配置编译、Keychain 实际增改查删、原子持久化、权限、.app 可执行程序选择、状态转换、会话心跳与清理、拒绝符号链接与硬链接、特权命令参数拒绝。
- `tools/attribution`：直接调用固定版本 sing-box 的 Darwin 进程搜索实现。两个不同的真实可执行文件各保持 TCP 和 UDP socket，验证其返回路径与独立 PID 路径查询一致；不存在的连接返回未知。详细结果见 [归属记录](attribution-results.md)。
- `scripts/integration.py`：真实 sing-box loopback 入站，独立的本地 SOCKS5 / HTTP CONNECT 上游及目标服务。通过上游握手计数、目标请求计数证明指定进程走代理、未匹配进程直连，以及代理故障无直接回退和 UDP 拒绝。详细结果见 [本地集成记录](local-integration-results.md)。
- 带 `--helper` 的集成命令调用捆绑 helper 的 `check`，校验产品 Swift 编译器实际生成的 TUN 配置，但不运行 TUN。
- UI `--smoke-test` 使用独立临时配置执行代理及规则的增改删与持久化，渲染窗口后退出，不读写用户配置、不激活网络。
- 无害 `/bin/sleep` 替代授权进程验证等待授权时的停止/退出，真实上游预检失败在启动授权前终止；不以此代替实际 macOS 授权弹窗的手工验收。
- 本地上游监听端口的实际 PID/路径验证、通配监听地址/IPv6 解析、原生进程启动时间核验、监听缺失拒绝和优先直连编译均有测试。完整 TUN 内本地上游回环保护仍待授权验收。

## 待授权的真实 TUN 验收

截至本次交付，管理员授权后的 TUN 实测尚未运行。不能把以下项目视为通过：系统路由接管、外部 HTTPS TCP 按应用分流、真实 IPv6 TCP、TUN 中 UDP/QUIC、TUN 停止及内核异常退出后的实际恢复。

普通集成测试证明进程识别和代理转发在本机可工作，不能替代这一步。最终授权脚本会显式启用 TUN，生成一次性测试应用与本地上游，访问公开测试站点并收集上游观测；完成后停止并比较系统网络状态。脚本结果保存在忽略的 `dist/` 目录。

用户最后执行：

```sh
python3 scripts/privileged-acceptance.py --activate
```

脚本让系统 `sudo` 在用户终端请求授权，测试 SOCKS5 下的 IPv4 HTTPS 选中/未匹配分流、上游失败、正常停止和受监督内核 SIGKILL 后的恢复。结果为 `dist/privileged-acceptance.json`。此脚本当前默认不执行 UDP/QUIC 和 IPv6 的真实接管验收，这两项仍需单独有适当网络条件的测试，不能随 IPv4 通过而自动标为通过。

实际 macOS 授权取消弹窗尚未手工测试；取消事件的状态处理已有测试。真实配置错误与篡改内核拒绝使用无特权 `check` 验证。

## 限制与故障边界

- 连接归属来自 socket 表快照，可能受竞态、连接复用及共享系统网络进程影响。未知归属按明确默认策略直连，不提供强制防泄漏保证。
- 仅包内 Helper 自动匹配；包外 WebKit / 系统服务不能自动归到选中应用。应用移动或升级需重新确认路径。
- DNS 端口 53 直连；不改系统 DNS，不提供 DNS 隐私和每应用 DNS。应用自建 DoH/DoT 的 TCP 连接仍按其进程路径匹配。
- 匹配 UDP/QUIC 拒绝，未匹配 UDP 直连。IPv6 配置受实际网络、路由优先级及归属能力限制。
- Loopback、本地链路、应用绑定物理接口及更高优先级 VPN 路由可能绕过 TUN。
- UI 退出/心跳超时、内核异常退出及 helper 常规退出信号具有清理路径。操作系统强制 `SIGKILL` 整个监督进程、内核/机器崩溃不等于经过了正常清理；完整恢复保证仍需特权验收。不要盲目导入启动前快照覆盖其他软件同期网络改动。
