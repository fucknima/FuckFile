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
