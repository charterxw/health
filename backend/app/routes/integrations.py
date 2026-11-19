from fastapi import APIRouter, HTTPException

from ..chatgpt_auth import get_chatgpt_status
from ..notifications import get_notification_status, send_telegram_message


router = APIRouter(prefix="/api/integrations", tags=["integrations"])


@router.get("/status")
def integration_status():
    return {
        "chatgpt": get_chatgpt_status(),
        "notifications": get_notification_status(),
    }


@router.post("/telegram/test")
def test_telegram_notification():
    status = get_notification_status()
    if not status["enabled"]:
        raise HTTPException(status_code=503, detail="Telegram notifications are not configured")
    if not send_telegram_message(
        "连接测试",
        "Telegram 通知已连接。之后生成的健康分析会发送到这里。",
    ):
        raise HTTPException(status_code=502, detail="Telegram could not deliver the test message")
    return {"sent": True}
