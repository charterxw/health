# 云影的 ChatGPT 识别连接

`backend/app/media_bridge.py` 由 FastAPI lifespan 启动，在 Unix socket 接受带内部令牌的固定识别请求。仅支持片名提取、TMDB 候选判断、连接测试；不新增公共 API 路由，不读健康数据，不写分析记录。模型和 ChatGPT OAuth 由 Health 的现有配置管理，续期使用同进程的 `chatgpt_auth` 锁。

生产配置：`MEDIA_AI_SOCKET=/run/media-ai/media-ai.sock`、`MEDIA_AI_TOKEN_FILE=/run/secrets/media-ai-token`。目录与令牌分别从 `/home/admin/cloud-reel/data/health-ai-socket`、`/home/admin/cloud-reel/data/ai-bridge-token` 挂载。令牌只读，不包含任何 OAuth 凭据。环境变量未设置时不启动识别连接。

当前生产镜像 `local/health-backend:media-ai-bridge-v1` 以部署前的 Health 镜像为基础，只增加媒体识别模块与 lifespan 钩子，未升级依赖或更改健康分析逻辑。常规从 backend/Dockerfile 重新构建也包含此功能。

验证：`PYTHONPATH=backend python -m unittest discover -s backend/tests -v`，新增测试覆盖 Unix socket 鉴权、完整流事件、配额失败及 TMDB 候选范围。生产没有生成模拟健康分析记录。
