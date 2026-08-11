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

- 浏览虚拟根与容器内部（symlink 直通真实容器）
- 复制 / 剪切 / 粘贴（进程内剪贴板，跨容器可用，禁止粘贴进自身）
- 删除（确认）与重命名
- plist / 文本 / 二进制 hexdump 预览
- 下拉刷新；启动与操作日志输出到系统日志（`[FuckFile]`）
- 每次启动生成 `Device Storage/ACCESS MAP.txt` 记录各 class 查询结果

## bad_query 探针（iOS 26.x）

内置 [forcequitOS/bad_query](https://github.com/forcequitOS/bad_query) 的 C 实现
（`src/BadQuery.c`），启动时自动对全部目标路径执行探针，**每一步**（dlopen、
每个符号解析、query 组装、containermanagerd 回包、token 消费、access/open/
readdir 验证）都记录到：

- `Device Storage/BadQuery Probe Log.txt`（分步、带时间戳、可连续追加）
- `Device Storage/BadQuery Probe Results.plist`（结构化结果）
- 系统日志 `[BadQueryProbe]` 前缀

探针成功的路径会被 symlink 到 `Device Storage/[BadQuery] Escaped/`，可直接浏览。

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
