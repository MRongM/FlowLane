# 验证记录

## 0.3：11 语言、双架构与公开发布

- `swift test`：68/68 通过，覆盖系统语言匹配、手动偏好持久化、全局/应用语言隔离、2068 条界面及运行消息的键/占位符、已有错误即时重渲染、旧状态兼容、特权请求字段不变，以及原有网络/凭据/生命周期边界。
- Python 诊断回归：7/7 通过，覆盖 allowlist 状态键、符号链接拒绝、未知/占位符消息隐藏、超时和启动错误脱敏及失败清理。
- [GitHub 原生 ARM/Intel CI](https://github.com/MRongM/app-proxy/actions/runs/38681481306)：两边均通过 68 项 Swift 测试、7 项 Python 诊断测试、Go 归属诊断、实际 loopback 转发、Release 打包/签名/内核摘要、捆绑 11 语言资源审计、产品 helper 配置校验和 LaunchServices 窗口冒烟。
- 原生 Swift 6.1 CI 曾在优化后的 helper 临时目录权限检查失败；将 `mkdtemp` 返回指针到 String 的复制移入数组 buffer 的有效借用范围后，两种原生架构的打包校验均通过。较新本地 Swift 未复现旧问题，未把本地成功作为旧问题不存在的依据。
- 11 种语言：en、zh-Hans、zh-Hant、ja、ko、fr、de、es、pt-BR、ru、ar。窗口和原生 Settings 共用一个偏好；部分 macOS 系统控件下次启动更新，系统授权窗口及原始内核诊断遵循系统/原始语言。
- ARM 原生构建与 Intel 交叉构建通过架构、资源、签名及固定内核原始字节校验；Intel 原生运行结果以 GitHub Actions 原生 runner 为准。helper 使用分架构固定摘要。
- 捆绑资源审计通过：离线 11 语言资源来自应用内部，未借助开发目录回退；原生 helper/内核的实际配置校验和本地分流通过，未启动 TUN。
- macOS 应用窗口冒烟通过 LaunchServices 启动。使用直接 Mach-O 或额外独立标记参数可出现窗口未创建，工作流已改用正常 `open -n -W`，将唯一标记放在测试路径中。
- 已捕获英文、简中、德文、阿拉伯语的应用页/设置页八张真实窗口截图；无文字裁切，阿拉伯语布局镜像。阿拉伯语混合路径的首斜杠显示问题已用 LTR 隔离处理。受 Accessibility 权限限制，未自动展开原生下拉菜单；选项数量/绑定/持久化由源码和测试验证。未请求额外权限。
- 介绍页包含 11 种语言，5 项 Node 测试及 22 组 Chrome 语言/桌面移动布局检查通过，无外部追踪、字体或脚本依赖，展示实际英文应用截图及明确的 TUN 验收边界。

公开源码前检查当前索引与 Git 历史中的凭据模式、私钥和意外产物。CI/Release 必须分别在原生 ARM/Intel runner 完成测试、捆绑资源审计及窗口冒烟；Release 验证不可变标签提交和应用版本后发布两个 ZIP 与 SHA256SUMS，Pages 部署仅从 main/手动任务执行。工作流实际结果见 GitHub Actions。完整受控管理员 TUN 验收仍与本次多语言/发布验证分开。

## 0.2：FlowLane 品牌与应用选择修复

2026-10-15，修复了零代理配置时“添加应用”不可点击的问题。现在可先选择真实 `.app`，保存为未分配代理且停用的规则，再分配代理。旧 UUID 规则保持兼容，启用却未分配代理的配置仍拒绝启动。

- `swift test`：51/51 通过，包括真实 TextEdit 选择、重启持久化、代理分配/清除、无代理规则拒绝授权和旧 JSON 兼容。
- `scripts/build.sh`：FlowLane.app 与 zip 构建、PNG → 标准 ICNS、ad-hoc 签名校验通过；旧 App Proxy.app 路径链接至新版。
- 新应用窗口冒烟通过，截图 `dist/flowlane-smoke.png` 已检查；窗口展示新名称、Logo、未分配代理规则和可点击的添加按钮。没有启动网络。
- 新捆绑 helper 产品配置校验与本地两种代理分流复测通过；授权脚本 `--self-test` 通过。
- 一次并发本地集成运行因 IPv4/IPv6 路由快照摘要变化报告失败；DNS/系统代理未变，全部转发断言通过。随后增加前后捕获诊断独立复测，路由/DNS/代理快照均一致，未复现差异。该次变化来源未确定，未通过重写路由或放宽比较消除失败。
- 独立审查无剩余 Critical / Important。真实管理员 TUN 接管与恢复继续保持未验证状态。

Logo 原图、生成方式和完整提示词见 [品牌记录](branding.md)。配置目录、Keychain 服务和应用 bundle identity 保持兼容。

以下是首次 0.1 交付时的独立证据。

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
