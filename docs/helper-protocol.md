# 每次授权会话的 helper 协议

`AppProxyHelper` 随应用打包于 `Contents/MacOS`，不安装 launch daemon，也不常驻。唯一可执行内核位置为同一包的 `Contents/Resources/sing-box`。固定 sing-box 1.14.3 arm64 内核 SHA-256：`28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2`。helper 把二进制复制到当前有效用户拥有的 0700 私有临时目录，在复制完成后校验目标文件摘要，再执行。授权运行时临时目录属于 root。

## 命令

```text
AppProxyHelper check --session ABS
AppProxyHelper run --session ABS --owner UID --parent PID
```

参数顺序和数量固定；不接受额外参数、任意内核位置、任意配置、脚本或 shell 命令。`check` 可无特权运行，只生成允许字段的配置，并运行固定内核的 `check -c CONFIG`；不会创建 TUN、修改系统路由、DNS 或代理，且保留请求以供随后授权。`run` 必须由显式管理员授权启动，验证请求身份和内核后才运行 `run -c CONFIG`。

## 目录与请求

UI 调用 `SessionDirectory.create(configuration:passwords:)`，生成当前用户真实 home 下的：

```text
~/Library/Application Support/App Proxy/Sessions/UUID/  0700，用户拥有
  request.json  0600，用户拥有，最多 1 MiB
  heartbeat     0600，用户拥有
  stop          0600，用户拥有，仅停止时创建
  status.json   0600，用户拥有，由 helper 发布
```

`SessionRequest` JSON 字段为 `configuration: AppConfiguration`、`passwords: [String:String]`（代理 UUID → 密码）、`parentPID: Int32`、`ownerUID: UInt32`、`token: String`（两个随机 UUID）。顶层字段集合严格匹配；代理与规则须通过领域模型验证。helper 用编译器重新生成全部配置，不接收原始内核配置。密码只存在于短期请求和私有运行配置，不能写普通配置、日志或 Git。

helper 通过用户数据库取得 home，逐层 `openat(O_DIRECTORY|O_NOFOLLOW)` 检查目录所有者和可写权限，固定最终目录描述符；会话目录必须为请求用户拥有的 0700 目录，最后组件必须是 UUID。文件用 `openat(O_NOFOLLOW|O_NONBLOCK)` 打开，验证普通文件、所有者、0600、单一硬链接和大小限制。`run` 在成功安全读取后立即 unlink 请求，格式错误也删除已读取请求；`check` 不删除。无效类型、权限或过大文件拒绝读取并保留给 UI 清理。

状态通过独占创建随机临时文件、写入、设置用户所有权、`fsync`、同一目录内 `renameat` 发布。不会跟随或截断已存在的 `status.json` 链接。root 不在用户可替换的目录内执行二进制或保存运行配置。用户若替换控制文件造成通信失败，helper 停止内核。

## 控制与状态

UI 每秒调用 `heartbeat()`，发布带令牌和 Unix 时间戳的 JSON。`requestStop()` 发布包含令牌的 `stop` 文件；令牌错误不构成停止授权。心跳缺失、格式错误、超过 10 秒或来自未来超过 2 秒都使会话结束。helper 检查父进程仍存在且有效 UID 与请求用户相同；命令行 parent 必须与请求一致。

`SessionStatus` 公共 Codable 字段：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| phase | `RuntimePhase` | stopped / starting / running / stopping / failed |
| message | String | 可向用户显示的结果或失败原因 |
| corePID | Int32? | 当前受监督的内核 PID；终态为空 |
| logs | [String] | 最多 150 条、每条最多 2048 字符的已脱敏日志 |
| restoration | String? | 停止后的网络状态比较结果 |

helper 在内核报告 `sing-box started` 后才发布 `running`，20 秒未就绪视为失败。启动前以及即将调用内核之前均检查 STOP、心跳和父进程，因此授权弹窗期间取消不会继续接管网络。

STOP、心跳失效、父进程退出、SIGTERM/SIGINT/SIGHUP/SIGQUIT、内核异常退出都会结束会话。停止先发送 SIGTERM，最多等待 5 秒，随后 SIGKILL 并回收子进程。stdout/stderr 在运行中持续读取，按完整行脱敏，超长行丢弃；配置校验输出完全丢弃，避免错误诊断引用凭据。失败状态保留给 UI；私有二进制和含密码配置在 helper 返回时清理。

## 恢复验证与边界

