# Health：Mac 自动续签与覆盖安装

这是一个需要在你自己的 Mac 上启用的用户定时任务，不是服务器任务或 iPhone 快捷指令。下载包只增加 `ios/scripts/` 下的脚本、测试和本文档；请解压到你原来的项目根目录。它不包含或替换 App 源码。目前提供的是脚本和经过模拟验证的逻辑；尚未在你的 Mac、Apple 账号或真机上验证或启用。

任务每 30 分钟检查一次。记录的有效期进入剩余 72 小时后，在指定 iPhone 能连接时尝试续签，同类签名尝试之间至少间隔 6 小时。手机不可连接时等待下次检查。它不会延长 Apple 的七天限制，也不能向离家的、无法连接的手机隔空安装。

## 第一次启用

1. 在 Mac 上安装并打开完整 Xcode，选择好 Command Line Tools。登录原来的 Apple 账号，确认 Health 主 App 和 WorkoutWidget 扩展使用原来的 Team 与 Bundle Identifier。
2. 接上 iPhone，先用 Xcode 手动 Run 成功一次；完成信任、开发者模式、登录或钥匙串授权。以后可使用 USB，也可使用已经配对且实际能连接的无线设备。无线连接不能保证在手机锁屏、Mac 休眠或不在同一可达网络时工作。
3. 把 `scripts/auto-renew.py` 放进原项目的 `ios/scripts/`，在包含 `ios/` 的项目目录运行：

   ```sh
   python3 ios/scripts/auto-renew.py setup
   ```

   向导会要求填写原 Team ID、iPhone UDID、原 App Bundle Identifier。默认使用脚本旁的 `ios/Health.xcodeproj`；如果脚本不在项目内，会询问项目的完整路径。不要猜测 Bundle ID，也不要提供 Apple 密码给脚本。

   可在 Xcode 的 Devices and Simulators / Device Hub 查看 iPhone 的 UDID；也可先运行 `xcrun devicectl list devices`，再用列表中的设备标识查询：

   ```sh
   xcrun devicectl device info details --device "列表中的设备标识"
   ```

   读取详情中的硬件 UDID；列表里的 CoreDevice Identifier 不一定是可用于 Xcode 构建的 UDID。

   Team ID 可在 Xcode 的签名设置和开发者账号信息中查到。配置应与之前已安装的 App 完全一致。

4. 第一次手动执行并查看结果：

   ```sh
   python3 ios/scripts/auto-renew.py run --force
   python3 ios/scripts/auto-renew.py status
   ```

   若自动任务已经在构建，手动 run 不会并发执行；稍后查看状态或本机日志。只有看到安装命令成功，且 `installed_expiry` 为新的合理有效期，才能认为这一次流程完成。首次没有已安装包的历史有效期可比较；此时只表示已核对新包有效期并完成安装命令。后续必须有效期真的向后延长才允许覆盖安装。

如果只想生成配置和 LaunchAgent 文件而暂不启用，使用 `setup --no-enable`。它不会停止一个此前已经启用的任务；首次设置时使用这个选项。

## 自动流程

- 只连接配置中指定的 iPhone；通过 `devicectl device info details` 进行真实连接检查。
- 使用原项目的 Health scheme、Debug 配置、原 Team 和 App Bundle Identifier，运行允许自动签名更新的 `xcodebuild`。
- 为请求新的描述文件，备份并暂时移走本机缓存中**仅精确匹配 Health 主 App 和 `.workout` 扩展、同一团队**的描述文件。不会移走通配描述文件或其他 App 的描述文件。构建结束或异常退出上下文时恢复原缓存，且不覆盖 Xcode 新写入的同名文件。它不会删除开发者门户上的描述文件或撤销证书。
- 校验主 App 与扩展的 Bundle ID、团队、设备 UDID、描述文件有效期和实际签名证书有效期，取最早到期时间。有效期不足 48 小时或没有比上次延长时停止。
- 用 `devicectl device install app` 覆盖安装；不卸载原 App、不自动打开 App。只有安装命令成功后才更新本地安装记录。
- 失败或临近到期但设备不可达时，在 Mac 本机发送最多每天一次的通知。通知显示还受 macOS 的通知权限和专注模式影响。没有发送邮件或 Telegram。

Xcode 不保证无交互续签。账号登录过期、双重认证、钥匙串权限、设备重新配对、Apple 服务拒绝、描述文件未刷新等情况，仍可能需要在 Mac 上手动处理。`-allowProvisioningUpdates` 本身不保证有效期延长。若连续离家超过剩余有效期，这个任务无法保证 App 持续可用。

## 查看与停用

本机文件存放于：

```text
~/Library/Application Support/HealthAutoRenew/
```

`state.json` 为最近状态，`build.log` / `install.log` 为最近一次工具输出，`agent.log` / `agent-error.log` 为定时任务输出，`profile-backups/` 为描述文件备份。目录仅当前用户可访问；不写入 Apple 密码。`installed_expiry` 是已核对安装包的到期时间，不是对手机当前可运行性的保证，证书被撤销等外部变化仍可能影响 App。

Mac 必须处于登录用户会话中，且 Xcode、钥匙串和网络可用。任务不自动唤醒 Mac，也不承诺手机锁屏时可安装。

```sh
python3 ios/scripts/auto-renew.py status
python3 ios/scripts/auto-renew.py uninstall
```

停用只卸载定时任务，保留配置、日志和备份。若需换 Team、设备或 Bundle ID，先停用，再备份并移走该目录内的 `config.json` 和 `state.json`，最后重新 setup。若电脑异常断电导致缓存未恢复，可在停用任务后，将 `profile-backups` 中相关文件按 `0-`（MobileDevice）或 `1-`（Xcode/UserData）前缀恢复至原缓存目录；不要覆盖新文件。

## 已验证与尚待验证

Linux 上执行标准库测试，覆盖旧描述文件不算续签、近到期包不安装、其他 App 缓存不受影响、异常后恢复缓存、离线设备不触发构建、安装失败不更新有效期、成功路径和路径含空格等情况。没有实际运行 macOS 的 security/codesign/xcodebuild/devicectl；启用前需在你的 Mac 和 iPhone 做第一次真实验证。

```sh
python3 ios/scripts/test-auto-renew.py -v
```

## 官方依据

- [Apple：Personal Team 描述文件七天有效期](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple：Xcode 命令行工具](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)
- [Apple：自动签名请求新描述文件的缓存处理](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/)
