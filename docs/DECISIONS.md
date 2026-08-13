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
