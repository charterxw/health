"""ChatGPT-plan-backed health analysis service.

The service never fabricates analysis. If ChatGPT-plan inference is unavailable,
callers receive an explicit error and no record is written to the database.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from datetime import datetime
from time import monotonic

from openai import OpenAI

from .chatgpt_auth import ChatGPTAuthError, get_access_token, is_chatgpt_connected
from .database import get_cached_health_today, get_db


logger = logging.getLogger(__name__)


class AIServiceError(RuntimeError):
    """Raised when a ChatGPT-plan analysis cannot be generated."""

    def __init__(self, message: str, code: str = "analysis_unavailable", status_code: int = 503):
        super().__init__(message)
        self.code = code
        self.status_code = status_code


def is_ai_configured() -> bool:
    return is_chatgpt_connected()


def get_ai_model() -> str:
    return os.getenv("OPENAI_MODEL", "gpt-6.1-sol").strip() or "gpt-6.1-sol"


def get_reasoning_effort() -> str:
    value = os.getenv("OPENAI_REASONING_EFFORT", "low").strip().lower()
    return value if value in {"low", "medium", "high", "xhigh", "max"} else "low"


def _require_ai_configured() -> None:
    if not is_ai_configured():
        raise AIServiceError(
            "ChatGPT is not connected. Complete Sign in with ChatGPT first.",
            "chatgpt_not_connected",
        )


def _call_openai(prompt: str, _target_length: int = 1200, *, schema: dict | None = None,
                 wall_timeout: float | None = None, effort: str | None = None) -> str:
    try:
        deadline = monotonic() + wall_timeout if wall_timeout is not None else None
        client = OpenAI(
            api_key=get_access_token(),
            base_url="https://api.openai.com/v1",
            timeout=180.0 if effort in {"high", "xhigh", "max"} else 90.0,
            max_retries=0,
        )
        chunks = []
        completed = False
        format_options = {"text": {"format": {
            "type": "json_schema", "name": "health_observation", "strict": True, "schema": schema,
        }}} if schema else {}
        with client.responses.create(
            model=get_ai_model(),
            instructions=(
                "You are a careful fitness and recovery analyst. Write in Chinese, "
                "use only the supplied data, clearly identify missing data, and never "
                "invent measurements. Do not diagnose disease or replace medical advice."
            ),
            input=[{"role": "user", "content": prompt}],
            reasoning={"effort": effort or get_reasoning_effort()},
            store=False,
            stream=True,
            **format_options,
        ) as stream:
            for event in stream:
                if deadline is not None and monotonic() >= deadline:
                    raise AIServiceError("分析生成超时，稍后会重试", "analysis_timeout")
                if event.type == "response.output_text.delta":
                    chunks.append(event.delta)
                elif event.type == "response.failed":
                    error = event.response.error
                    code = (
                        error.get("code")
                        if isinstance(error, dict)
                        else getattr(error, "code", None)
                    ) or "analysis_failed"
                    _raise_plan_error(code)
                elif event.type == "response.completed":
                    completed = True

        content = "".join(chunks).strip()
        if not completed:
            raise AIServiceError("ChatGPT response ended before completion")
        if not content:
            raise AIServiceError("ChatGPT returned an empty response")
        return content
    except ChatGPTAuthError as exc:
        raise AIServiceError(str(exc), exc.code) from exc
    except AIServiceError:
        raise
    except Exception as exc:
        code = _exception_code(exc)
        if code:
            _raise_plan_error(code)
        logger.error("ChatGPT-plan analysis request failed exception=%s",type(exc).__name__)
        raise AIServiceError("ChatGPT analysis is temporarily unavailable") from exc


def _exception_code(exc: Exception) -> str | None:
    body = getattr(exc, "body", None)
    if isinstance(body, dict):
        error = body.get("error", body)
        if isinstance(error, dict) and error.get("code"):
            return str(error["code"])
    return getattr(exc, "code", None)


def _raise_plan_error(code: str) -> None:
    if code == "subscription_sharing_usage_limit_exceeded":
        raise AIServiceError(
            "ChatGPT Plus usage limit reached. Try again after the allowance resets.",
            code,
            429,
        )
    if code == "subscription_sharing_user_not_eligible":
        raise AIServiceError(
            "This ChatGPT account or workspace cannot use plan allowance here.",
            code,
            403,
        )
    if code in {
        "subscription_sharing_invalid_user",
        "chatpass_v2_scope_not_authorized",
        "chatpass_v2_invalid_authorization_context",
    }:
        raise AIServiceError(
            "The ChatGPT connection needs to be authorized again.",
            code,
            401,
        )
    if code == "subscription_sharing_usage_unavailable":
        raise AIServiceError(
            "ChatGPT could not check plan usage. Try again shortly.",
            code,
            503,
        )
    raise AIServiceError("ChatGPT analysis failed", code)


def _run(coro):
    """Run an async Google Health call from a scheduler/FastAPI worker thread."""
    return asyncio.run(coro)


def _upsert_insight(date: str, slot: str, title: str, content: str, category: str,
                    *, report=None, input_hash=None, input_json=None, prompt_version=None, push=False):
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if input_json and conn.execute("SELECT 1 FROM strength_session_deletions WHERE instr(?, id)>0 LIMIT 1", (input_json,)).fetchone():
            raise AIServiceError("训练记录已删除，请重新生成分析", "training_data_changed", 409)
        conn.execute(
            "DELETE FROM ai_insights WHERE date = ? AND time_slot = ? AND title = ?",
            (date, slot, title),
        )
        saved = conn.execute(
            """INSERT INTO ai_insights
               (date, time_slot, title, content, category, provider, model,
                report_json, input_hash, input_json, prompt_version)
               VALUES (?, ?, ?, ?, ?, 'chatgpt_plan', ?, ?, ?, ?, ?)""",
            (date, slot, title, content, category, get_ai_model(),
             json.dumps(report, ensure_ascii=False) if report else None,
             input_hash, input_json, prompt_version),
        )
        queued = 0
        if push:
            from .web_push import queue_observation
            queued = queue_observation(conn, saved.lastrowid, slot, date)
        conn.commit()
        return queued


async def _observation_day_metrics(today, fields):
    from .google_health import get_today_metric
    from .observations import number

    results = await asyncio.gather(*(asyncio.wait_for(get_today_metric(field, today), timeout=35)
                                     for field in fields), return_exceptions=True)
    cached = get_cached_health_today() or {}
    metrics = {"date": today, "_cached_fields": []}
    for field, result in zip(fields, results):
        value = number(result.get(field)) if isinstance(result, dict) else None
        if value is None and cached.get("date") == today:
            value = number(cached.get(field))
            if value is not None:
                metrics["_cached_fields"].append(field)
        metrics[field] = value
    return metrics


def _get_recent_metrics(days: int) -> list[dict]:
    from .google_health import get_history_metrics

    try:
        return _run(get_history_metrics(days))
    except Exception as exc:
        logger.exception("Could not load Google Health history")
        raise AIServiceError("Google Health history is unavailable") from exc


def _valid_average(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) not in (None, "")]
    return round(sum(values) / len(values), 1) if values else None


def _sleep_percent(row: dict, stage_key: str) -> float | None:
    asleep = float(row.get("minutes_asleep") or 0)
    return round(float(row.get(stage_key) or 0) / asleep * 100, 1) if asleep else None


def _sleep_trend_context(current: dict, previous: list[dict]) -> str:
    """Build transparent personal-baseline math for the sleep-analysis prompt."""
    previous = previous[:7]
    current_with_stages = dict(current)
    current_with_stages["deep_percent"] = _sleep_percent(current, "total_deep_mins")
    current_with_stages["rem_percent"] = _sleep_percent(current, "total_rem_mins")

    history = []
    for row in previous:
        item = dict(row)
        item["deep_percent"] = _sleep_percent(row, "total_deep_mins")
        item["rem_percent"] = _sleep_percent(row, "total_rem_mins")
        history.append(item)

    fields = (
        ("实际睡眠", "minutes_asleep", "分钟"),
        ("睡眠效率", "sleep_efficiency_percent", "%"),
        ("深睡占比", "deep_percent", "%"),
        ("REM占比", "rem_percent", "%"),
        ("HRV", "hrv", "ms"),
        ("静息心率", "resting_hr", "bpm"),
        ("平均血氧", "spo2_average", "%"),
        ("呼吸频率", "respiratory_rate", "次/分钟"),
        ("皮肤温度偏差", "skin_temperature_delta_c", "°C"),
    )
    comparisons = []
    for label, key, unit in fields:
        current_value = current_with_stages.get(key)
        baseline = _valid_average(history, key)
        if current_value is None or baseline is None:
            comparisons.append(f"- {label}：当前或历史基线不足")
            continue
        delta = round(float(current_value) - baseline, 1)
        sign = "+" if delta > 0 else ""
        comparisons.append(
            f"- {label}：昨晚 {current_value}{unit}；此前 {len([r for r in history if r.get(key) not in (None, '')])} 晚均值 "
            f"{baseline}{unit}；差值 {sign}{delta}{unit}"
        )

    nightly_lines = []
    for row in [current_with_stages, *history]:
        nightly_lines.append(
            f"- {row.get('date')}：睡眠={row.get('minutes_asleep', '缺失')}分钟，"
            f"效率={row.get('sleep_efficiency_percent', '缺失')}%，"
            f"深睡={row.get('deep_percent', '缺失')}%，REM={row.get('rem_percent', '缺失')}%，"
            f"清醒={row.get('total_awake_mins', '缺失')}分钟，HRV={row.get('hrv', '缺失')}ms，"
            f"静息心率={row.get('resting_hr', '缺失')}bpm，SpO₂={row.get('spo2_average', '缺失')}%，"
            f"呼吸={row.get('respiratory_rate', '缺失')}次/分钟，"
            f"皮温偏差={row.get('skin_temperature_delta_c', '缺失')}°C"
        )

    confidence = "趋势证据较充分" if len(history) >= 5 else "历史不足，只能视为短期迹象"
    return (
        f"可比较的此前主睡眠：{len(history)} 晚（{confidence}）\n"
        "\n相对个人基线的计算：\n" + "\n".join(comparisons) +
        "\n\n逐晚原始摘要：\n" + "\n".join(nightly_lines)
    )


def generate_morning_insight():
    from .observations import generate_sleep_observation
    return generate_sleep_observation()


def generate_evening_insight():
    _require_ai_configured()
    from .observations import DAY_FIELDS, generate_evening_observation
    captured = datetime.now()
    metrics = _run(_observation_day_metrics(captured.date().isoformat(), DAY_FIELDS))
    return generate_evening_observation(metrics, captured_at=captured)


def generate_training_analysis():
    from .training_observations import generate_training_observation
    return generate_training_observation()


def generate_sleep_analysis(force: bool = False):
    from .observations import generate_sleep_observation
    return generate_sleep_observation(force=force)
