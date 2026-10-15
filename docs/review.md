# 交付前审查

2026-10-15，独立审查覆盖 Swift 模型/编译器、Keychain、会话文件边界、root helper、网络生命周期、UI 取消与验收脚本。最终无剩余 Critical / Important 发现，允许交付源码；真实管理员 TUN 验收仍待执行。

已修复并验证：

- SOCKS5 密码长度使用 UTF-8 字节数，255/256 边界及多字节密码有回归测试；保存到 Keychain 前与运行时编译均拒绝超限。HTTP CONNECT 不采用 SOCKS5 限制。
- 授权进程同步发起后异步等待，停止/退出可取消尚未建立 helper 会话的等待；独立的 pending 状态阻止旧操作返回前再次启动。测试以真实 `/bin/sleep` 代替授权进程，不弹管理员框。
- 本地上游的监听 PID、路径、UID 与进程启动时间经过验证；其执行路径和整个应用包先直连，再匹配用户规则。身份改变则停止。真实本地 IPv4、localhost、IPv4-mapped IPv6、双栈与 IPv6-only 边界均有测试。
- 验收脚本在发送信号前以原生进程信息、出生时间和父进程链确认内核属于当前 UUID 会话及本次启动的 sudo/helper；拒绝另一会话、PID 重用及 launcher 替换。自测不发送特权信号。
- 日志上限统一为 150 条；凭据明文、JSON 转义、百分号编码、Basic token 和跨行片段均脱敏。

无法捕获的 helper SIGKILL/机器崩溃、共享进程归属和未知连接直连策略已在 README 与 helper 协议记录。没有把状态机、配置解析或 loopback 结果当作真实 TUN 恢复的证明。
