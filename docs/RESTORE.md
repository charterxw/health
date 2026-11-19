# 恢复与交接

本次归档日期：2026-11-18，America/New_York。

仓库保存可重新构建的全部 App / Server / Web 源码、构建配置与依赖锁、
图标、原生肌肉路径、源几何、提示词、训练目录、休息提示音和第三方许可。
`artifacts/ios/1.3.0/` 另存已交付的安装包、原生源码包、校验和与验证记录。

| 部分 | 本次版本 | 主要入口 |
| --- | --- | --- |
| iPhone 原生 App | Pine 1.3.0（10） | `ios/Health.xcodeproj`、`ios/README.md` |
| Server 与网页版 | `dialog-diagnostics-20261118` | `backend/`、`frontend/`、`docker-compose.yml` |
| 设计与交互约定 | 第一版卡片布局的精修版 | `ios/DESIGN.md`、`AGENTS.md` |
| Pi 运维脚本 | 当前主机的六个脚本 | `ops/README.md` |

## 取回源码或安装包

```sh
git clone https://github.com/charterxw/health.git
cd health
git checkout pine-1.3.0-10
shasum -a 256 -c artifacts/ios/1.3.0/SHA256SUMS
```

继续开发时从 `main` 或该标签新建分支。标签用于恢复本次归档，后续版本另建标签。
归档 IPA 未签名，沿用现有 SideStore 签名安装流程。它包含主 App 和实况活动扩展。
覆盖现有 App 时保留原来的 Team / Bundle Identifier；更换签名身份或卸载会影响
Keychain 与本机离线训练的连续性。本仓库没有 Apple 证书和描述文件。

## 构建原生 App

需要 macOS 和完整 Xcode。此版本使用 Liquid Glass SDK API，需要 Xcode 26+
SDK；归档包实际由 Xcode 27.2 / iPhoneOS 27.2 SDK 构建，最低部署目标 iOS 17。
工程、图标和肌肉路径都已生成，通常无需重新生成它们。

```sh
python3 ios/scripts/check-project.py
swift run --package-path ios --jobs 2 HealthCoreChecks
swift run --package-path ios --jobs 2 NativeCoreChecks
bash ios/scripts/build.sh --unsigned-ipa
```

输出为 `ios/build/Pine-unsigned.ipa`。生成原生源码包：

```sh
python3 ios/scripts/package-source.py
```

默认构建未签名包不需要 `ios/Config/Local.xcconfig`。使用 Xcode 直接签名时，
从 `Local.xcconfig.example` 复制该文件并在本机配置团队；该文件被 Git 忽略。
API 地址当前在 `ios/App/HealthAPI.swift`，默认使用现有 HTTPS 域名。

保留三标签：总览、训练、运动记录。首页顺序为观察卡、恢复与步数、活动与训练。
睡眠及其他四项健康详情在恢复入口。`ios/LegacyWebShell/` 仅是历史留档，
没有加入原生 App 编译目标。设计预览数据为生成的示例，Release 不包含这些入口。

本次设备 Release、模拟器 Debug 与 UI 测试包编译及 24 项核心检查通过。
用户要求停止模拟器检查，因此没有完成本版运行、视觉、动效、深色/大字或真机
帧率验收；不要将编译成功理解为这些体验已经通过验收。

## 在新机器运行 Server / Web

需要 Docker Engine 与 Compose v2。以下为独立本地运行配置，不依赖 Pi 的
cloud-reel 媒体连接或主机备份服务。先填写 `.env` 中的登录信息和随机 JWT_SECRET，
将 `COOKIE_SECURE=false`、`CORS_ORIGINS=http://localhost:9999`，并保持后台任务和
Telegram 关闭，直到完成真实账号连接。`ALLOWED_HOSTS` 默认支持本地访问。

```sh
cp .env.example .env
mkdir -p secrets runtime-secrets/oauth
chmod 700 secrets runtime-secrets runtime-secrets/oauth
docker volume create health_fitness-data
# 新建空卷的所有权必须匹配后端的 UID/GID 10001。
docker run --rm --user 0 -v health_fitness-data:/data \
  python:3.11-slim sh -c 'chown 10001:10001 /data && chmod 700 /data'
sudo chown 10001:10001 runtime-secrets/oauth
docker compose --env-file .env -f ops/compose.standalone.yml config --quiet
docker compose --env-file .env -f ops/compose.standalone.yml up -d --build
curl --fail http://localhost:9999/api/readyz
```

浏览器打开 `http://localhost:9999`。空卷会初始化空数据库与内置训练目录，不会
恢复个人训练历史。若这台主机已经有该命名卷，上述命令会复用它；不要为了试运行
覆盖、清空或删除现有卷。恢复已有数据库时，先走下一节的离线恢复步骤。

ChatGPT / Google Health 连接需重新授权，或恢复私有备份中的有效凭据。
ChatGPT 登录工具见 `tools/chatgpt_login.py`：本配置的目标文件是
`runtime-secrets/oauth/chatgpt-oauth.json`，目录和文件需允许 UID 10001 读写以续期。
Google 的 OAuth token 保存在数据卷内的 `/data/tokens.json`。
Google OAuth 回调、域名、HTTPS、CORS 和 cookie 配置应相互匹配。

