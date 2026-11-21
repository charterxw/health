from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field

from .. import strength_training as service
from .. import workout_physiology as physiology
from .. import exercise_history
from .. import session_review

router = APIRouter(prefix="/api/strength", tags=["strength"])


def mutate(callback, *args):
    try:
        return callback(*args)
    except service.DeletedSession as error:
        raise HTTPException(410, {"message": str(error), "deleted": error.tombstone}) from error
    except service.Conflict as error:
        raise HTTPException(409, str(error)) from error
    except ValueError as error:
        raise HTTPException(422, str(error)) from error


@router.get("/catalog")
def catalog():
    return service.catalog()


@router.post("/exercises")
def create_exercise(exercise: service.Exercise):
    return mutate(service.create_exercise, exercise)


@router.put("/exercises/{exercise_id}/setup-note")
def save_setup_note(exercise_id: str, request: service.SetupNote):
    try:
        return service.save_setup_note(exercise_id, request)
    except LookupError as error:
        raise HTTPException(404, str(error)) from error


@router.get("/exercises/{exercise_id}/history")
def exercise_progress(exercise_id: str):
    data = exercise_history.history(exercise_id)
    if data is None:
        raise HTTPException(404, "没有找到这个动作")
    return data


@router.put("/templates/{template_id}")
def save_template(template_id: str, request: service.SaveTemplate):
    if request.template.id != template_id:
        raise HTTPException(422, "模板编号不一致")
    return mutate(service.save_template, request)


@router.get("/sessions")
def sessions(limit: int = Query(100, ge=1, le=500)):
    return service.list_sessions(limit)


@router.get("/session-deletions")
def session_deletions():
    return service.list_session_deletions()


@router.get("/sessions/{session_id}")
def session(session_id: UUID):
    record = service.get_session(session_id)
    if record is None:
        raise HTTPException(404, "没有找到这场训练")
    return record


@router.put("/sessions/{session_id}")
def save_session(session_id: UUID, request: service.SaveSession):
    if session_id != request.session.id:
        raise HTTPException(422, "训练编号不一致")
    return mutate(service.save_session, request)


@router.get("/sessions/{session_id}/review")
def workout_review(session_id: UUID):
    result = session_review.read_review(session_id)
    if result is None:
        raise HTTPException(404, "没有找到可分析的已完成训练")
    return result


@router.post("/sessions/{session_id}/review")
def request_workout_review(session_id: UUID, background_tasks: BackgroundTasks):
    if session_review.read_review(session_id) is None:
        raise HTTPException(404, "没有找到可分析的已完成训练")
    token = session_review.claim_review(session_id)
    if token:
        background_tasks.add_task(session_review.generate_review, str(session_id), token)
    return session_review.read_review(session_id)


@router.delete("/sessions/{session_id}")
def delete_session(session_id: UUID, expected_version: int = Query(..., ge=1)):
    deleted = mutate(service.delete_session, session_id, expected_version)
    if deleted is None:
        raise HTTPException(404, "没有找到这场训练")
    return deleted


class DeleteSession(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_version: int = Field(ge=1)


@router.post("/sessions/{session_id}/delete")
def delete_session_action(session_id: UUID, request: DeleteSession):
    return delete_session(session_id, request.expected_version)


def require_report(report):
    if report is None:
        raise HTTPException(404, "没有找到这场训练")
    return report


@router.get("/sessions/{session_id}/physiology")
def workout_physiology(session_id: UUID):
    return require_report(physiology.get_report(session_id))


@router.post("/sessions/{session_id}/physiology/refresh")
def refresh_physiology(session_id: UUID):
    raise HTTPException(410, '力量训练报告已停止单独获取心率，请刷新页面查看训练复盘')


class SelectSource(BaseModel):
    model_config = ConfigDict(extra="forbid")
    source_id: str = Field(min_length=1, max_length=64)


@router.put("/sessions/{session_id}/physiology/source")
def select_physiology_source(session_id: UUID, request: SelectSource):
    return require_report(mutate(physiology.select_source, session_id, request.source_id))
