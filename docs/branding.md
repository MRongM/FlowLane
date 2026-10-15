# 流径 FlowLane

名称寓意：每个应用，各行其径。Flow 表示网络流量，Lane 表示为不同应用选择的连接路径。

Logo 是深蓝圆角底板上的三条蓝绿流线，形成抽象 F。用于 Dock、Finder 与窗口页头。图标不包含文字，缩小时仍保留轮廓。

- 原图：`Resources/Brand/FlowLane.png`，1254 × 1254，带透明通道。
- 生成方式：内置 imagegen 工具，全新生成；未使用 CLI/API fallback，也未上传用户截图作为参考。
- 打包：保留 PNG 原图，以 macOS `sips` 生成标准尺寸，再用 `iconutil` 打包为应用内的 `AppIcon.icns`。
- 显示名称：流径 FlowLane；产物：`dist/FlowLane.app`。
- 保留已有 bundle identifier、Keychain service 和配置目录，已有配置可继续使用；旧产物路径链接至新应用。

生成提示词：

```text
Use case: logo-brand. Asset type: final macOS application icon for FlowLane, Chinese name 流径, a native utility that assigns different network routes to individual applications. Create ONE polished, original, highly recognizable icon, centered in a square 1024x1024 image. A deep midnight-blue rounded squircle tile with generous macOS-style rounded corners. Within it, a bold sculpted mark made of three clean flowing ribbons/lanes in luminous cyan, teal and electric blue: a common lower-left flow bends gracefully upward and separates into distinct routes, subtly suggesting an F through negative space. Make the silhouette simple and memorable, legible at 32 pixels, with balanced optical spacing and restrained glass/enamel depth. Crisp refined edges, soft internal highlights, subtle dimensional shading, professional desktop software identity. The exterior outside the rounded tile must be genuinely transparent alpha. No text, no wordmark, no letters printed on the tile, no logo presentation board, no multiple versions, no devices or surrounding mockup, no arrows, no shield, no lock, no network node dots, no excessive glow, no watermark. Deliver just the single finished application icon with approximately 7% transparent outer margin.
```
