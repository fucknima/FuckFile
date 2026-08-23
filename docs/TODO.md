# TODO

状态：

- [ ] 未开始
- [~] 进行中
- [x] 完成
- [!] 阻塞

> 说明：本项目实现为 Objective-C（theos 构建，GitHub Actions 远程编译）。
> 文档中的 Swift 命名（FileItem 等）对应实现见 ARCHITECTURE.md「当前实现映射」。
>
> **范围收敛（2026-08-13）**：产品聚焦 App Data 读取。除 class-2
> （App Data）外的所有容器类别已从 MCM start 移除，浏览器只展示
> App 数据（含 FuckFile 自身沙盒）。
>
> **UI/交互改造（2026-08-13）**：
> - 多选逻辑修复（点击仅切换选中）、列表精简（图标/名称/大小/时间）
> - 首页重设计（App 数据主入口 + 快捷访问 + 设置）、导航栏「更多」菜单
> - 粘贴横幅、冲突底部 sheet（应用于后续）、空/加载/错误状态视图
> - 搜索/收藏/最近直达预览或目录、文件不可用处理
> - 任务中心：速度/ETA/失败原因/左滑重试
> - 文本编辑器未保存提示、大文件分段预览、plist 深层安全完成
> - 待办：列表/网格切换（设置页占位）、Dynamic Type/iPad 细化
>
> **文件查看体系（2026-08-22）**：
> - 新增 Viewer Registry + File Association + Preview Router 三层架构（ADR-010）
> - 打开链路收敛：文件 → FFPreviewRouter → FFFileAssociationService →
>   FFViewerRegistry → Viewer；Browser 不再堆扩展名 if/else
> - 新增 QuickLook/Web/Hex/SQLite3/ZIP 包内浏览器/IPA 安装器六个查看器，
>   图片与媒体改为 Registry 内联实现，plist/text/pdf 复用既有模块
> - 设置新增「文件查看」：支持的文件查看器 + 文件关联（覆盖/自定义/
>   删除/恢复默认，立即生效）
> - .deb 全部专用逻辑清除；无终端、无脚本执行
>
> **真机反馈修复（2026-08-22 下午）**：
> - 修复长按菜单复制/剪切/压缩后闪退：网格 flowlayout 断言
>   （非整数 item 宽度浮点越界 + 隐藏网格参与布局提交）；网格改为懒创建、
>   尺寸 floor + 极窄兜底，列表模式不再实例化 UICollectionView
> - 新增外部入口：Info.plist CFBundleDocumentTypes（public.data/content/
>   archive），AppDelegate openURL 接收文件拷贝到 Device Storage/Imported/
>   并提供「前往查看」；浏览器「更多」菜单新增「导入文件…」（文件选择器，
>   重名自动加序号，写入经路径安全策略）
> - 压缩包浏览器加固：中央目录解析失败时回退本地文件头扫描；单条目提取
>   同样支持兜底路径；空归档/结构无法解析显示明确状态行并记录日志
> - Hex 编辑器保存后作废页缓存（此前显示旧字节）
>
> **开源化改造（2026-08-22 晚，ADR-011）**：
> - ZIP 解析全面切换到 vendored minizip（third_party/minizip），
>   删除手写 EOCD/CDE/本地头扫描；真实世界归档兼容性问题由此解决
> - 长按菜单闪退根因修复：菜单收起动画期间直接 present 与转场冲突，
>   所有菜单操作统一推迟到下一轮主循环
> - 分享接收改 Inbox 模式（LSOpenInPlace=NO），冷启动立即导入，
>   解决"没有权限"与后台无文件问题
> - 导入位置统一 ~/Documents/Imported/（与 Device Storage 同级）+
>   首页「导入」快捷入口
> - 复制/剪切/移动/解压任务完成后自动刷新目标目录列表（去抖 1 秒）
> - 图片浏览器缩放、Hex 校验和、SQLite CSV 导出、IPA 安装器分级探测
>   （TrollStore 一键跳转 + LSApplicationWorkspace 尝试）
> - 待办：Hex 逐字节网格编辑、文本编辑器语法高亮（暂缓，见 ADR-011）、
>   SQLite 记录编辑
>
> **真机回归修复第二波（2026-08-22 深夜）**：
> - 压缩闪退根因实锤并修复：FFZipCreate 把含 ObjC 指针的结构体存入
>   NSValue（ARC 不 retain，取出即悬垂指针）→ 后台任务线程
>   EXC_ARM_PAC_FAIL；改为 ObjC 类管理生命周期
> - 网格视图黑屏根因并修复：collectionView 曾是 UITableViewController
>   self.view（=tableView）的子视图，被隐藏整体不可见；Browser 类改为
>   UIViewController + 自建 tableView（网格与列表成为平级兄弟视图）
> - 编辑模式禁用左滑（swipe 与底部批量栏重叠）；批量工具栏文字按钮改
>   图标（窄屏不再截断溢出）
> - 压缩包浏览器：树建不出来时降级平铺列表，不再出现"无法解析"死胡同
> - 分享接收冷启动失败：拷贝增加 4 轮指数退避重试（0/0.5/1.5/3s），
>   授权竞态下也能落盘
> - App 图标：Assets.xcassets（1024 通用 + 深色变体），CI actool 编译
>   进包并写入 CFBundleIcons
>
> **UI/UX 系统级重构（2026-08-23，ADR-013）**：
> - Navigation：全 App Inline 标题（prefersLargeTitles=NO），正文大标题移除，
>   首页/目录/设置等标题回到顶部导航栏
> - Browser：新增 FFPathBreadcrumbView 路径导航（单行、横向滚动、当前加粗、
>   上级可点）；列表信息降噪（文件夹/文件/符号链接一行式 + 相对时间）；
>   图标色彩降噪；Dynamic Type 第一批落地
> - 属性页：FFFileInfoViewController 替代 fullDetail Alert；xattr/递归统计/
>   SHA-256/MIME 移出扫描主路径，由 FFFileMetadataService 按需后台加载
> - Grid：自适应列数（2~8 列，保留 floor/极窄兜底/懒创建销毁）；「默认视图」
>   设置语义 + 浏览器「显示方式」运行时切换
> - 更多菜单/＋菜单/批量工具栏重组；搜索页统一 UISearchController；结果路径
>   缩略显示；任务中心排版分层；设置重分组（默认视图/文件夹优先/存储与缓存）
> - Share Extension 仅状态标签视觉统一，导入逻辑零改动
> - 待办：真机回归矩阵（见下）、10k 文件性能实测、极端 Dynamic Type 字号验证
>
> **外部分享架构重做（2026-08-23，ADR-012）**：
> - 真机 A/B 已确认“文件类型”不是主变量：微信 PDF 可经 openURL 导入，
>   Files PDF 与 LCSign IPA/ZIP 只唤起主 App且没有 Import 回调。
> - 逆向核对 LCSign-1.2-8.ipa：其主 App 使用
>   UIFileSharingEnabled=YES + UISupportsDocumentBrowser=YES +
>   LSSupportsOpeningDocumentsInPlace=NO，并内嵌标准 LCShareExtension.appex。
> - 新增 FuckFileShare.appex：share-services + FileWithMaxCount=25，
>   NSItemProvider 的文件 representation 在 completion 内立即持久化，禁止
>   把临时 URL 留给主 App。
> - 新增 FFSharedInboxService + FFImportService：共享条目先以
>   .partial-UUID 写 payload/metadata，完成后 rename；主 App staging + 原子
>   commit 到 Device Storage/Imported，同名自动加序号。
> - 重签兼容不再押注 App Group：若 App Group 可用则使用；否则 Extension
>   写自身 Documents，主 App 通过 MobileHouseArrest MCM class-4 Extension
>   Data 访问 PluginKitPlugin 数据容器并消费共享收件箱。
> - GitHub Actions 已要求真实构建/嵌入 FuckFileShare.appex、验证 LC_MAIN、
>   nested extension 先签/main app 后签，并 codesign --verify --deep --strict。
> - [ ] 最终真机验收：Files PDF、LCSign IPA、LCSign ZIP 各测一次；微信 PDF
>   作为 openURL 回归。CI 通过不等于真机 Share Extension 已验证。

