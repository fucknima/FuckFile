# TODO

状态：

- [ ] 未开始
- [~] 进行中
- [x] 完成
- [!] 阻塞

> 说明：本项目实现为 Objective-C（theos 构建，GitHub Actions 远程编译）。
> 文档中的 Swift 命名（FileItem 等）对应实现见 ARCHITECTURE.md「当前实现映射」。

## P0 架构初始化

- [x] 建立 FileItem（FFEntry：name/path/type/size/日期/isDirectory/isSymlink/detail）
- [~] 建立 StorageProvider（Local 直连已工作，Protocol 抽象留待网络功能前完成）
- [~] 建立 LocalStorageProvider（功能等价于 Local 直连，无正式 Protocol 层）
- [~] 建立统一 FileError（统一使用 NSError，无自定义错误枚举）
- [~] 建立 FileOperationService（FFCopyEngine 覆盖复制；rename/delete 仍散落在 View 层）
- [x] 建立 Logger（FFLogger：时间戳、模块 tag、文件持久化、线程安全）
- [x] 建立基本项目目录结构（src/ 平铺 + 模块文件）

## P0 文件浏览

- [x] 获取目录内容（loadDirectoryContents，dirent 直读）
- [~] FileBrowserViewModel（FFBrowserViewController 内含逻辑，无独立 VM）
- [x] 文件列表
- [x] 文件夹进入
- [x] 返回上级
- [~] 空目录状态（显示空列表，无专门空态插图）
- [x] Loading 状态（loading 标志 + 下拉刷新）
- [x] Error 状态（presentLoadError 弹窗）
- [x] 文件类型识别（kindName + 扩展名图标映射）
- [x] 系统文件图标（SF Symbols 按扩展名分类）
- [x] 文件大小格式化
- [x] 日期格式化
- [x] 显示隐藏文件（默认显示，无开关）
- [x] 文件数量显示（dir scan 统计日志 + 列表）

## P0 排序

- [x] 名称
- [x] 大小
- [x] 日期
- [x] 类型
- [x] 升序/降序
- [x] 文件夹优先

## P0 筛选

- [x] 全部/图片/视频/音频/文档/压缩包/代码（工具栏筛选菜单）
- [x] 与搜索文本叠加过滤

## P0 文件操作

- [x] 新建文件夹
- [x] 新建文件
- [x] 重命名
- [x] 删除
- [x] 删除确认
- [x] 复制
- [x] 移动（剪切+粘贴）
- [x] Duplicate（创建副本）

## P0 多选

- [x] 进入多选
- [x] 单个选择
- [x] 全选
- [x] 取消选择（退出多选）
- [x] 批量删除
- [x] 批量复制
- [x] 批量移动（剪切）
- [x] 批量分享

## P1 文件冲突

- [x] 文件已存在检测
- [x] Replace
- [x] Skip
- [x] Keep Both（自动重命名）
- [x] Apply to All（全部替换 / 全部跳过）
- [x] 自动生成新文件名（" name copy" / " copy 2" …）

## P1 文件任务

- [ ] FileTask
- [ ] FileTaskManager
- [ ] 任务队列
- [ ] 文件复制进度
- [ ] 总进度
- [ ] Cancel
- [ ] 失败任务
- [ ] Retry

## P1 Preview

- [~] PreviewRouter（previewEntry 内联路由，未抽象）
- [x] 图片
- [x] 视频
- [x] 音频
- [x] 文本
- [ ] PDF
- [x] JSON（文本编辑）
- [x] plist（结构化编辑器）

## P1 缩略图

- [ ] ThumbnailService
- [ ] 图片缩略图
- [ ] 视频缩略图
- [ ] PDF缩略图
- [ ] Memory Cache
- [ ] Disk Cache
- [ ] Cache Cleanup

## P1 搜索

- [x] 当前目录搜索
- [ ] 递归搜索
- [x] 名称搜索
- [x] 文件类型筛选（工具栏筛选菜单）
- [ ] 大小筛选
- [ ] 日期筛选
- [ ] 搜索历史

## P2 收藏

- [ ] 收藏文件夹
- [ ] 收藏文件
- [ ] 收藏页面
- [ ] 取消收藏

## P2 最近访问

- [ ] 最近文件
- [ ] 最近目录
- [ ] 最近打开时间
- [ ] 清理历史

## P2 Archive

- [x] ZIP识别
- [x] ZIP解压（FFZipExtract，store+deflate，入口消毒，写保护回退）
- [ ] ZIP压缩
- [ ] 解压进度
- [ ] 压缩进度
- [~] 压缩异常处理（错误弹窗已实现，进度/取消未实现）

## P3 Network

- [ ] 验证 StorageProvider 抽象
- [ ] 网络服务器数据模型
- [ ] 添加服务器界面
- [ ] SMB
- [ ] WebDAV
- [ ] SFTP
- [ ] 网络断线处理
- [ ] 网络任务恢复

## P4 优化

- [ ] 1000 文件目录测试
- [ ] 10000 文件目录测试
- [ ] 超大文件复制
- [ ] 内存检测
- [ ] CPU检测
- [ ] 快速滚动测试
- [ ] Thumbnail 性能
- [ ] 文件任务并发限制
