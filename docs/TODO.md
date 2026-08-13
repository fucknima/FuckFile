# TODO

状态：

- [ ] 未开始
- [~] 进行中
- [x] 完成
- [!] 阻塞

## P0 架构初始化

- [ ] 建立 FileItem
- [ ] 建立 StorageProvider
- [ ] 建立 LocalStorageProvider
- [ ] 建立统一 FileError
- [ ] 建立 FileOperationService
- [ ] 建立 Logger
- [ ] 建立基本项目目录结构

## P0 文件浏览

- [ ] 获取目录内容
- [ ] FileBrowserViewModel
- [ ] 文件列表
- [ ] 文件夹进入
- [ ] 返回上级
- [ ] 空目录状态
- [ ] Loading 状态
- [ ] Error 状态
- [ ] 文件类型识别
- [ ] 系统文件图标
- [ ] 文件大小格式化
- [ ] 日期格式化

## P0 排序

- [ ] 名称
- [ ] 大小
- [ ] 日期
- [ ] 类型
- [ ] 升序/降序
- [ ] 文件夹优先

## P0 文件操作

- [ ] 新建文件夹
- [ ] 重命名
- [ ] 删除
- [ ] 删除确认
- [ ] 复制
- [ ] 移动
- [ ] Duplicate

## P0 多选

- [ ] 进入多选
- [ ] 单个选择
- [ ] 全选
- [ ] 取消选择
- [ ] 批量删除
- [ ] 批量复制
- [ ] 批量移动
- [ ] 批量分享

## P1 文件冲突

- [ ] 文件已存在检测
- [ ] Replace
- [ ] Skip
- [ ] Keep Both
- [ ] Apply to All
- [ ] 自动生成新文件名

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

- [ ] PreviewRouter
- [ ] 图片
- [ ] 视频
- [ ] 音频
- [ ] 文本
- [ ] PDF
- [ ] JSON
- [ ] plist

## P1 缩略图

- [ ] ThumbnailService
- [ ] 图片缩略图
- [ ] 视频缩略图
- [ ] PDF缩略图
- [ ] Memory Cache
- [ ] Disk Cache
- [ ] Cache Cleanup

## P1 搜索

- [ ] 当前目录搜索
- [ ] 递归搜索
- [ ] 名称搜索
- [ ] 文件类型筛选
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

- [ ] ZIP识别
- [ ] ZIP解压
- [ ] ZIP压缩
- [ ] 解压进度
- [ ] 压缩进度
- [ ] 压缩异常处理

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
