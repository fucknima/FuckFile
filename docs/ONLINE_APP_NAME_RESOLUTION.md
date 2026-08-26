# AppData 在线 App 名称补全

日期：2026-08-26

## 目标

AppData 在 MobileHouseArrest 身份下能够确认第三方应用 Bundle ID，但本地 LaunchServices / 容器 metadata 无法稳定取得用户 App 的真实显示名称。本功能只解决：

`Bundle ID -> 可读 App 名称`

不参与 App 枚举、MCM lease、安装状态判断或 AppData 权限判断。

设计原则：Bundle ID 永远是技术身份与路径身份；在线名称只是可读显示层。即使目录名称失效、地区发生变化或第三方 App 下架，用户仍能看到真实 Bundle ID。

## 生命周期

`FFOnlineAppNameResolver` 自己管理完整生命周期，AppData 页面不启动网络：

```text
高级系统访问关闭
        ↓
WaitingForSystemAccess（绝不联网）
        │
高级系统访问 Ready
        ↓
AppData 正在扫描 ─────→ WaitingForScan
        │ 扫描完成
        ↓
读取稳定 Registry
        ↓
缓存 / 本地名称判定
        ↓
Resolving（显示进度）
        ├─ 成功/明确无结果 → 继续
        ├─ 断网/5xx/异常 → WaitingForRetry → 自动退避重试
        └─ 429 → 60 秒后自动重试
        ↓
Idle
```

Resolver 在应用生命周期内观察：

- 「在线补全 App 名称」偏好变化；
- 高级系统访问偏好与 Ready/Failed 状态变化；
- AppData 扫描状态变化；
- AppData Registry 变化；
- App 回到前台。

因此进入/离开 AppData 页面不会决定网络任务是否运行，也不会导致重复请求。

### 总闸门

在线请求必须同时满足：

1. 设置「在线补全 App 名称」开启；
2. 「启用高级系统访问」开启；
3. 高级系统访问状态已经 Ready；
4. AppData 当前不在扫描；
5. 不处于网络退避窗口。

关闭高级系统访问会立即使在线阶段失去运行资格；用户的「在线补全」子偏好本身保留，下次高级访问重新可用时自动恢复。

## 数据与优先级

AppData Registry 只保存：

- 可访问 Bundle ID；
- 本地能够可靠取得的名称。

在线名称不再写回 Registry，而是保存在 Resolver 自己的独立 overlay cache。显示优先级：

```text
本地可靠名称
    ↓ 没有
在线精确匹配缓存
    ↓ 没有
Bundle ID
```

这保证未来如果系统/容器 metadata 能拿到真实本地名称，本地名称自然覆盖在线结果；在线错误也不会污染 AppData 的底层 inventory。

## AppData 列表显示

有可读名称：

```text
微信
com.tencent.xin · 用户 App 数据
```

没有可读名称：

```text
com.example.private
用户 App 数据
```

系统 App 同理使用 `Bundle ID · 系统 App 数据`。不再在列表里显示「按需连接」；按需 materialize 属于实现细节，不占用用户最有价值的第二行信息。

`FFEntry.name` 仍保持 Bundle ID，因此虚拟路径、materialize 与技术身份不受显示名变化影响。

## 在线数据源

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

- 成功结果：30 天后需要后台刷新；旧的精确名称继续显示，采用 stale-while-revalidate，不因 TTL 到期突然退回 Bundle ID；
- 所有 storefront 都以有效响应明确无结果：负缓存 24 小时；
- 已有历史精确名称但本次所有 storefront 无结果：保留历史名称并刷新验证时间，兼容下架/地区变化；
- 网络错误、非 2xx、JSON 结构异常：不写负缓存；
- 所有 Lookup（含 storefront fallback）之间至少间隔 3.2 秒，主动控制在 Apple 文档约 20 次/分钟的限制以下；
- HTTP 429：60 秒后自动重试；
- 其他临时网络失败：30/60/120/240/300 秒指数退避，成功后清零；
- 关闭开关、关闭高级访问或 AppData 开始扫描时，当前请求立即失效；旧回调由 request generation 丢弃，不能污染新生命周期；
- 在线失败永远不改变 AppData 的访问能力与 Bundle ID。

## 进度与反馈

现有 AppData 扫描底部 toast 扩展为统一后台状态提示，避免多个浮层竞争：

- AppData 扫描优先：`正在更新 App Data` + 扫描进度；
- 在线阶段：`正在补全 App 名称 · x/y` + 确定进度条；
- 完成：`App 名称已更新 · 已识别 n/total`；
- 网络暂停：短暂提示 `App 名称补全暂停 · 稍后自动重试`。

设置页「在线补全 App 名称」副标题同步显示：等待高级访问 / 等待扫描 / 正在补全 / 等待重试 / 已识别数量。

## 设置与隐私

设置页「系统访问」分组：

- `启用高级系统访问`
- `在线补全 App 名称`

后者是前者的从属能力。高级系统访问关闭时，在线补全开关置灰并显示「需先开启高级系统访问」；偏好值保留。

说明明确告知：开启后会把未命名第三方 App 的 Bundle ID 发送给 Apple App Store 公开目录。关闭在线补全后停止新请求；已经成功缓存的名称保留，不回退成 Bundle ID。

## 真机样本依据

2026-08-26 真机日志：AppData Registry 共 240 个可访问条目，其中按当前产品规则分类为 47 个用户 App、193 个 `com.apple.*` 系统条目。对 47 个用户 Bundle ID 的外部核对中，约 89% 可由公开商店元数据直接确认名称；计入项目自身等可精确验证来源时约 91%。主要失败模式是私有、自签或已不可公开检索的 App 无结果，而不是 Bundle ID 错配。

因此实现原则是：**宁可不补，也不能猜错；名称可以失败，Bundle ID 与 AppData 访问链不能被在线服务影响。**

## 发布门槛

该功能只有在仓库原有 `build.yml` 完整通过 Theos 编译、Share Extension 打包、签名校验和 IPA 产物检查后才视为可真机验证；不以静态阅读或临时 CI 代替正式构建。

交付的 IPA 必须由当前功能分支 HEAD 直接构建；旧 SHA 的成功 artifact 不可替代当前 HEAD 的验证与交付。

临时 `build/appdata-lifecycle-final` 分支仅用于触发与当前源码树一致的正式 IPA 构建，不包含额外源码改动。
