# Swift 重写（swift-fuckfile 分支）

目标：用 Swift（SwiftUI 为主，必要时 UIKit）重写 FuckFile，功能对齐现有
Objective-C 版，并为后续「Feather 式 IPA 安装器」提供 Swift 生态接入点。

- 旧实现保留在 `src/`（Objective-C）作为参考与行为对照，重写期间不参与编译；
  达到功能对齐后删除。
- 本分支的 App 只编译 `Sources/*.swift`；Makefile / CI 已按重写版调整
  （不再有 runtime 准备、libarchive、ShareExtension 打包步骤）。
- 构建产物：CI `build-unsigned-ipa`（push `swift-fuckfile` 触发），
  发布为 `review-ipa-<run>` 预发布，装法不变（重签 IPA）。

## 阶段

1. **骨架（已完成）**：App shell（文件/任务/设置三个 tab）、存储环境
   （Documents 沙盒 + 内部条目过滤）、日志（与旧版同一份日志文件）、
   目录列举、任务模型/串行执行器。
2. **文件浏览器 + 文件操作**：网格/列表、多选、复制/移动/删除/重命名、
   回收站、冲突处理。
3. **查看器/编辑器**：文本、图片、媒体、PDF、Office、SQLite、Hex、压缩包。
4. **网络与任务中心**：WebDAV/局域网共享、下载任务、任务中心 UI 完整化。
5. **安装器**：pairing 文件导入 + LocalDevVPN 连通 + lockdownd/AFC/
   installation_proxy（Feather 的 Pairing 安装路径，只装已签名 IPA）。

## 约定

- 每次推进都必须可编译、可出包、可真机验证；不合并半成品到主分支。
- 文档先行：改 PRODUCT.md/ADR/TODO 后再动代码。
- 日志标签与旧版保持一致（`[Files]`、`[Tasks]` 等），方便对照真机日志。
