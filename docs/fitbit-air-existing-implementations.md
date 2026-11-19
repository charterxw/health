# Fitbit Air 已有数据读取实现研究

调查日期：2026-11-07。已读取 8 个公开仓库的源码，[固定 commit 与文件清单](evidence/fitbit-air-repositories.json)已保存。未执行这些仓库的程序、连接用户 Air 或发起 Apple 账号登录。结论区分源码观察、作者实测报告和设计推断，不属于原版 App 的 REA Evidence。

## 当前目标与结论

用户明确：不要求经 Google Health 开始训练，核心是在训练时读取 Air 的实时心率；桌面一次点击启动自己的读取／记录界面即可。

已有实现采用标准 BLE：启用 Air 心率共享，连接 Heart Rate Service `0x180D`，订阅 Heart Rate Measurement `0x2A37`。Google 的[官方说明](https://support.google.com/googlehealth/answer/14236705?hl=en)也确认 Air 支持向兼容设备和 App 共享 Bluetooth Heart Rate Profile。

实时心率路线不依赖原版 App 的私有启动路由或 IPA。现有 Air 配对和心率共享设置仍是前置条件；iPhone 上的后台读取、重复开始、重连和与原 App 共存需实机验证。

## 直接读取 BLE 的项目

### wasimcodex/180D：实机依据最具体

[仓库](https://github.com/wasimcodex/180D)，Android，MIT。固定版本 `ffd03a9296ed9b547d11a170ebacfc3f2ec24d3d`。

- [BLE 源码](https://github.com/wasimcodex/180D/blob/ffd03a9296ed9b547d11a170ebacfc3f2ec24d3d/app/src/main/java/com/example/a180d/BleHeartRateService.kt#L445-L519)发现 `180D/2A37`，开启通知，解析 BPM 并保存样本。
- [开始 session](https://github.com/wasimcodex/180D/blob/ffd03a9296ed9b547d11a170ebacfc3f2ec24d3d/app/src/main/java/com/example/a180d/BleHeartRateService.kt#L165-L183)创建本地记录并连接心率设备；[存储模型](https://github.com/wasimcodex/180D/blob/ffd03a9296ed9b547d11a170ebacfc3f2ec24d3d/app/src/main/java/com/example/a180d/SessionStorage.kt#L32-L77)分别保存 session 和带时间戳的心率样本，没有通过原版 App 发开始训练命令。
- 作者记录了 Air、Pixel 6a、nRF Connect 的实机检查；发布帖还有用户报告成功和重连问题。本次未独立复现。
- [所测固件的数据包](https://github.com/wasimcodex/180D/blob/ffd03a9296ed9b547d11a170ebacfc3f2ec24d3d/CLAUDE.md#L205-L254)为 flags `0x00`，含 8-bit BPM，不含 RR intervals、contact 或 energy expended。不能扩展为所有固件的永久限制。
- [连接经验](https://github.com/wasimcodex/180D/blob/ffd03a9296ed9b547d11a170ebacfc3f2ec24d3d/CLAUDE.md#L318-L342)：`Always visible` 影响设备发现；已有 App 连接设备时可能不再广播，应考虑记住设备后直连。Android 的 GATT 缓存处理不能照搬到 iOS。

### taku0193/pulse-air-macos：Apple 平台参考

[仓库](https://github.com/taku0193/pulse-air-macos)，Swift／CoreBluetooth，MIT。固定版本 `dc3820b7361ef565640e91e92baf1232b5b63346`。

[HeartRateMonitor.swift](https://github.com/taku0193/pulse-air-macos/blob/dc3820b7361ef565640e91e92baf1232b5b63346/Sources/PulseAirMenuBar/HeartRateMonitor.swift)实现扫描 `180D`、连接、发现 `2A37`、`setNotifyValue(true, for:)`、收到通知后解析并更新时间戳。[解析器](https://github.com/taku0193/pulse-air-macos/blob/dc3820b7361ef565640e91e92baf1232b5b63346/Sources/PulseAirCore/HeartRateParser.swift)处理标准 8-bit／16-bit BPM 和短包。它是 macOS 项目，CoreBluetooth 数据路径可参考到 iOS，但不能称为已验证的 iPhone 实现。

### AyushSagar16/fitbit-air：BLE 与云端分开

[仓库](https://github.com/AyushSagar16/fitbit-air)，Node／noble，MIT。固定版本 `b27b8ed3f73c534b1cff10193f78c9f9515d8836`。

[BLE 模块](https://github.com/AyushSagar16/fitbit-air/blob/b27b8ed3f73c534b1cff10193f78c9f9515d8836/src/ble/heartRate.js#L228-L280)订阅 `2A37`，服务器转发到 WebSocket／REST。[session store](https://github.com/AyushSagar16/fitbit-air/blob/b27b8ed3f73c534b1cff10193f78c9f9515d8836/src/server/sessions.js)只是内存记录，重启即清空。通用解析器虽支持 RR、能量、contact，代码也尝试读取电量服务，但不能据此声称 Air 实际发送这些字段。它不是可直接安装在 iPhone 的 App。

另检查了 [LordPerkyy/HeartRateWidget](https://github.com/LordPerkyy/HeartRateWidget)：Python／Bleak 订阅标准心率通知，主要面向 Windows 浮动显示。其自动解除 Windows 蓝牙配对的处理不适合原样移植到用户 iPhone。

## 读取云端历史的项目

| 仓库 | 已实现的路径 | 当前需求的边界 |
|---|---|---|
| [santekotturi/airlift](https://github.com/santekotturi/airlift) | iOS Swift；Google Health API → HealthKit，处理睡眠、HR、HRV、SpO₂、步数等 | 无 Air BLE 读取路径；其 [App Intent](https://github.com/santekotturi/airlift/blob/de2ec9e596310fba64c9b9b399e72489796c226c/Sources/Intents/SyncIntent.swift)用于同步数据，不是开始设备训练 |
| [Luraxx/pulse](https://github.com/Luraxx/pulse) | iOS Swift；[HealthAPIClient](https://github.com/Luraxx/pulse/blob/f324b03319af60958751ec4e5e0379af5d592efd/Core/API/HealthAPIClient.swift)读 Google Health，在手机计算日常指标 | 可参考 iOS UI 与云数据接入；本次在 App、Core、Widget 中未找到直接 BLE 读取实现 |
| [bharathajay51/fitbit-air](https://github.com/bharathajay51/fitbit-air) | Python；[live_feed.py](https://github.com/bharathajay51/fitbit-air/blob/8f287432a8d015c92f542e9d49a165ebefd7c85f/live_feed.py)轮询云端心率 | live 不代表现场 BLE；作者关于第三方不能直接读 Air 心率的笼统说法与心率共享实测不符，不采用该说法 |
| [adityaongit/pulse](https://github.com/adityaongit/pulse) | Web；[Google API client](https://github.com/adityaongit/pulse/blob/15b236d4a07e45ea0acd04b393c1b85bdd742238/src/server/sources/google/client.ts)读取同步数据 | 该 commit 的 [startActivity](https://github.com/adityaongit/pulse/blob/15b236d4a07e45ea0acd04b393c1b85bdd742238/src/lib/features.ts)为 false；[现场页源码](https://github.com/adityaongit/pulse/blob/15b236d4a07e45ea0acd04b393c1b85bdd742238/src/app/%28app%29/activity/LogActivity.tsx#L201-L205)说明没有实时心率和定位采集。许可证为 PolyForm Noncommercial |

## 不宜当作 Air 成功案例的工作

[Gadgetbridge PR #6273](https://codeberg.org/Freeyourgadget/Gadgetbridge/pulls/6273)是未合并的 Charge 6 集成，作者称部分实时数据依赖已配对官方 App 中的会话密钥，首次离线配对和完整历史同步仍受阻。其他型号的进展不证明 Air 完整私有协议已被还原。

本轮检查的仓库没有给出已验证的 Air 原生训练开始／暂停／结束控制通道。用户当前目标不要求该通道，因此它不再阻塞实时心率方案。

## iPhone 实现路线

以下是基于源码和 Apple API 的设计推断，尚未在用户设备验证：

1. 首次设置：保留现有 Air 配对，开启心率共享；自己的 App 获取蓝牙权限，选择并记住用户 Air。
2. 桌面入口：自己的 App 提供带训练类型的 App Intent，触发后进入记录界面并开始自己的 session。参考 [Apple App Intents](https://developer.apple.com/videos/play/wwdc2025/244/)。
3. 训练中：CoreBluetooth 订阅 `180D/2A37`，保存实际收到的 BPM 与接收时间，展示当前心率、曲线、连接状态和计时。断流后标记过期，不把旧值当成实时值。
4. 结束后：用本地样本生成心率曲线和统计。步行／hiking 的手机 GPS、力量训练的手动日志可后续加入，不能声称这些信息来自心率通知。
5. 按 [Apple CoreBluetooth 后台机制](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)处理状态保存／恢复；实测首次连接、连续两次开始、锁屏、切 App、断线重连和 Google Health 同步共存。

第一阶段验证：完成一次性设置后，桌面一次触发自己的界面，连接 Air 并持续读取真实心率。原版 IPA 获取和 Apple 账号登录流程暂时搁置。
