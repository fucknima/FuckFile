# Architecture Decision Records

## ADR-001

日期：项目初始化

决定：

所有存储位置统一实现 StorageProvider。

原因：

未来需要支持 Local、SMB、WebDAV、SFTP。

UI 不应该根据存储类型写不同逻辑。

## ADR-002

决定：

所有复制、移动、删除、压缩等文件操作通过 Service 层执行。

禁止 View 直接实现复杂文件操作。

原因：

便于：

- 进度管理
- 错误处理
- 取消
- 测试
- 网络 Provider 扩展

## ADR-003

决定：

长耗时文件操作统一进入 FileTaskManager。

原因：

后期必须支持：

- 多任务
- 进度
- Cancel
- Retry
- 网络传输

## ADR-004

决定：

文件浏览统一使用 FileItem。

Local、SMB、WebDAV、SFTP 不建立互不兼容的 UI Model。

## ADR-005

决定：

第一阶段优先完成文件管理核心。

暂时不追求大量高级功能。

优先级：

稳定性 > 数据安全 > 性能 > 功能数量 > 动画效果

## ADR-006

日期：2026-08-13

决定：

项目实现语言保持 Objective-C（theos 构建，GitHub Actions 远程编译），
文档中的 Swift 命名（FileItem / StorageProvider / ViewModel）作为
架构方向的映射目标，不要求立即迁移。

原因：

- 现有成熟代码（MHA 沙盒逃逸文件访问、容器枚举、App 显示名解析、
  plist/文本编辑、ZIP 解压、多选批量操作等）已正常稳定工作，全部
  以 Objective-C 实现。迁移成本远高于收益。
- 本机环境为 Linux，无 macOS/Xcode，编译验证依赖 GitHub Actions；
  Objective-C + theos 的构建链路已验证稳定。
- 文档架构原则（UI 不直接操作文件系统、Service 层、统一模型）在
  ObjC 中同样适用：FFEntry 对应 FileItem，FFCopyEngine/FFZipExtract
  已体现 Service 层，后续新增能力（冲突系统、任务中心、网络）一律
  遵循该原则实现。

后续重大重构（如引入 Protocol StorageProvider、Swift 迁移）必须
先更新本 ADR 再执行。

## ADR-007

日期：2026-08-13

决定：

文件冲突处理从 P0 收尾后进入 P1 第一优先。

原因：

复制/移动遇到同名文件时当前行为是静默自动重命名，虽不丢数据但
不符合"任何可能造成数据丢失的行为不得静默执行"的产品原则。
在任务中心之前实现冲突系统，因为冲突策略是复制/移动语义的
一部分，任务系统只是执行载体。

## ADR-008

日期：2026-08-13

决定：

V0.4（压缩与编辑）完成后，跳过 V0.5（网络文件：SMB/WebDAV/SFTP），
先实现 V0.6 中无第三方依赖的能力（存储分析、文件分类、大文件查找、
重复文件查找、回收站）。

原因：

- SMB/SFTP 需要第三方协议库（AMSMB2 / libssh2），在当前 theos +
  无依赖构建链中需要交叉编译静态库，工程复杂度高。
- WebDAV 可用 NSURLSession 自实现，但浏览/上传/下载/断线恢复的
  完整实现量大，收益需要 StorageProvider 抽象先行。
- V0.6 的本地能力全部基于已有原语（目录遍历、SHA-256、任务中心），
  无需新依赖，能保持"稳定性 > 数据安全 > 功能数量"的节奏。

网络功能待 StorageProvider 抽象与协议库方案确定后重新排期。

## ADR-009

日期：2026-08-13

决定：

回退 9507bca（「App names: extract third-party display names from the LS csstore」），
移除 FFLSDiscoverAppNames 与 FFAppNamesRegisterStoreNames 整条链路。

原因：

- 该实现直接对 com.apple.LaunchServices-*-v2.csstore 二进制做字节扫描，
  在每个 bundle id 后的 256 字节窗口内取"第一个看起来像名字"的字节串作为显示名。
- csstore 中 id 之后是二进制偏移/长度表，抓到的多为无关字节片段，
  导致 App Data 列表中大量显示名变成乱码（如 `R%b`、
  `(UNDaemonShouldReceiveBackgroundResponses^UNHideSettings_`、
  `!"#$%$$2$$+_`、`!QdQfQcS1.6`），且配对本身不可靠（英文单词同样可能配错）。
- 日志佐证：`name extraction complete entries=18583`，19k 条"名字"几乎全是噪声，
  说明启发式过滤（FFLSPlausibleName）基本无效。
- 显示名解析链恢复为：静态映射 → LSApplicationWorkspace → iTunesMetadata
  itemName → bundle id 兜底。第三方应用名待后续用正式 API 方案再补。

## ADR-009

日期：2026-08-13

决定：

按代码审查意见完成一轮安全/架构加固：