## P0 架构初始化

- [x] 建立 FileItem（FFEntry：name/path/type/size/日期/isDirectory/isSymlink/detail）
- [~] 建立 StorageProvider（Local 直连已工作，Protocol 抽象留待网络功能前完成）
- [~] 建立 LocalStorageProvider（功能等价于 Local 直连，无正式 Protocol 层）
- [~] 建立统一 FileError（统一使用 NSError，无自定义错误枚举）
- [~] 建立 FileOperationService（FFCopyEngine 覆盖复制；rename/delete 仍散落在 View 层）
- [x] 建立 FFImportService（staging、原子提交、security scope/coordinator 外部读取）
- [x] 建立 Share Extension + FFSharedInboxService（Share Sheet 与 Document Open 双入口）
- [x] 建立 signer-independent class-4 Extension Data fallback（App Group 不作为唯一依赖）
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
- [~] 外部分享导入：代码/CI 已完成，等待一次最终真机验收矩阵

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

- [x] FileTask（kind/state/progress/cancel 模型）
- [x] FileTaskManager（串行队列、有界历史、状态通知）
- [x] 任务队列（首页「任务中心」入口 + FFTasksViewController）
- [x] 文件复制进度（递归预扫描 + 逐块回调）
- [x] 总进度（多文件合计字节比例）
- [x] Cancel（文件级取消 + 解压条目级取消）
- [x] 失败任务（failed 状态 + 错误记录）
- [~] Retry（失败任务可重投递，UI 入口待补）