后端依赖使用 `backend/requirements.txt` 的精确版本与 hashes；Dockerfile 固定
基础镜像摘要并以 10001:10001 运行。前端使用 `package-lock.json` 和 Node 24。
无需把 `node_modules`、Python 虚拟环境、Swift `.build` 或 Xcode DerivedData 放进 Git。

## 恢复现有 Raspberry Pi 部署

根目录 `docker-compose.yml` 与 `backend/Dockerfile` 来自当前 Pi 配置，
不是早期开发版。该 compose 依赖：

- 外部数据卷 `health_fitness-data`，包括训练、健康缓存、模板、反馈与授权 token。
- `.env`：登录、JWT、Google OAuth 等私有配置。
- `runtime-secrets/oauth/chatgpt-oauth.json`：后端可写的 ChatGPT OAuth 凭据。
- `secrets/telegram-bot-token`、`secrets/telegram-chat-id`：可选通知凭据。
- `/home/admin/cloud-reel/data/health-ai-socket` 与 `ai-bridge-token`：媒体服务连接。
- HTTPS 反向代理 / Cloudflare tunnel，以及正确的 LAN 地址、域名和可信代理范围。

更换 Pi 时修改 `.env` 中 `HEALTH_BIND_ADDRESS` 以及 compose 的域名/CORS/host 配置。
如不恢复 cloud-reel，使用独立 compose；不要创建假的媒体令牌来凑齐挂载。
当前根 compose 的镜像标签和 `CURRENT_RELEASE` 对应同一实际运行版本；
部分旧的环境版本标记不代表实时静态资源，核对时以运行容器和文件 hash 为准。

恢复顺序：

1. 取回本次 Git 标签或目标版本的源码；备份目标主机现有配置与卷。
2. 从私有加密备份恢复 `.env`、凭据和数据。后端停止时恢复卷中的完整文件集，
   保留所有权；数据库至少检查 `PRAGMA integrity_check`，避免只拷贝运行中的 `.db`
   而漏掉 WAL。在线备份应使用 SQLite backup API，或沿用现有备份工具。
3. 确认数据目录和 OAuth 文件允许 UID 10001 读写；只读通知凭据需要可读。
4. 核对网络、反向代理、外部媒体挂载和 `health_fitness-data` 卷已经存在。
5. 在目标主机执行 `docker compose config --quiet`，再执行
   `docker compose up -d --build --wait --wait-timeout 150`。
6. 检查 `/api/readyz`、正常登录、历史训练/模板、最新数据来源与 App 同步。
   确认成功后再打开后台分析和通知。不要用生成新健康分析或测试通知作为启动探针。

本次归档没有重启或更改生产容器、数据库、训练记录和通知。

## Git 以外必须保留的私有备份

这个 GitHub 仓库是公开的。密钥、完整健康数据库、个人报告、保存的个人重量目标、
Apple 签名文件与设备标识没有放进 Git。所有编译资源和生成脚本都在仓库中。
`docs/personal-*.md` 与 `docs/training-333-plan.json` 是本机私有历史材料，
不是编译输入；保持在原机器/私有备份即可。

现有 Pi 的备份系统使用 `server-backup@health`，每天 America/New_York 03:10，
配置在 `/etc/server-backup/profiles/health.json`，最近成功回执在
`/var/lib/server-backup/health/last-success.json`。该系统的加密远端备份包含
`app`、`data` 与 `backup-runtime` 类别；rclone 配置、age 解密身份与远端访问凭据
必须另行安全保存。仓库仅记录这些位置，不含其内容。

`ops/full_restore_check.py` 是该现有系统的恢复演练脚本，依赖原主机布局和现有
镜像；它不等于全新机器的一键恢复器。恢复主机级备份服务还需要私有备份中的
`backup-runtime`，Cloudflare 与 cloud-reel 的基础设施也由各自备份负责。

## 开发检查与资源溯源

后端隔离检查使用 Python 3.11+ 虚拟环境：

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --require-hashes -r backend/requirements-test.txt
ALLOWED_HOSTS=testserver,localhost,127.0.0.1,backend PYTHONPATH=backend \
  python -m unittest discover -s backend/tests -v
cd frontend
npm ci
npm test
npm run build
```

顶层 `backend/test_sleep.py` 会访问真实账号，`tools/` 与 `ops/` 里部分脚本会
写数据库、发送消息、改密码、装定时任务或重启服务；它们不是常规离线检查。

部分旧后端测试仍使用已废弃的 JWT 会话夹具，尚未随 opaque session 安全接口
更新，完整测试集在本次归档时不是全绿。运行基线见
`docs/provenance/archive-validation.json`；归档保留生产代码原貌，没有为通过旧测试
放宽认证。前端模板目标测试缺失的临时文件已替换为仓库内的合成测试夹具。

`docs/provenance/raspberrypi-20261118.json` 保存本次运行后端 42 个文件、发布源
121 个文件的 SHA-256，以及容器镜像 ID 和生产构建配置的 hash。本次逐文件比对一致。
原生路径资源已经提交；重新生成的脚本在 `ios/scripts/`。许可与来源见
`THIRD_PARTY_NOTICES.md`、`licenses/` 和 App 内资源。设计参考约定在 `ios/DESIGN.md`。
