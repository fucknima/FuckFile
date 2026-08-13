# FuckFile — iOS 文件管理器

基于 MHA（MobileHouseArrest 身份信任）容器访问技术的 iOS 26.6 文件管理器。
面向高级用户：浏览、管理、编辑、预览其他 App 的沙盒容器与系统数据。

工程为 Objective-C（theos 构建），CI 通过 GitHub Actions 远程编译 unsigned IPA，
使用轻松签（Esign）注入 `com.apple.mobile.MobileHouseArrest` 身份后安装。

## 能力

- 设备存储虚拟根：App Data / App Groups / Extension Data / VPN / Service / System Data / System Groups / Protected
- LaunchServices 数据库全量扫描发现第三方 App（iOS 26 隐藏枚举的替代方案）
- App 显示名解析（iTunesMetadata + 静态表 + LS workspace）
- 列表浏览、排序（名称/大小/时间/类型 + 升降序）、类型筛选、搜索
- 多选批量：复制/剪切/删除/分享
- 文本编辑、结构化 plist 编辑、图片/音视频预览、十六进制查看
- ZIP/ipa/deb 解压（内置实现）、SHA-256、目录递归大小
- 运行日志页（分享/清空/手动重扫描）

## 构建

```sh
# GitHub Actions: build-unsigned-ipa workflow（theos，macOS runner）
```

签名安装：轻松签 → 保持 bundle id `com.apple.mobile.MobileHouseArrest`。

## 文档

- docs/PRODUCT.md — 产品规格
- docs/ROADMAP.md — 版本路线
- docs/ARCHITECTURE.md — 架构（含 ObjC 实现映射）
- docs/TODO.md — 任务清单（与代码同步）
- docs/DECISIONS.md — 架构决策记录
- AGENTS.md — AI 开发规则

## 免责声明

本工具用于安全研究与自身设备管理。访问其他 App 的沙盒数据涉及
隐私与合规风险，请仅在自己有权访问的设备上使用。
