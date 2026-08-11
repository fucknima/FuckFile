# FuckFile

Jailed（非越狱）iOS 容器文件管理器，构建在 MobileContainerManager 身份信任绕过之上。
MCM 层移植自 [0xjohnnydev/FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop)（MCMBridge + MCM 激活/枚举逻辑），UI 为自研。

> **研究用途。** 本质是利用 containermanagerd 的签名身份信任缺陷（MobileHouseArrest
> identity-trust bypass）获取其他 App 容器的沙箱扩展。这是系统设计缺陷，Apple 可能
> 随时修复。仅限在自己设备上自签使用，请勿分发。

## 原理

- 整个 App 必须重签为 `com.apple.mobile.MobileHouseArrest`（见 `Info.plist`），
  containermanagerd 信任该 caller 身份，为任意 App 容器签发 sandbox extension。
- 运行时 `dlopen("/usr/lib/system/libsystem_containermanager.dylib")` 调私有 C API：
  `container_query_*` / `container_object_*` / `container_copy_sandbox_token`，
  激活租约后当前进程获得目标容器路径访问权。
- 每次启动枚举容器 class 2/4/6/7/10/12/13/15，在
  `Documents/Device Storage/` 下建 symlink 虚拟根：
  `[MHA-C2] App Data`、`[MHA-C7] App Groups`、`[MHA-C4] Extension Data`、
  `[MHA-C6] VPN Data`、`[MHA-C10] Service Data`、`[MHA-C12] System Data`、
  `[MHA-C13] System Groups`、`[MHA-C15] Protected Data`、
  `[MHA-C13 Scoped] Additional Locations`、`[MHA-Mixed EXP] Experimental`。
- 权限边界：容器级。无 root、无 /var/mobile、无 Keychain、无 TCC、无 App bundle。
  进入容器后仍受 Data Protection 与 DAC（owner/mode）限制。

## 功能

- 首页仪表盘：存储/探针/工具状态一目了然，一键进入各功能区
- 现代文件浏览器（UIKit + SF Symbols）：
  - 文件夹/图片/视频/音频/压缩包/plist/数据库等类型图标与配色
  - 长按上下文菜单、左滑操作（删除/更多）
  - 搜索过滤、按名称/大小/修改时间排序
  - 新建文件夹 / 新建文件 / 下拉刷新
- 复制 / 剪切 / 粘贴（进程内剪贴板，跨容器可用，禁止粘贴进自身）
- 删除（确认）、重命名、分享（系统分享面板）、属性（mode/uid/gid/时间/xattr）
- 预览：图片 / 视频 / 音频（AVKit）、plist / 文本 / 二进制 hexdump（1 MB 上限）
- 下拉刷新；启动与操作日志输出到系统日志（`[FuckFile]`）
- 每次启动生成 `Device Storage/ACCESS MAP.txt` 记录各 class 查询结果

## 排障日志

所有关键步骤（bundle id 校验、MCM bridge 加载、每个 class 的 identifier 枚举、
每个容器的 lease 激活/符号链接结果、scoped 探测、bad_query 每一步）都会追加写入：

```text
Documents/Device Storage/FuckFile Log.txt
```

bad_query 的详细分步日志另存于：

```text
Documents/Device Storage/BadQuery Probe Log.txt
```

开启文件共享（`UIFileSharingEnabled`）后，可通过 文件 App →
“我的 iPhone → FuckFile → Device Storage” 直接导出这两个 txt。

## iOS 26.6 兼容

- 界面已全部中文化。
- 当 canonical bad_query flags（`0x0000008000000000`）在 26.6 上被 token
  签发拦截时，App 会自动回退到“变体矩阵”验证过的 class-13 组合
  （group × flags × part × traversal，共 64 种，遍历优先），消费第一个
  成功签发 token 的组合，再执行 `bad_query_list` 容器枚举。
- 探针结果 plist 会记录 `VariantMatrix`，控制台可查看 64 种组合中哪些
  能签发 token（日志里显示为 `TOKEN-OK`）。

## bad_query 探针（iOS 26.x）

