from fastapi import APIRouter, HTTPException, Query
from .. import web_push as service

router = APIRouter(prefix='/api/webpush', tags=['webpush'])


@router.get('/config')
def config():
    try:
        return service.config()
    except (OSError, ValueError) as error:
        raise HTTPException(503, '通知服务暂时不可用，请稍后重试') from error


@router.get('/subscription')
def status(id: str = Query(..., pattern=r'^[a-f0-9]{64}$')):
    return service.subscription_status(id)


@router.post('/subscriptions')
def subscribe(subscription: service.Subscription):
    return service.subscribe(subscription)


@router.delete('/subscriptions')
def unsubscribe(request: service.SubscriptionId):
    return service.unsubscribe(request.id)
