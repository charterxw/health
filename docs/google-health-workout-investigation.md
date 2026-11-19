# Google Health 训练流程调查

更新时间：2026-11-07。状态：已分析录屏、核对公开入口，并完成 8 个公开实现的源码研究。当前采用标准 BLE 心率读取路线；原版 App 安装包不是这一目标的前置条件。

## 用户目标

- 设备：iPhone + Fitbit Air。
- 训练：力量、步行、hiking。
- 痛点：开始训练步骤繁琐，训练中指标不足，结束后报表体验差。
- **当前最高优先级：在 iPhone 手机桌面点一次，就开始指定类型的真实训练。** 报表和训练中页面的重做随后处理。
- 用户进一步明确：不要求通过 Google Health 开始训练，只需训练时读取 Air 心率。自己的 App 开始 session、接收并保存真实心率即可；不要求同时切换原版 App 的训练状态。
- 两个日常痛点必须分别验收：早上不必手动打开 Google Health 才能获得昨夜数据；训练时从桌面一次触发即可看到实时心率。仅接入云 API 或重做报表不能视为已经解决早晨同步。
- 调查范围：开始 → 训练中 → 暂停／恢复 → 结束 → 回看。

## 桌面一键启动：本轮发现

### 新增优先项：晨起同步

官方说明设备会自动同步，打开 Google Health 也会触发同步；iPhone 排障文档要求开启 Google Health 的后台 App 刷新及蓝牙权限。[同步说明](https://support.google.com/googlehealth/answer/14237221?hl=en)、[iPhone 排障](https://support.google.com/googlehealth/answer/14236618?co=GENIE.Platform%3DiOS&hl=en)。Apple 说明从多任务界面主动退出 App 可能使它在再次打开前无法后台检查更新，[参考](https://support.apple.com/en-euro/118408)。这些是诊断方向，不证明用户当前故障原因。

当前先询问用户是否经常主动上划关闭 Google Health，再核对后台设置。云 API 只提供已同步的数据，服务端定时拉取不能强制 Air 上传。Airlift 的作者提出过“早晨打开 Google Health，再同步云数据”的快捷指令自动化，但它仍依赖官方 App 被唤醒。Apple 支持闹钟停止等个人自动化触发，[事件触发说明](https://support.apple.com/en-sg/guide/shortcuts/apd932ff833f/ios)；具体打开 App 的动作受手机锁屏和执行条件影响，必须实测，不能承诺完全锁屏、后台、无人操作即可同步。

晨起验收：在用户正常过夜和早晨使用手机的流程下，记录数据何时从 Air 到达云端；区分“完全后台自动上传”“自动打开官方 App 后上传”“仍需手动打开”三种结果。训练 BLE 心率读取成功不代表晨起睡眠／血氧／HRV 同步问题已解决。

成功标准：首次授权和设备配对完成后，桌面分别提供力量、步行、hiking 的固定入口。日常只点一次，随后可自动打开 App／倒计时，但不再要求选类型或点第二次开始；必须真正进入训练记录状态。只打开 App、到达训练选择页、启动本地计时器或补写一条历史记录都不满足该目标。

### 用户录屏的可见证据

录屏长约 30.11 秒，1206 × 2622。完整来源摘要见 [source manifest](evidence/workout-entrypoint-sources.json)。以下时间是录屏偏移，按抽帧定位，不能当作逐帧测量或触摸事件时间。

| 时间 | 可见状态 | 可支持的结论 |
|---|---|---|
| 00:00 | 已打开 iPhone 健康类 App 文件夹，Google Health 图标可见 | 录屏起点不是关闭文件夹后的完整桌面 |
| 00:01–00:08 | Google Health 的“今天”页；页面同时有“开始”按钮和“健身”标签，顶部显示同步状态 | 本次先进入了综合首页；不能据此认定同步必须完成才能开始 |
| 00:09–00:10 | “健身”页出现步行、力量训练、远足等快速入口 | 本次使用的是 App 内部的训练入口 |
| 00:11–00:13 附近 | “即将开始锻炼”倒计时 | 选择训练类型之后会自动进入倒计时 |
| 00:14–00:17 附近 | 力量训练现场页；从占位值变为心率和增长的训练计时，随后显示暂停后的结束／继续控件 | 存在真实的训练中状态；仅凭画面不能确定 BLE 指令或数据通道 |
| 00:18–00:22 附近 | 结束后出现主观强度评分和“保存并查看摘要”；摘要标注 Fitbit Air，显示一次 4 秒测试训练 | 原版可保存并回看该训练；这段短测试不能代表完整训练的数据覆盖 |
| 00:23–00:30 附近 | 滚动查看摘要，然后确认删除该测试记录 | 可见报表结构；本次没有测试桌面组件或快捷指令 |

观察到的路径是：已打开的文件夹 → Google Health → 健身 → 力量训练 → 倒计时 → 正在训练。由于没有触摸事件日志，不把操作次数或各步等待时间写成精确测量。今天页已有“开始”按钮，本次未测试它，不能声称“健身”标签是唯一入口。

### 系统动作和深层链接

- 用户已在 iPhone 快捷指令中新建并搜索 Google Health／Fitbit，反馈没有找到训练启动动作。这个结论限定于用户当前可见的动作列表；没有据此推断安装包完全不含 App Intents 或动态捐赠动作。
- 已读取第一方 [apple-app-site-association](https://www.fitbit.com/.well-known/apple-app-site-association)。它为正式版 `com.fitbit.FitbitMobile` 声明 `/in-app/*` 路径。原始 JSON 已保存在 [本地证据文件](evidence/fitbit-apple-app-site-association.json)。
- 上述文件只声明网站路径关联，不列出“开始力量／步行／远足”的具体路由，也不能单独证明手机当前版本实现了这些路由。不能把这个通配路径直接制作成可用的训练启动快捷指令。
- 对第一方帮助、开发文档及公开索引的有界查询没有找到可验证的训练启动 URL。`/in-app/` 根路径返回 404；这不排除 App 内的具体路由存在。没有猜测或测试会创建训练的 URL。

关于原版 App 的判断：公开快捷指令路径未找到；深层链接路径有第一方关联元数据，但**一键开始训练尚未实现或验证**。若以后仍要控制原版 App，可通过安装包检查启动路由。用户当前目标已经收敛到自己的界面读取 Air 实时心率：已找到标准 BLE 的实机报告和源码，[已有实现研究](fitbit-air-existing-implementations.md)给出具体依据及 iPhone 路线；这条路线不依赖 IPA。

## 已确认的依据

以下采用“官方文档”“项目源码”“工具检查”分类；录屏另列为“用户提供的可见行为”。它们不是目标 App 的 REA Evidence。当前没有可引用的 Google Health 安装包分析 Evidence ID。

| 结论 | 依据 | 限制 |
|---|---|---|
| Fitbit Air 能把训练中的实时指标传到 Google Health 手机 App | [Google Health 自定义训练说明](https://support.google.com/googlehealth/answer/15402636?hl=en) | 没有证明第三方能订阅原版 App 的同一通道 |
| Air 支持向兼容设备／App 共享实时心率；官方文档提到 Bluetooth Heart Rate Profile | [实时心率共享](https://support.google.com/googlehealth/answer/14236705?hl=en) | 自定义 iPhone App 的连接、后台运行、重新连接、与原版 App 共存均待实测；不能据此推断其他指标也能共享 |
| 公开 API 的 exercise 保存训练 session、事件、分段和汇总；曲线需按训练时间窗口另读遥测 | [Workout API 指南](https://developers.google.com/health/data-types/workouts?hl=en) | 有字段定义不代表用户每次训练都有该字段 |
| 云端数据在设备同步后提供；webhook 表示云端数据已更新 | [数据可用性](https://developers.google.com/health/data-types?hl=en)、[Webhook](https://developers.google.com/health/webhooks) | 不能把云端同步当作低延迟的现场传感器流 |
| stable v4 的 pairedDevices 公开方法只有 get/list | [REST 参考](https://developers.google.com/health/reference/rest)、[Discovery](https://health.googleapis.com/$discovery/rest?version=v4)，revision `20261106` | 这次公开接口枚举未发现远程开始／暂停／停止设备训练的方法；不排除原版 App 有私有能力 |

## 现有项目能复用什么

这是本项目源码观察，未联网读取用户健康数据：

- `backend/app/google_health.py` 已使用 Google Health v4 和三类只读 scope。
- `backend/app/routes/workouts.py` 的 `/api/workouts/exercises` 读取过去 120 天的训练，向前端保留日期、时间、名称、分钟、热量、步数。当前未输出 session 标识、完整时间窗口、距离、心率、区间、分段或 GPS 信息。
- 同一接口筛选 FITBIT／空 platform，第三方来源不会全部保留。
- `frontend/src/components/TrainingInsights.jsx` 是训练历史和分析页面，没有正在训练的 session 状态或开始／暂停／恢复接口。
- 力量训练的组数、重量、次数、RPE 来自训记，不能称作从 Google Health 提取的力量训练明细。
- 当前 Google Health 接入没有 location scope。路线读取需要核对权限及原始数据覆盖。

## 需要用 REA 和实机回答的问题

| 问题 | 需要的证据 | 当前状态 |
|---|---|---|
| 启动一种常用训练需要哪些步骤？能否通过系统快捷入口直达？ | 实机流程；若有可读 IPA，再检查 URL schemes、App Intents、页面入口与调用关系 | 录屏路径已观察；用户未找到快捷指令训练动作；具体深层路由未验证 |
| 开始训练是否会切换 Air 设备状态，还是只建立手机 session？ | 开始／暂停／恢复／停止前后的状态变化，必要时结合代码或操作者提供的协议记录 | 未验证 |
| 实时指标来自哪个通道，更新频率怎样？ | 实机实时界面与时间戳；可读代码；BLE 心率共享的真实连接测试 | 录屏可见现场数据变化；底层通道和频率未验证 |
| 心率共享是否要每次手动开启，断开后能否自动恢复？ | Air + iPhone 实测，含锁屏、后台、重连 | 未验证 |
| 结束后哪些数据即时可得，哪些要等待同步？ | 同一次训练的原版页面、设备状态与 API 时间窗口对照 | 录屏可见短测试结束后进入摘要；未对照云端同步时间 |
| 力量训练能否获得动作／组数，hiking 能否获得路线和爬升？ | 原版记录与对应 session／遥测字段；区分手机、Air、手动输入的来源 | 未验证 |

## 待验证的自定义界面方向

这些是设计候选，并非已经实现的设备能力：

- **开始**：力量、步行、hiking 三个常用入口；清楚显示传感器连接与定位状态。
- **训练中**：统一显示训练计时、心率与连接状态。力量增加组数／重量／次数和休息计时；步行与 hiking 增加距离、配速、路线和爬升，字段取决于可用来源。
- **结束后**：先展示主要成绩，再展示心率曲线和区间。力量按动作比较历史；步行／hiking 展示路线、分段和爬升。缺测保持缺测，不能画成 0。
- **记录归属**：若自定义 App 记录 session，应保留原始标识、来源和完整起止时间；写入 Google Health 前验证重复记录和日汇总语义。

两条技术路线需要分别验证：

1. 保留 Google Health 的设备连接和采集，自定义界面读取同步后的详细记录。此路线对报表最直接，启动和现场展示的改善仍受原版入口限制。
2. iPhone 自行维护训练 session，通过 Air 心率共享取得实时心率，手机负责定位／计时／手动力量日志。此路线是否成立取决于心率连接、后台定位及数据去重测试；不等于已能遥控 Air。

## REA 准备与当前阻塞

- 已读取官方 [REA skill](https://github.com/morluto/rea/blob/main/.agents/skills/reverse-engineer-anything/SKILL.md) 及连接恢复、Android、Apple 资源相关说明。
- 已通过官方 npm 包运行 REA `6.8.0` CLI；复用现有 Node `24.22.1`。包位于 npm 缓存，未修改项目依赖。
- `rea doctor --client codex --json` 确认该 Node 可用，当前没有 setup 管理的 Codex REA 注册。本次可继续使用 CLI，无须为了本次调查修改注册。
- 已安装的 CLI 帮助确认 `inspect-artifact` 支持先保存完整 Evidence 再返回 summary。后续以该版本实际命令和 schema 为准。
- 用户没有 IPA。此前已通过 Homebrew 安装并验证开源工具 [`ipatool` 2.6.0](https://github.com/majd/ipatool)，但没有发起登录。现有标准 BLE 路线使当前任务无需获取原版安装包，因此登录与下载流程暂时搁置。
- [美国 App Store 目录查询](https://itunes.apple.com/lookup?id=462638897&country=us) 于本次调查返回：`Google Health (Fitbit)`、商店 ID `462638897`、bundle ID `com.fitbit.FitbitMobile`、商店版本 `5.12`，发布日期 `2026-11-05`。这是商店目录元数据，不证明手机已安装此版本。
- 本机 Downloads／Applications 的有界文件名检查没有找到目标 APK／IPA。手机实际安装版本和二进制 SHA-256 仍未知。
- iPhone Mirroring 打开后显示首次设置欢迎页，尚未连接到用户 iPhone；没有进行配对或访问手机内容。

用户本次暂不方便配对 iPhone Mirroring，已提供并分析训练流程录屏。随后研究已有实现，确认当前“训练时读心率”的目标有标准 BLE 路线，因此暂不进行 IPA 获取或 Apple 账号登录。下一步应验证用户 iPhone 与 Air 的心率共享连接，再实现自己的桌面入口和记录界面。原版路由与私有协议仅保留为可选调查方向，不是当前前置条件。


## 2026-11-08 补充：打开 App 的官方链接

[Google 官方 Universal Links 文档](https://developers.google.com/health/universal-app-links)明确列出 `https://www.fitbit.com/in-app/today`，用于打开 Google Health 的 Today 页。它支持本次训练报告中的“打开 Google Health 同步”入口；没有声明开始训练或强制 BLE 同步的能力。这里验证的是官方链接定义，iPhone 主屏幕 Web App 的实际 App 跳转仍待实机观察。返回后会请求后台重新获取，并保留延迟补采。此前未找到可验证“开始训练 URL”的结论不受这个首页入口影响。