1. 所有文件变更操作（创建/重命名/删除/批量删除）统一走
   FFFileOperationService（openat + O_NOFOLLOW 逐级验证父链，
   App Data 链接显式解析并复验目标，最终条目相对父 fd 校验），
   不再直接调用 NSFileManager 做变更。
2. ZIP 解压加固：预扫描限制条目数（10 万）与解压后体积（4 GiB）
   防 ZIP 炸弹；逐文件 CRC32 校验；解压先写临时目录、成功后再
   rename 提交，失败/取消自动清理。
3. rescan 改为专用串行队列 + 完成回调（LS 异步确认结束后触发），
   修复日志页"立即发完成通知但扫描未结束"的时序 bug。
4. FFLogger：串行队列（NSDateFormatter 在队列内）、1 MiB 轮转
   （归档 .old.txt）、写入前对容器 UUID 脱敏（保留前 8 位）并
   规范化 /private/var 前缀。
5. CI 固定 actions/checkout（v4.3.0）、upload-artifact（v4.6.2）、
   theos（5280bd03）与 ldid（Procursus v2.1.5-procursus7 release
   二进制）；codesign 不再用 `|| true` 吞错。

日志位置维持 Documents/Device Storage（产品要求与 App Data 同目录），
以脱敏 + 轮转控制敏感信息与体积，不再单独迁移目录。

## ADR-010

日期：2026-08-22

决定：

文件查看体系采用「Viewer Registry + File Association + Preview Router」
三层架构，并一次性接入全部查看器：

1. `FFViewerRegistry` 统一管理 viewer ID / 显示名 / 图标 / 可用状态 /
   open 分发；任何页面不得绕过 Registry 推入查看器。
2. `FFFileAssociationService` 内置默认关联表写在代码中，用户修改只存
   NSUserDefaults override；支持自定义扩展名、删除覆盖、恢复默认；
   匹配为最长后缀优先 + 大小写不敏感 + 前导点规范化。
3. `FFPreviewRouter` 收敛为：用户覆盖 → 内置默认 → 可用性检查与打开 →
   内容检测 fallback（plist 嗅探 → 文本嗅探 → Quick Look → Hex）。
   Browser/Search/Favorites/Recents 共用该 Router。
4. 新增 Viewer：QuickLook（系统 QLPreviewController）、Web（WKWebView，
   本地 HTML read-access 根限定在文件所在目录，解析 .url/.webloc）、
   SQLite3（系统 sqlite3 只读浏览与查询）、Hex（pread 分页 64KB +
   内存 patch + FFPathPolicy 校验写回 + 失败回滚）、ZIP 包内浏览器
   （中央目录解析、单条目提取、选中提取、全部解压复用任务中心）、
   IPA 安装器（解析应用信息；安装按真实环境如实反馈）。
5. `.deb` 完全排除：不注册专用关联、不进 ZIP 浏览器、不交安装器，
   并清理了既有代码把 .deb 当 ZIP/归档的判断。不实现终端，脚本类
   扩展名仅按文本打开。

原因：

- 避免扩展名判断散落在 Browser 各处（此前 previewEntry 内联路由已
  开始重新堆积 images/videos/pdf 的 if/else）。
- 支持用户自定义关联且立即生效；升级新增默认格式不覆盖用户选择。
- Viewer 可扩展：新格式只需注册一个 ID 与实现，Router/UI 不改。
- Search/Favorites/Recents/Browser 四个入口天然共享同一打开链路与
  fallback，不再各自维护预览逻辑。
- 不支持的格式（TAR/GZ/7z/RAR/XZ/BZ2 无解析后端）明确显示「暂不支持/
  部分支持」，禁止拿 ZIP 解析器硬解或伪装成功。

限制记录：

- IPA 安装在免越狱容器环境无 installd 后端，安装按钮如实说明原因，
  提供 ZIP 浏览/分享/解压替代路径。
- SQLite 编辑器第一版只读（浏览+查询），记录编辑待后续带事务实现。
- Hex 编辑器按行编辑字节（每行 16 字节），保存前全部驻留内存 patch，
  写回失败时用缓存原值回滚，保证不留半修改状态。

## ADR-011

日期：2026-08-22

决定：

格式解析类代码一律优先采用经过实战检验的开源实现，禁止手写解析器。
本次将 ZIP 解析（列表 + 单条目提取 + 全量解压）切换到 vendor 进仓库的
minizip（third_party/minizip，zlib License，来源 madler/zlib contrib），
删除全部手写 EOCD/CDE/本地头扫描代码。Makefile 直接编译其 .c 文件。

原因：

- 手写 EOCD/CDE 解析器在真实世界归档上暴露兼容性问题：用户实测
  Actions artifact zip 显示"无法解析包内结构"。这类边界（数据描述符、
  非标准 extra 字段、ZIP64、编码变体）minizip 已处理了二十余年。
