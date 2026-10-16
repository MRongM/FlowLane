# 流径 FlowLane

名称寓意：每个应用，各行其径。Flow 表示网络流量，Lane 表示为不同应用选择的连接路径。

Logo 是深蓝圆角底板上的三条蓝绿流线，形成抽象 F。用于 Dock、Finder 与窗口页头。图标不包含文字，缩小时仍保留轮廓。

- 原图：`Resources/Brand/FlowLane.png`，1254 × 1254，带透明通道。
- 生成方式：内置 imagegen 工具，全新生成；未使用 CLI/API fallback，也未上传用户截图作为参考。
- 打包：保留 PNG 原图，以 macOS `sips` 生成标准尺寸，再用 `iconutil` 打包为应用内的 `AppIcon.icns`。
- GitHub 仓库：`MRongM/FlowLane`；应用、主程序及 Swift 包名称：`FlowLane`；中文显示名称：流径 FlowLane；产物：`dist/FlowLane.app`。版本直接使用语义版本号。
- 保留已有 bundle identifier、Keychain service 和配置目录，已有配置可继续使用；旧产物路径链接至新应用。

## 维护与兼容

- `Package.swift` 的包名和应用产品名、`Info.plist` 的 `CFBundleExecutable`、打包脚本及 CI 启动路径统一为 `FlowLane`。SwiftPM 资源目录随包名变为 `FlowLane_AppProxyKit.bundle`，打包复制与运行时查找必须同步；内部模块及 `AppProxyHelper` 保持原名。
- 继续使用 bundle identifier `com.mrongm.app-proxy`、配置目录 `~/Library/Application Support/App Proxy/` 和 Keychain service `com.mrongm.app-proxy.proxy-password`。这些兼容标识不随产品改名迁移。
- `.build/`、`build/`、`downloaded-binaries/`、诊断日志和 Python 缓存可在验证结束后清理，下次构建会重新生成或下载。`dist/` 只在本地保留最终应用、双架构 ZIP 和校验文件，不提交二进制产物。`tmp/` 用于本地临时文件；用户提供的原始参考截图保留在本地。
- `/Applications/FlowLane.app` 包含内核、图标和语言资源，独立于源码目录与构建缓存；改名或清理源码目录不影响已安装应用。安装和普通验证不自动启用网络。
- 资源审计使用 `dist/<arch>/FlowLane.app` 的实际目录或系统安装目录。当前审计按路径前缀判断资源归属，通过 `dist/FlowLane.app` 符号链接直接调用可执行文件会误报资源在应用外；这不代表实际包内缺失语言资源。

生成提示词：

```text
Use case: logo-brand. Asset type: final macOS application icon for FlowLane, Chinese name 流径, a native utility that assigns different network routes to individual applications. Create ONE polished, original, highly recognizable icon, centered in a square 1024x1024 image. A deep midnight-blue rounded squircle tile with generous macOS-style rounded corners. Within it, a bold sculpted mark made of three clean flowing ribbons/lanes in luminous cyan, teal and electric blue: a common lower-left flow bends gracefully upward and separates into distinct routes, subtly suggesting an F through negative space. Make the silhouette simple and memorable, legible at 32 pixels, with balanced optical spacing and restrained glass/enamel depth. Crisp refined edges, soft internal highlights, subtle dimensional shading, professional desktop software identity. The exterior outside the rounded tile must be genuinely transparent alpha. No text, no wordmark, no letters printed on the tile, no logo presentation board, no multiple versions, no devices or surrounding mockup, no arrows, no shield, no lock, no network node dots, no excessive glow, no watermark. Deliver just the single finished application icon with approximately 7% transparent outer margin.
```
