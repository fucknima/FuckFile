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