- zlib 已是现有依赖，minizip 是纯 C、零新依赖，theos 构建链无改动成本。
- 此前未采用现成库的理由（担心交叉编译验证拖慢交付）不成立——
  实际引入只花了两个 commit；而手写解析器的缺陷修复成本远高于此。
- 安全规则保留在 minizip 之上：条目数上限、单条目体积上限、文件名消毒、
  符号链接与加密条目拒绝、CRC 校验（unzCloseCurrentFile）、临时目录 +
  rename 原子提交。

同类决策：

- 图片浏览器缩放采用 PhotoScroller 模式（UIScrollView + viewForZooming）
- Hex 编辑器补 GOTO/CRC32/SHA-256 校验和（开源十六进制编辑器的通用能力集）
- SQLite 保持系统 sqlite3；CSV 导出为通用能力补充
- 文本编辑器语法高亮暂缓：ObjC/theos 下无轻量成熟方案，正则高亮收益低
  且有性能风险，待有合适组件再评估

后续新增任何格式支持（7z/RAR/TAR 等）必须同样先找成熟开源后端。

## ADR-012

日期：2026-08-23

决定：

外部文件进入采用「Document Open + Share Extension」双系统入口，并以
LCSign 1.2-8 的实际 IPA 结构作为已验证参考，而不是继续假设所有发送方
都会触发 `application:openURL:options:`。

1. Document Open 保留 `CFBundleDocumentTypes` + AppDelegate `openURL`；
   Files 配置固定为 `UIFileSharingEnabled=YES`、`UISupportsDocumentBrowser=YES`、
   `LSSupportsOpeningDocumentsInPlace=NO`、`LSHandlerRank=Default`，与 LCSign
   的最终 IPA 配置一致。Open In 目标是让系统优先交付 App 自己 Inbox 中
   的稳定副本，而不是依赖其他 App 私有容器的短期 URL。
2. Share Sheet 新增 `FuckFileShare.appex`，使用标准 `com.apple.share-services`
   extension point，`NSExtensionActivationSupportsFileWithMaxCount=25`；读取
   `NSExtensionItem` / `NSItemProvider`，使用 `registeredTypeIdentifiers` 与
   `loadFileRepresentationForTypeIdentifier:completionHandler:`。
3. NSItemProvider 给出的 representation 必须在 completion handler 存活期间
   立即持久化。Extension 先写 `.partial-UUID/payload + metadata.plist`，完整后
   rename 为 `UUID.ffshare`；禁止保存 provider 临时路径后让主 App 再读。
4. App Group 只作为可选桥梁，不作为正确性前提。历史实验已证明第三方
   重签工具可能剥离/拒绝 App Group entitlement。若 App Group 不可用，Share
   Extension 写入自身 Extension Data 容器；主 App 利用既有
   `com.apple.mobile.MobileHouseArrest` MCM 身份，通过 class 4（Extension Data）
   直接取得 `FuckFileShare` 的 PluginKitPlugin 数据容器并消费收件箱。
5. 主 App 统一由 `FFSharedInboxService` 扫描 App Group 与 class-4 fallback，
   再交给 `FFImportService`。成功后删除共享条目；失败保留，避免数据丢失。
6. `FFImportService` 统一 staging/原子提交/重名命名。稳定本地/MCM lease 路径
   直接流式复制；真正的外部 URL 使用 security scope + `NSFileCoordinator`，
   copy 必须发生在 coordinator accessor 内。
7. CI 必须真正构建 MH_EXECUTE `.appex`、验证 `LC_MAIN`、嵌入
   `FuckFile.app/PlugIns/FuckFileShare.appex`、先签 nested extension 后签主 App，
   并执行 `codesign --verify --deep --strict`。构建成功不能只代表主 App 成功。

依据：

- 真机 A/B：微信 PDF 能进入现有 openURL 管线；系统 Files PDF 与 LCSign
  IPA/ZIP 仅唤起主 App且没有 Import 回调日志，证明发送方通道不同。
- 对 LCSign-1.2-8.ipa 的实际检查确认：主 App 配置为 Files sharing +
  Document Browser + OpenInPlace=NO；包内存在 `LCShareExtension.appex`；其
  extension manifest 为 `com.apple.share-services`、FileWithMaxCount=25，二进制
  引用了 NSItemProvider 的 registered types / loadFileRepresentation / loadItem、
  文件复制与共享容器 API。
- FilzaSlop 的 MobileContainerManager 实现明确映射 class 4 为 Extension Data，
  并以 class-4 identifier 获取 `/var/mobile/Containers/Data/PluginKitPlugin`
  类型容器。FuckFile 已经依赖同一 MHA-MCM 基础设施，因此可把它用作不依赖
  App Group provisioning 的稳定桥梁。

边界：

- CI 可以证明编译、Mach-O entry point、嵌入结构和嵌套签名正确；只有真机
  能最终证明具体 iOS/重签器组合下 Share Extension 被系统加载以及 class-4
  bridge 的运行时授权。未做真机验证前不得把该项写成“已完全验证”。
