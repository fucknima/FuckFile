# FuckFile

Jailed（非越狱）iOS 容器文件管理器，面向 iOS 26.x。构建在两类沙盒逃逸之上：

- **MCM**：MobileContainerManager 身份信任绕过（移植自 [0xjohnnydev/FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop)）。
- **bad_query**：containermanagerd 查询逃逸（移植自 [forcequitOS/bad_query](https://github.com/forcequitOS/bad_query)），带 64 组变体矩阵回退。
- MobileGestalt 编辑器参考 [rooootdev/mond](https://github.com/rooootdev/mond)。

> 研究用途：利用 containermanagerd 的身份信任缺陷获取其它 App 容器的沙盒扩展。
> 这是系统设计缺陷，Apple 可能随时修补。仅限在自己设备上使用，请勿分发。

## 目录

- [快速上手](#快速上手)
- [界面全是黑屏 / 只显示三分之一](#界面黑屏或只显示三分之一)
- [沙盒逃逸探针用法（重点）](#沙盒逃逸探针用法重点)
- [探针控制台的每个设置是什么意思](#探针控制台的每个设置是什么意思)
- [MobileGestalt 编辑器用法](#mobilegestalt-编辑器用法)
- [日志在哪里、怎么导出](#日志在哪里怎么导出)
- [构建与安装](#构建与安装)
- [已知限制](#已知限制)

## 快速上手

1. 从 GitHub Actions 下载最新的 `FuckFile.ipa`，用爱思助手 / zsign / TrollStore 等方式重签安装。
   **重签时必须保持 bundle id 为 `com.apple.mobile.MobileHouseArrest`**（MCM 路线的硬性要求；bad_query 探针本身不要求）。
2. 打开 App，启动时自动完成：
   - MCM 虚拟根目录建立（`Device Storage/[MHA-*]`）；
   - bad_query 全目标探针（约 1 秒）；
   - 逃逸根目录自动重连（重启后 token 自动补回来）。
3. 首页点 **bad_query 探针控制台** → **枚举容器**，等几秒。
4. 回首页 → **设备存储** → `[BadQuery] Escaped` → `App Data`（或其它分类），就能看到按 bundle id 命名的其它 App 容器链接。
5. 点进某个 App 容器，浏览它的 `Documents / Library / tmp`。

## 界面黑屏或只显示三分之一

这是 sideload App 缺少“真实启动屏”时进入的**兼容模式**：iOS 用 320×480 的旧分辨率渲染你的 App，然后上下黑边补齐，看起来只有中间三分之一有内容。

本版已内置真正的 `LaunchScreen.storyboard`（CI 编译成 `LaunchScreen.storyboardc` 打进 IPA），并设置 `UILaunchStoryboardName`，正常安装后应全屏。

如果安装后仍然黑屏，按顺序检查：

1. 确认你装的是 **1.1.3（build 5）或更新**的 IPA，而不是旧包。
2. 用爱思助手重签时，不要勾选或使用任何“改包名/降级兼容模式”的选项，直接重签即可。
3. 打开 App 后，`FuckFile Log.txt` 会记录屏幕尺寸：
   - 如果 `screen bounds` 是 `402x874` 这类现代尺寸，说明兼容模式已解除；
   - 如果还是 `320x480`，说明安装的是旧包或安装工具剥离了启动屏。
4. 把新的 `FuckFile Log.txt` 导出给我，日志里带有 `screen bounds`、`window frame`、`safe=` 等诊断行。

## 沙盒逃逸探针用法（重点）

探针入口：首页 → **bad_query 探针控制台**。

### 第一次使用（必做）

```text
探针控制台
  └─ 枚举容器（点它）
        ├─ App Data            → 253 个容器
        ├─ InternalDaemon      → 20 个容器
        ├─ PluginKitPlugin     → 899 个容器
        ├─ App Groups          → 122 个容器
        └─ SystemGroup (new)   → 30 个容器
        └─ 结果写入 Device Storage/[BadQuery] Escaped/
```

之后去：首页 → 设备存储 → `[BadQuery] Escaped` → `App Data`。

- 每个容器有 **UUID 链接**（原名，便于对照）和 **bundle id 链接**（如 `com.apple.mobilesafari`，好认）。
- 目录是符号链接，长按可以看属性；点进去就是该 App 的沙盒目录。
- 如果某次重启后点进容器显示“无法打开目录”，App 会自动尝试重新消费沙盒扩展；仍失败就回探针控制台再点一次 **枚举容器**。

### 每次重新打开 App 之后

启动时会自动：

```text
BadQueryProbe run begin
BadQueryProbe run done
BadQueryReconnect begin   ← 自动把 6 个逃逸根目录 + MobileGestalt 的 token 重新消费
BadQueryReconnect done
```

所以正常情况不需要手动操作。若你手动跑了“重新运行探针”，建议随后也点一次“枚举容器”或“消费自定义路径”。

### 探针日志怎么看

每一步（dlopen、每个符号、query 构造、token 获取、consume、access/open/readdir）都记录在：

```text
Device Storage/BadQuery Probe Log.txt   ← 探针专用，带 [HH:mm:ss]
Device Storage/FuckFile Log.txt         ← 全 App 日志，带毫秒时间戳
```

常见状态：

| 状态 | 含义 |
| --- | --- |
| `TOKEN-OK` | 该组合能签发沙盒 token（未消费） |
| `consume OK matrix` | 已消费成功，句柄生效 |
| `container_copy_sandbox_token NULL` | canonical flags 被内核拒绝，走矩阵回退 |
| `denied` | containermanagerd 直接拒绝（该路径不可达） |
| `code=-4` | 内核拒绝签发扩展 |

## 探针控制台的每个设置是什么意思

| 按钮 | 作用 | 什么时候用 |
| --- | --- | --- |
| 重新运行探针 | 重新跑一遍全部目标 + 变体矩阵 | 怀疑系统状态变化、想留新日志时 |
| 查看步骤日志 | 打开 `BadQuery Probe Log.txt` | 排查哪一步失败 |
| 查看结果 Plist | 打开结构化结果 | 给开发者看 / 分析矩阵 |
| 消费自定义路径 | 对任意绝对路径执行 bad_query 并保留句柄 | 探针没覆盖的路径，手动开权限 |
| 释放扩展 | 释放“手动消费”的句柄 | 测完想回收（枚举用的句柄不会释放） |
| 枚举容器 | 批量枚举 + UUID→bundle id 建链接 | **核心操作，每次重装后必点** |
| 设置 App Group 牺牲 | 写 `AppGroupSacrifice.plist` | 见下文 |
| 查看变体矩阵 | 64 组组合的 TOKEN-OK 结果 | 研究当前系统哪条路还活着 |
| 使用说明 | 这份文档的 App 内版本 | 随时查 |

### App Group 牺牲（可选设置）

iOS 26 上访问 App Group 需要“牺牲”一个你自己签名时拥有的 group：

1. 重签 IPA 时给 entitlement 加入：

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.your.own.group</string>
</array>
```

2. 打开 App → bad_query 探针控制台 → **设置 App Group 牺牲** → 输入同一个 `group.your.own.group` → 保存。
3. 重新运行探针 → 枚举容器。

没有配置时，class 7 路线会跳过，日志会写明：

```text
No AppGroupSacrifice.plist (GroupId) configured; class 7 sacrifice route skipped
```

App Group 链接在 `[BadQuery] Escaped/App Groups/` 下。

## MobileGestalt 编辑器用法

入口：首页 → 工具 → MobileGestalt 编辑器。

### 为什么之前是空的

MCM 的 class-13 scoped 激活在 iOS 26.6 上拿不到 token（日志：
`MCM object contained no sandbox token`）。本版已加 **bad_query 矩阵回退**：

```text
[MCM] gestalt bad_query consume begin target=/var/containers/Shared/SystemGroup/.../com.apple.MobileGestalt.plist
[MCM] gestalt bad_query consume OK handle=... 
[MCM] gestalt reachable via bad_query path=... 
```

消费成功后编辑器直接读写 `com.apple.MobileGestalt.plist`，并自动把原始文件备份到：

```text
Documents/MobileGestalt Backup/SavedGestalt.plist
```

> iOS 26.6 上系统组的目录枚举仍被沙箱拒绝（`Caches` 目录 `opendir` 返回 EPERM），
> 但文件本身可读可写，所以编辑器功能不受影响。需要在浏览器里直接看这个文件时，
> 用编辑器里的 **“导出 plist 到设备存储”**，它会复制到
> `Device Storage/MobileGestalt Export/com.apple.MobileGestalt.plist`。

### 常用开关

- **灵动岛、全天候显示、充电上限、开机提示音、相机控制、操作按钮、车祸检测、轻点唤醒、PWM 调光、Apple Intelligence、内部存储、Metal HUD、区域限制** 等。
- **关闭区域限制**会写入 `US / LL/A`，改前想清楚。
- 设备外观：`ArtworkDeviceSubType` 预设（iPhone 14 Pro / 15 Pro Max / 16 Pro / 16 Pro Max 等）。
- 设备型号：改 `h9jDsbgj7xIVeIQ8S3/X3Q`（Apple Intelligence 资格用），可能影响面容 ID。

操作：

- **应用修改**：原子替换写入，点完重启生效。
- **还原修改**：恢复首次备份的原始 plist。
- **打开 plist 所在目录**：直接在文件管理器里看原始文件。

> 警告：空 plist 或非法 plist 时不要重启，先“还原修改”。改 MobileGestalt 有软砖风险。

## 日志在哪里、怎么导出

所有日志都在 App 的 Documents 下，开启了 `UIFileSharingEnabled`，可以从系统“文件”App 导出：

```text
文件 App → 我的 iPhone → FuckFile → Device Storage
```

建议导出这 4 个文件后压缩发我：

```text
FuckFile Log.txt
BadQuery Probe Log.txt
BadQuery Probe Results.plist
ACCESS MAP.txt
```

另外：

- `[BadQuery] Escaped/`：逃逸后建的符号链接目录。
- `[BadQuery] Escaped/Enumerate Results.plist`：枚举摘要。
- `[BadQuery] Escaped/Reconnect Results.plist`：自动重连结果。
- `[MHA-Mixed EXP] Experimental/Probe Results.plist`：MCM 实验性 scoped 探针结果。

## 构建与安装

push 到任意分支后 GitHub Actions 都会自动构建并上传：

```text
https://github.com/fucknima/FuckFile/actions
```

artifact 按分支命名（如 `FuckFile-unsigned-ipa-main`、`FuckFile-unsigned-ipa-codex-gestalt-export`），
下载 `FuckFile.ipa` 后自行重签（爱思助手 / zsign / TrollStore）。

本地构建（需要 macOS + Theos）：

```sh
export THEOS=$HOME/theos
make clean
make FINALPACKAGE=1
```

## 已知限制

- 改 bundle id 即失效：MCM 激活前有硬校验（fail-closed），bad_query 探针本身不受影响。
- 没有 root、没有 `/var/mobile` 全局访问、没有 Keychain、没有 TCC、不能读 App bundle。
- 进入容器后仍受 Data Protection 与 DAC（owner/mode）限制，部分文件能看到名字但打不开。
- iOS 版本收紧后部分 class 查询失败属正常，以 `Probe Results.plist` 为准。
- 可配置目标清单：`Documents/MCMIdentifiers.plist`（格式见 `MCMIdentifiers.example.plist`）。

## Credits

- MCM 机制与实现：0xjohnnydev/FilzaSlop（及其上游 FilzaJailedDS / MCM 研究成果）
- 沙盒逃逸：forcequitOS/bad_query（Taj C）
- MobileGestalt 编辑器概念与键位：rooootdev/mond
