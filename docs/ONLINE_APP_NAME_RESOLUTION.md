# AppData 在线 App 名称补全

日期：2026-08-26

## 目标

AppData 在 MobileHouseArrest 身份下能够确认第三方应用 Bundle ID，但本地 LaunchServices / 容器 metadata 无法稳定取得用户 App 的真实显示名称。本功能只解决：

`Bundle ID -> 可读 App 名称`

不参与 App 枚举、MCM lease、安装状态判断或 AppData 权限判断。

## 实现

实现入口：`FFOnlineAppNameResolver`。

触发条件：

- 设置「在线补全 App 名称」开启（首次安装默认开启）；
- AppData Registry 中条目已经存在；
- Bundle ID 不是 `com.apple` / `com.apple.*`；
- 当前显示名为空或仍与 Bundle ID 完全相同。

数据源：Apple 公开 iTunes / App Store Lookup 目录。

查询按 storefront 依次尝试：

1. CN
2. 当前系统 Locale 的国家/地区
3. US
4. JP
5. GB
6. NZ
7. AE

使用 `bundleId` 查询；返回结果必须满足：

`returned bundleId == requested bundleId`

完全相等才接受 `trackName`（无 `trackName` 时才使用 `trackCensoredName`）。禁止模糊匹配、搜索结果猜测和第三方网页自动写入。

## 缓存与失败策略

- 成功结果：缓存 30 天；
- 所有 storefront 都明确无结果：负缓存 24 小时；
- 网络错误、非 2xx、JSON 结构异常：不写负缓存；
- HTTP 429：暂停新的在线查询 60 秒；
- 在线失败：继续显示 Bundle ID，不影响 AppData 浏览和打开；
- 页面加载不等待网络，在线补全始终异步执行。

Registry 使用批量升级接口 `upgradeFallbackDisplayNames:`，只允许把“空名称 / Bundle ID fallback”升级为真实名称。后续 AppData 重扫若再次只能得到 Bundle ID，不允许把已经补全的名称降级回 Bundle ID；如果以后本地来源取得非 fallback 名称，本地名称仍可覆盖在线结果。

## 设置与隐私

设置页「系统访问」分组增加：

`在线补全 App 名称：开 / 关`

说明明确告知：开启后会把未命名第三方 App 的 Bundle ID 发送给 Apple App Store 公开目录。关闭后立即停止后续在线请求；已经成功补全的名称保留在本地 Registry，不回退成 Bundle ID。

## 真机样本依据

2026-08-26 真机日志：AppData Registry 共 240 个可访问条目，其中按当前产品规则分类为 47 个用户 App、193 个 `com.apple.*` 系统条目。对 47 个用户 Bundle ID 的外部核对中，约 89% 可由公开商店元数据直接确认名称；计入项目自身等可精确验证来源时约 91%。主要失败模式是私有、自签或已不可公开检索的 App 无结果，而不是 Bundle ID 错配。

因此实现原则是“宁可不补，也不能猜错”：精确 Bundle ID 校验失败时一律保留原标识符。