## P1 Preview

- [x] PreviewRouter（关联→Registry→fallback，Browser/Search/Favorites/Recents 共用）
- [x] 图片
- [x] 视频
- [x] 音频
- [x] 文本
- [x] PDF（PDFKit：连续滚动、缩略图侧栏、分享、失败反馈）
- [x] JSON（文本编辑）
- [x] plist（结构化编辑器）
- [x] Quick Look Viewer（系统 QLPreviewController，fallback 链一环）
- [x] Web Viewer（WKWebView；本地 HTML read-access 限定所在目录；.url/.webloc 解析）
- [x] Hex 编辑器（pread 分页 64KB、OFFSET/HEX/ASCII、偏移跳转、内存 patch、保存经路径安全策略、失败回滚、取消修改）
- [x] SQLite3 编辑器（只读：库信息/表/视图/索引/schema/分页浏览/SQL 查询/busy·locked·malformed 错误反馈）

## P1 文件关联（2026-08-22 完成）

- [x] FFViewerRegistry（viewer ID/名称/图标/可用状态/open 分发唯一来源）
- [x] FFFileAssociationService（内置默认表在代码 + NSUserDefaults override）
- [x] 最长后缀优先匹配（backup.tar.gz → .tar.gz → .gz）、大小写不敏感、前导点规范化
- [x] 用户覆盖 / 自定义扩展名 / 删除覆盖项 / 恢复默认
- [x] 升级新增默认格式不覆盖用户选择
- [x] 修改立即生效（实时读取，无需重启）
- [x] 设置页「文件查看」section：支持的文件查看器 / 文件关联两个管理页
- [x] 长按菜单「用其他查看器打开」「浏览压缩包」「安装」（按能力显示）
- [x] 默认关联全量落地（text/plist/sqlite/image/media/web/hex/ipa/archive/pdf）
- [x] .deb 清理：不注册关联、不进 ZIP 浏览器、不交安装器，删除既有当 ZIP 的判断
- [x] 不支持格式诚实提示（tar/gz/7z/rar/xz/bz2「当前构建暂不支持」）
- [ ] SQLite 记录编辑（BEGIN/COMMIT/ROLLBACK 事务）
- [ ] Archive 统一 Backend 抽象（为 7z/RAR/XZ/BZ2/TAR 后端接入预留）
- [ ] IPA 安装后端（需越狱环境 installd/opainstaller；当前如实提示不可用原因）

## P1 缩略图

- [x] ThumbnailService（串行生成队列 + 请求合并）
- [x] 图片缩略图（CGImageSource 降采样）
- [x] 视频缩略图（AVAssetImageGenerator）
- [x] PDF缩略图（PDFKit：首页渲染）
- [x] Memory Cache（NSCache，600 项 / 48MB）
- [x] Disk Cache（Caches/Thumbnails，SHA1 key）
- [x] Cache Cleanup（日志页「清缓存」+ clearCaches API）

## P1 搜索

- [x] 当前目录搜索
- [x] 递归搜索（全局搜索页，DFS + 分批 + 取消）
- [x] 名称搜索
- [x] 文件类型筛选（工具栏筛选菜单）
- [ ] 大小筛选
- [ ] 日期筛选
- [x] 搜索历史（NSUserDefaults 持久化，点击重搜，可清空）

## P2 收藏

- [x] 收藏文件夹
- [x] 收藏文件
- [x] 收藏页面（首页「收藏」）
- [x] 取消收藏（长按菜单切换 + 左滑删除）

## P2 最近访问

- [x] 最近文件
- [x] 最近目录
- [x] 最近打开时间
- [x] 清理历史（「清空」按钮）

## P2 Archive

- [x] ZIP识别
- [x] ZIP解压（FFZipExtract，store+deflate，入口消毒，写保护回退）
- [x] ZIP压缩（FFZipCreate：store/deflate 自适应、递归、UTF-8）
- [x] 解压进度（字节比例 + 条目名，接入任务中心）
- [x] 压缩进度（字节比例 + 条目名，接入任务中心）
- [x] 压缩异常处理（失败清理半成品、取消、错误上报）
- [x] ZIP 包内浏览器（FFArchiveService 中央目录列表 + FFArchiveBrowserViewController：
      目录树浏览、文件属性、单文件预览复用 PreviewRouter、单条目提取、
      选中项提取、全部解压接入任务中心；ipa 同样支持）
- [ ] 7z/RAR/XZ/BZ2/TAR 解析后端（当前明确提示暂不支持）

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
