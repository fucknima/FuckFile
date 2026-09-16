# FuckFile — iOS 文件管理器

一个普通沙盒文件管理器：只管理 App 自己 Documents 目录里的文件，通过 Files、
AirDrop、分享面板导入导出。不包含任何跨容器访问、身份伪装或私有安装能力。

工程为 Objective-C（theos 构建），CI 通过 GitHub Actions 远程编译 unsigned IPA，
用任意签名工具重签即可安装（bundle id `com.fucknima.fuckfile`，无需注入系统身份）。

## 能力

- 浏览 App 沙盒（Documents）：列表/网格、面包屑、排序（名称/大小/时间/类型）、
  类型筛选、当前目录搜索
- 多选批量：复制/移动/分享/压缩/删除
- 导入：Files「打开方式」、分享面板（App Group 或 localhost 直传，不依赖跨容器权限）
- 文本编辑、结构化 plist 编辑、图片/音视频预览、十六进制查看、SQLite 只读浏览、PDF 阅读
- Office 预览（doc/docx/ppt/xlsx 等，离线运行时；保真度限制见 docs/TODO.md）
- ZIP 包内浏览、解压、压缩（store/deflate 自适应）、SHA-256、目录递归大小
- 局域网文件共享（浏览器 + WebDAV，仅 App 沙盒内容）
- 运行日志页（分享、清空）

## 构建

```sh
# GitHub Actions: build-unsigned-ipa workflow（theos，macOS runner）
```

安装：用任意签名工具重签 IPA。

## 文档

- docs/PRODUCT.md — 产品规格
- docs/ROADMAP.md — 版本路线
- docs/ARCHITECTURE.md — 架构（含 ObjC 实现映射）
- docs/TODO.md — 任务清单（与代码同步）
- docs/DECISIONS.md — 架构决策记录
- AGENTS.md — AI 开发规则

## 免责声明

本工具只访问自己沙盒内的文件，导入的外部文件需要用户显式授权。