接管前后只读运行 `netstat -rn -f inet/inet6`、`scutil --dns` 和 `scutil --proxy`，每条命令限时 3 秒，最多读取 2 MiB。路由只保留排序后的 Destination/Gateway/Flags/Netif，忽略 `L` 链路层邻居、Expire 和计数器。停止后短暂重试等待 utun 路由清理；输出缺失或仍有差异都标为失败并说明具体类别。不会导入旧快照、重写其他工具的路由、DNS 或代理。

本协议未通过本次普通测试证明实际 TUN 接管/IPv6 TCP/停止恢复；这些需要用户明确授权的独立验收。进程未知默认直连，包外共享 helper 无法可靠归属；DNS 明确直连；已匹配 UDP 拒绝。端口 53 不提供 DNS 隐私。

helper 自身遭 SIGKILL、进程崩溃或机器突然断电时，`defer` 和信号处理无法保证执行；macOS 不提供此实现可用的父进程死亡自动终止机制。可能遗留 root 内核或私有运行文件，不能宣称崩溃后的网络恢复已验证，也不能仅凭记录的 PID 盲目结束进程。需核实进程可执行文件、归属和私有目录后进行显式管理员恢复。正常 UI 退出/崩溃由仍存活的 helper 监督处理。

UI 启动时可调用 `SessionDirectory.cleanupAbandoned()`。它只清理安全打开且父 PID 已通过 `kill(pid,0)` 的 ESRCH 确认消失的未消费请求，或请求已消费、状态为 stopped/failed 且无内核 PID 的终态；记录的内核 PID 存活、权限不可知或状态不明时保留，不执行 kill。授权前 UI 崩溃留下的 0600 请求会在下次启动清理；PID 被重用时保守保留。UI 正常结束等待 helper 退出后调用 `cleanup()`；其清理仅 unlink 当前目录的叶子条目，不跟随链接或递归进入子目录。

## 本地上游避免回环

只有启用规则实际引用的代理参与启动时检查。授权 `run` 在 TUN 启动前解析这些上游的全部 IPv4/IPv6 地址（主机名解析限时 4 秒），与当前接口及 loopback 地址比较；IPv4 映射 IPv6 loopback 也视为本地。`check` 仍然只验证配置，不要求实际代理在线。

本地地址使用固定参数 `/usr/sbin/lsof -nP -iTCP:PORT -sTCP:LISTEN -Fpftn` 查询 TCP 监听者，每次限时 3 秒、输出上限 1 MiB。按精确 IP/端口和 IPv4/IPv6 类型匹配，通配监听只匹配对应类型，不因同一端口把不同具体 IP 的进程加入豁免。`localhost` 同时解析到 IPv4/IPv6 而只有其中一个监听时，检查已存在的监听者；至少一个本地地址必须有可核验监听者。查询失败、所有本地地址均无监听者或进程身份不可验证时，启动失败，不启用 TUN。

监听者必须由原生 `proc_pidpath` 和内核进程信息核验其可执行路径、UID、PID 和启动时间。固定内核以及已核验的本地上游可执行文件优先直连；属于 `.app` 的上游将整个最外层应用包及包内 Helper 优先直连，覆盖用户选择的应用规则。这样本地代理自己的出站连接不会再次送回本地代理。状态日志明确显示此覆盖策略。

启动前及运行期间每轮检查已核验上游的进程身份；退出、重启、PID 重用或执行路径改变都会停止内核，必须重新启动会话。包外共享进程无法仅根据该应用监听者可靠归属，仍不能保证自动覆盖；需要保持该共享进程未被应用规则代理。上游 DNS 解析结果、监听绑定或进程架构在会话中改变时，应停止并重新启动，发现阶段不是持续 DNS/端口监控。IPv6 通配 socket 是否接受 IPv4 连接无法仅凭 lsof 类型确认。仅当本地 IPv4 端点没有普通 IPv4 监听匹配、但同端口存在 IPv6 通配监听者时，helper 才对该已确认本地的数字 IPv4 地址执行最多 1 秒的非阻塞 TCP 连接探测；连接后立即关闭，不发送应用数据，并响应取消。探测失败则不增加这些豁免。探测成功后将已通过原生身份核验的候选 IPv6 通配监听者加入豁免；这根据端点可连接性推断双栈能力，无法证明连接属于多个候选中的哪个 socket，因此会保守覆盖这些候选。若已有普通 IPv4 匹配，就完全不加入额外 IPv6 候选，避免豁免同端口不相关进程。未通过实际授权 TUN 测试前，不把此预防措施描述为网络回环已实测消除。

信号处理在建立私有运行目录前安装，SIGTERM/SIGINT 等在配置校验期间也会触发取消、回收校验子进程并清理临时文件；SIGKILL 和机器断电边界仍然存在。