内置 [forcequitOS/bad_query](https://github.com/forcequitOS/bad_query) 的 C 实现
（`src/BadQuery.c`），启动时自动对全部目标路径执行探针，**每一步**（dlopen、
每个符号解析、query 组装、containermanagerd 回包、token 消费、access/open/
readdir 验证）都记录到：

- `Device Storage/BadQuery Probe Log.txt`（分步、带时间戳、可连续追加）
- `Device Storage/BadQuery Probe Results.plist`（结构化结果）
- 系统日志 `[BadQueryProbe]` 前缀

探针成功的路径会被 symlink 到 `Device Storage/[BadQuery] Escaped/`，可直接浏览。

内置 **bad_query 控制台**（首页 → Probe Console）：

- 查看结构化探针结果与分步日志
- 一键重跑全部探针
- 对任意绝对路径执行 `bad_query` 消费/释放 sandbox extension
- **容器映射**：一键用 `bad_query_list` 枚举 App Data / InternalDaemon /
  PluginKitPlugin / App Groups / System Groups，读取容器 metadata 把 UUID
  反查成 bundle id，并以 bundle id 命名 symlink 到
  `Device Storage/[BadQuery] Escaped/<分类>/`，可直接浏览其他 App 的
  Documents/Library/tmp
- 在控制台填写 **App Group sacrifice**（你签名时拥有的 group id），保存后重跑
  即可在 iOS 26 上访问 App Group
- 探针日志已修复为完整追加（旧版只保留最后一行）

## MobileGestalt 编辑器（iOS 26+）

移植自 [rooootdev/mond](https://github.com/rooootdev/mond) 的核心功能，通过 MCM
scoped 路由（class 13 part 3 或 class 12 part-domain 回退）直接读写
`com.apple.MobileGestalt.plist`：

- 首次打开自动备份原 plist（`Documents/MobileGestalt Backup/SavedGestalt.plist`）
- 常用开关：灵动岛、全天候显示、充电上限、开机提示音、相机控制、操作按钮、
  车祸检测、轻点唤醒、Apple Intelligence、内部存储、Metal HUD、区域限制等
- 设备外观：ArtworkDeviceSubType 预设（iPhone 14 Pro / 15 Pro Max / 16 Pro 等）
- 设备型号 spoof（Apple Intelligence 资格），自定义设备名
- Apply 使用临时文件 + 原子替换，Revert 恢复首次备份

> **警告：改坏 MobileGestalt 可能软砖。空 plist 或非法 plist 时切勿重启，先 Revert。**

## Wallpaper Lab（PosterBoard）

移植自 FilzaSlop 的 `PosterBoardFeature`：

- 首页 → Wallpaper Lab（或直接浏览 `[MHA-C2] Wallpaper Lab`）
- 在 Lab 根目录点导航栏 **Wallpaper**：检查 PosterBoard 结构、导入 `.tendies`
  描述符包、回滚最近一次导入
- 把解包后的描述符包放入 `[MHA-C2] Wallpaper Lab/Imports/`
- 导入只新增 UUID 描述符目录，不覆盖 PosterBoard 数据库；刷新偏好会先备份，
  回滚前校验 SHA-256

> 本仓库未捆绑 Cipher 示例壁纸；需要时自行放置到 Imports。

iOS 26 上访问 App Group 需要"App Group sacrifice"：把你自己签名时带的
App Group id 写进 `Documents/AppGroupSacrifice.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>GroupId</key><string>group.your.own.group</string>
</dict></plist>
```

签名时（zsign/爱思）注入对应 entitlement：

```xml
<key>com.apple.security.application-groups</key>
<array><string>group.your.own.group</string></array>
```

## 构建（GitHub Actions）

仓库 push 自动构建并上传未签名 `FuckFile.ipa`（ad-hoc 签名，需自行重签安装，
如 zsign / 爱思助手 / TrollStore 等方式）。

## 本机构建

```sh
export THEOS=$HOME/theos
make clean
make FINALPACKAGE=1
```

## 已知限制

- 改 bundle id 即失效（MCM 激活前有硬校验，fail-closed）。
- 部分 class 查询随 iOS 版本收紧：Experimental 目录内链接失败属正常，见
  `Probe Results.plist`。
- 可配置目标清单：放 `Documents/MCMIdentifiers.plist`（格式见仓库根示例），
  或在 `src/MCMManager.m` 的 fallback 列表里加 identifier。
- zsign 重签时保持 bundle id 为 `com.apple.mobile.MobileHouseArrest`（MCM 路径
  的硬性要求）；bad_query 探针本身对身份无要求，即使改 bundle id 也能测。

## Credits

- MCM 机制与实现：0xjohnnydev/FilzaSlop（及其上游 FilzaJailedDS / MCM 研究成果）
- bad_query 沙箱逃逸：forcequitOS/bad_query（Taj C）
- MobileGestalt 编辑器概念与键位：rooootdev/mond
