"""Evidence-first daily observations and rolling seven-day reviews."""

from __future__ import annotations

import hashlib
import json
import logging
import math
from datetime import datetime, timedelta
from statistics import mean, median, pstdev, quantiles
from threading import RLock

from .database import get_cached_health_metrics, get_db
from . import body_log

VERSION = "observations-v1"
DAILY_VERSION = "observations-v2"
MORNING_TITLE = "早间睡眠分析"
EVENING_TITLE = "晚间健康分析"
DAY_FIELDS = ("steps", "active_minutes", "calories_burned", "distance_km", "hrv", "resting_hr")
LOCK = RLock()
logger = logging.getLogger(__name__)
FIELDS = (
    "minutes_asleep", "minutes_in_bed", "total_awake_mins",
    "sleep_efficiency_percent", "total_deep_mins", "total_rem_mins",
    "deep_percent", "rem_percent", "hrv", "resting_hr", "respiratory_rate",
    "spo2_average", "skin_temperature_delta_c", "bedtime_minutes", "wake_minutes",
)
ZERO_VALID = {"total_awake_mins", "skin_temperature_delta_c", "bedtime_minutes", "wake_minutes"}


def number(value, zero_valid=False):
    try:
        value = float(value)
        return value if math.isfinite(value) and (value > 0 or zero_valid) else None
    except (TypeError, ValueError):
        return None


def local_minutes(value, offset):
    if not value or offset is None:
        return None
    try:
        local = datetime.fromisoformat(value.replace("Z", "+00:00")) + timedelta(
            seconds=int(str(offset).removesuffix("s"))
        )
        # Noon is the boundary, so 23:30 and 00:30 differ by one hour, not 23.
        return (local.hour * 60 + local.minute - 720) % 1440
    except (ValueError, TypeError):
        return None


def sleep_rows(rows):
    """One main sleep per wake date. Never substitute naps or zero-filled days."""
    by_date = {}
    for row in rows:
        if row.get("is_nap") or not row.get("date") or not number(row.get("minutes_asleep")):
            continue
        item = {"date": row["date"]}
        for key in FIELDS:
            item[key] = number(row.get(key), key in ZERO_VALID)
        for stage in ("deep", "rem"):
            minutes = item[f"total_{stage}_mins"]
            item[f"{stage}_percent"] = round(minutes / item["minutes_asleep"] * 100, 1) if minutes is not None else None
        item["start_time"] = row.get("start_time")
        item["end_time"] = row.get("end_time")
        item["bedtime_minutes"] = local_minutes(row.get("start_time"), row.get("start_utc_offset"))
        item["wake_minutes"] = local_minutes(row.get("end_time"), row.get("end_utc_offset"))
        if item["date"] not in by_date or item["minutes_asleep"] > by_date[item["date"]]["minutes_asleep"]:
            by_date[item["date"]] = item
    return sorted(by_date.values(), key=lambda r: r["date"], reverse=True)


def stats(rows, key):
    values = [row[key] for row in rows if row.get(key) is not None]
    if not values:
        return {"n": 0}
    return {"n": len(values), "mean": round(mean(values), 1), "median": round(median(values), 1),
            "min": min(values), "max": max(values), "sd": round(pstdev(values), 1)}


def personal_reference(history, key):
    reference = stats(history, key)
    if reference["n"] >= 5:
        lower, _, upper = quantiles([row[key] for row in history if row.get(key) is not None], n=4, method="inclusive")
        reference.update(p25=round(lower, 1), p75=round(upper, 1))
    return reference


def comparison(current, history, fields=FIELDS):
    result = {}
    for key in fields:
        reference = personal_reference(history, key)
        value = current.get(key)
        result[key] = {"value": value, "baseline": reference,
                       "delta": round(value - reference["mean"], 1) if value is not None and reference["n"] else None,
                       "delta_from_median": round(value - reference["median"], 1) if value is not None and reference["n"] else None}
    return result


def previous_report(slot, date):
    with get_db() as conn:
        row = conn.execute(
            "SELECT date, report_json FROM ai_insights WHERE time_slot = ? AND date < ? "
            "AND report_json IS NOT NULL ORDER BY date DESC, id DESC LIMIT 1", (slot, date)
        ).fetchone()
    return {"date": row["date"], "report": json.loads(row["report_json"])} if row else None


def report_schema(weekly=False):
    finding = {
        "type": "object", "additionalProperties": False,
        "properties": {
            "headline": {"type": "string", "maxLength": 36},
            "body": {"type": "string", "maxLength": 140},
            "evidence": {"type": "array", "items": {"type": "string", "maxLength": 140}, "maxItems": 4},
            "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
        },
        "required": ["headline", "body", "evidence", "confidence"],
    }
    return {
        "type": "object", "additionalProperties": False,
        "properties": {
            "status": {"type": "string", "enum": ["finding", "unchanged", "insufficient_data"]},
            "summary": {"type": "string", "maxLength": 100},
            "findings": {"type": "array", "items": finding, "maxItems": 3 if weekly else 1},
            "limitations": {"type": "string", "maxLength": 120},
        },
        "required": ["status", "summary", "findings", "limitations"],
    }


DAILY_PROMPT = """写中文早间睡眠分析。先找一个能改变用户理解的判断，通常只写一个发现。第二条必须独立、有证据。
先比较昨夜和个人近28天中位数、常见范围、近几晚，区分单晚变化与连续变化。分辨实际睡眠变短是记录窗口提前结束、开始更晚，还是窗口内未睡增加。两个时间信号必须使用同一批有效夜晚；无法区分就保留不确定性。
HRV、静息心率或睡眠结构只有在支持、修正或反驳主判断时才写。深睡与REM同时看分钟和占比。数值缺失仅指输入为null；单晚波动不代表恢复趋势。
标题直接说观察到的变化；正文用自然中文说明为什么这条值得留意，少用“完整日均值”“窗口分解”等术语。证据写日期、比较基准及样本数。避免把指标列表写成文章，避免用前一天的结论套今天。
只依据输入；相关性不能当原因，未知主观感受不能替用户判断。没有可靠新判断时用一句 summary 交代，findings 留空。局限只留会影响结论的一项；有发现时 summary 留空。
"""

EVENING_PROMPT = """写中文晚间健康复盘，最多两个互不重复的发现，第一条放今天最值得回看的信号。
当天有力量训练时，优先挑最有说明力的一个动作。先看同重量、同组数的逐组次数；若没有同条件，比较具体负重与组次的变化，区别负重选择和表现变化。说清哪些在历史范围、哪些与最近一次不同。间隔较久只当单次参照。辅助量单独解释，记录中最重一组不等于最大力量。
再看当天活动或恢复信号是否提供有用背景：用个人历史中位数与常见范围判断偏离，区别“训练较集中”和“日常走动较少”，仅在两个来源有数据时作这种判断。当天活动是 activity_snapshot_local_time 的取样快照；较低值不能直接等于全天低于平时。
结合昨夜睡眠、当天HRV和静息心率，只写会改变理解的关系；数值存在就不能称未同步，样本不足只说无法判断。睡眠、心率、训练表现可同时发生，不能归因，也不能从心率推断肌肉用力。若活动字段使用当天缓存，只在它影响判断时说明。
标题说具体发现，不用含糊的“信号未同步显示改善”。正文每条挑一两个关键数字，详细组次和比较日期放 evidence。用自然中文，拒绝指标流水账、通用训练建议和重复免责声明。没有可靠新发现时写一句 summary 并留空 findings；有发现时 summary 留空。只用输入证据。
"""

WEEKLY_PROMPT = """生成中文「每周观察」：分析最近七个完整日，与此前数周比较，最多三个有证据的发现。
每个标题直接写结论，正文2-3句，总可见文字不超过500字；只有一个发现时不凑数，没有新判断时findings=[]。
挑值得更新认识的内容：平均值变化是否由少数夜晚驱动；工作日/周末或睡眠窗口结构差异；
训练表现与恢复信号是否一致；一时波动还是跨数周持续移动。比较均值、中位数、分布、覆盖率，避免只比两个周均值。
若判断由两晚拉低，必须用逐晚数据核实并说明其余夜晚情况；若称持续变化，必须检查连续日期，缺测日不可跨越当作连续。
训练只比较同动作、同单位和可比组次；没有训练记录不等于未训练。配对训练/睡眠需正确匹配训练日与次日醒来日期。
任何关系要说明样本数和例外；小样本只称线索，不能归因。缺失/未同步不能当零，不推断病因。
不要七篇日报拼接，不写睡眠/恢复/运动的固定栏目，不重复数字，不固定安排下周计划或行动。
严禁实验、打卡、习惯跟进、建议执行情况、下周验证；用户不需要这些内容。
每条正文最多两个关键数字，其他证据放evidence（日期、有效样本数、比较范围和例外）。
没有证据支撑的发现就删掉，不要以泛泛建议填充。无发现用summary一句话交代稳定或样本不足。
"""


def validate_report(report, weekly=False, *, max_findings=None, max_chars=None):
    if not isinstance(report, dict) or report.get("status") not in {"finding", "unchanged", "insufficient_data"}:
        raise ValueError("Invalid observation status")
    findings = report.get("findings")
    if not isinstance(findings, list) or len(findings) > (max_findings or (3 if weekly else 1)):
        raise ValueError("Invalid number of findings")
    if bool(findings) != (report["status"] == "finding"):
        raise ValueError("Observation status does not match findings")
    visible = len(report.get("summary", ""))
    for finding in findings:
        if not finding.get("headline") or not finding.get("body") or not finding.get("evidence"):
            raise ValueError("A finding must have a conclusion, interpretation and evidence")
        visible += len(finding["headline"]) + len(finding["body"])
    if visible > (max_chars or (500 if weekly else 180)) or (not findings and not report.get("summary")):
        raise ValueError("Observation is too long or empty")
    return report


def render_text(report):
    return "\n\n".join(f"{f['headline']}\n{f['body']}" for f in report["findings"]) or report["summary"]


def serialize(row):
    result = dict(row)
    raw = result.pop("report_json", None)
    result.pop("input_json", None)
    result.pop("input_hash", None)
    result["report"] = json.loads(raw) if raw else None
    return result


def _save_report(slot, date, title, context, *, weekly=False, force=False, notify=True, prepared_report=None, as_of=None):
    from .openai_service import _call_openai, _upsert_insight, AIServiceError
    from .notifications import notify_analysis

    daily = slot in {"morning", "evening"}
    version = DAILY_VERSION if daily else VERSION
    snapshot = json.dumps(context, ensure_ascii=False, sort_keys=True)
    digest = hashlib.sha256((version + snapshot).encode()).hexdigest()
    with get_db() as conn:
        row = conn.execute(
            "SELECT * FROM ai_insights WHERE date=? AND time_slot=? AND title=? ORDER BY id DESC LIMIT 1",
            (date, slot, title),
        ).fetchone()
    if row and row["input_hash"] == digest and row["report_json"] and not force:
        return serialize(row)
    evening = slot == "evening"
    prompt = WEEKLY_PROMPT if weekly else EVENING_PROMPT if evening else DAILY_PROMPT
    schema = report_schema(weekly)
    if daily:
        schema["properties"]["findings"]["maxItems"] = 2
    context = dict(context, previous_observation=previous_report(slot, date))
    if as_of:
        context["activity_snapshot_local_time"] = as_of
    source = "\n数据（JSON）：\n" + json.dumps(context, ensure_ascii=False)
    for attempt in range(2 if daily and prepared_report is None else 1):
        try:
            result = prepared_report if prepared_report is not None else json.loads(_call_openai(
                prompt + source, schema=schema, wall_timeout=120 if daily else None,
            ))
            report = validate_report(result, weekly, max_findings=2 if daily else None,
                                     max_chars=452 if daily else None)
            break
        except (ValueError, TypeError, KeyError) as exc:
            logger.warning("Invalid %s observation (%s), attempt %d", slot, type(exc).__name__, attempt + 1)
            if attempt or not daily or prepared_report is not None:
                raise AIServiceError("分析未满足证据或格式要求，请稍后重试", "invalid_observation") from exc
            prompt += "\n上一份格式未通过。重新生成：每个发现都要有标题、正文和至少一条具体证据；没有发现时，留空 findings 并填 summary。"
    report.update({"version": version, "period": context["period"]})
    if as_of:
        report["as_of"] = as_of
    if weekly:
        report["trend"] = [{"date": r["date"], "minutes": r.get("minutes_asleep")} for r in context["calendar"]]
    text = render_text(report)
    queued = _upsert_insight(date, slot, title, text, "observation", report=report,
                            input_hash=digest, input_json=snapshot, prompt_version=version, push=notify)
    if notify and not queued:
        notify_analysis(title, "已生成。打开 Health 首页的「今日观察」查看。", date)
    return {"date": date, "time_slot": slot, "title": title, "content": text,
            "report": report, "prompt_version": version, "available": True}


def load_sleep(days=42):
    from .google_health import get_sleep_history
    from .openai_service import _run, AIServiceError
    try:
        return sleep_rows(_run(get_sleep_history(days)))
    except Exception as exc:
        raise AIServiceError("睡眠数据暂不可用，请稍后重试") from exc


def daily_context(rows, date):
    current = next((r for r in rows if r["date"] == date), None)
    cutoff = (datetime.fromisoformat(date) - timedelta(days=28)).strftime("%Y-%m-%d")
    history = [r for r in rows if cutoff <= r["date"] < date]
    # Compare paired nights to avoid decomposing averages with different coverage.
    paired = [r for r in history if r.get("minutes_in_bed") is not None and r.get("minutes_asleep") is not None]
    clock_fields = ("bedtime_minutes", "wake_minutes")
    clock_nights = [row for row in history if all(row.get(key) is not None for key in clock_fields)]
    clock = comparison(current, clock_nights, clock_fields) if current and clock_nights else {}
    for metric in clock.values():
        for label, value in (("current_time", metric["value"]), ("baseline_median_time", metric["baseline"]["median"])):
            if value is not None:
                hour, minute = divmod(round(value + 720) % 1440, 60)
                metric[label] = f"{hour:02d}:{minute:02d}"
    window = {}
    if current and current.get("minutes_in_bed") and paired:
        bed_mean = mean(r["minutes_in_bed"] for r in paired)
        sleep_mean = mean(r["minutes_asleep"] for r in paired)
        window = {
            "n": len(paired),
            "sleep_delta_minutes": round(current["minutes_asleep"] - sleep_mean, 1),
            "window_delta_minutes": round(current["minutes_in_bed"] - bed_mean, 1),
            "awake_within_window_delta_minutes": round(
                (current["minutes_in_bed"] - current["minutes_asleep"]) - (bed_mean - sleep_mean), 1),
            "note": "睡眠差值=窗口差值-窗口内未睡差值；未睡由同口径卧床减睡眠得到，不混用清醒阶段计时。",
        }
    return {"period": {"start": date, "end": date}, "current": current,
            "baseline_period": {"start": cutoff, "end": date, "end_exclusive": True},
            "comparisons": comparison(current, history) if current else {},
            "paired_sleep_clock": clock,
            "recent_nights": history,
            "sleep_window_decomposition": window,
            "notes": "bedtime_minutes/wake_minutes为当地时间自中午起的分钟数，非午夜。无值为缺失。"}


def generate_sleep_observation(force=False, notify=True):
    from .openai_service import _require_ai_configured, AIServiceError
    _require_ai_configured()
    with LOCK:
        today = datetime.now().strftime("%Y-%m-%d")
        context = daily_context(load_sleep(), today)
        if not context["current"]:
            raise AIServiceError("等待昨夜主睡眠同步", "health_data_not_fresh", 409)
        return _save_report("morning", today, MORNING_TITLE, context, force=force, notify=notify)


def _sleep_for_evening(today):
    from .openai_service import AIServiceError
    with get_db() as conn:
        saved = conn.execute(
            """SELECT report_json, input_json FROM ai_insights WHERE date=? AND
               ((time_slot='morning' AND title=?) OR time_slot='sleep')
               AND report_json IS NOT NULL
               ORDER BY (title=?) DESC, id DESC LIMIT 1""", (today, MORNING_TITLE, MORNING_TITLE),
        ).fetchone()
    result = {}
    if saved:
        result["morning_report"] = json.loads(saved["report_json"])
        night = json.loads(saved["input_json"] or "{}").get("current")
        if night and night.get("date") == today:
            result["main_sleep"] = night
    if "main_sleep" not in result:
        try:
            night = next((row for row in load_sleep(2) if row["date"] == today), None)
            if night:
                result["main_sleep"] = night
        except AIServiceError:
            pass
    return result


def generate_evening_observation(metrics, *, notify=True, captured_at=None):
    from .openai_service import AIServiceError
    from .training_observations import training_context
    from .workout_physiology import get_report
    from .workout_data import get_training_workouts

    with LOCK:
        now = captured_at or datetime.now()
        today = now.strftime("%Y-%m-%d")
        current = metrics if metrics.get("date") == today and not metrics.get("_stale") else {}
        valid = {key: number(current.get(key)) for key in DAY_FIELDS}
        workouts = get_training_workouts(121)
        completed = [workout for workout in workouts
                     if workout["datestr"] == today and workout.get("source") == "local"]
        if not completed and not any(value is not None for value in valid.values()):
            raise AIServiceError("等待今天的活动或训练数据同步", "health_data_not_fresh", 409)
        cutoff = (now.date() - timedelta(days=28)).isoformat()
        history = [row for row in get_cached_health_metrics(29) if cutoff <= row["date"] < today]
        previous_days = [{key: number(row.get(key)) for key in DAY_FIELDS} for row in history]
        context = {"period": {"start": today, "end": today},
                   "today_activity_and_health": valid,
                   "today_vs_personal_baselines": comparison(valid, previous_days, DAY_FIELDS),
                   "baseline_dates": [row["date"] for row in history],
                   "sleep_today": _sleep_for_evening(today)}
        if current.get("_cached_fields"):
            context["cached_fields"] = current["_cached_fields"]
        if completed:
            training = training_context([*completed, *(w for w in workouts if w["datestr"] < today)], [], working_only=True)
            context["today_strength"] = completed
            heart_context = []
            for workout in completed:
                prefix, _, identifier = workout.get("localid", "").partition(":")
                if prefix != "strength" or not identifier:
                    continue
                physiology = get_report(identifier) or {}
                heart = (physiology.get("heart_rate") or {}).get("summary") or {}
                if heart.get("sample_count"):
                    heart_context.append({"session_id": workout["localid"], "coverage": physiology["status"],
                                          **{key: heart.get(key) for key in ("mean_bpm", "max_bpm", "minute_coverage_percent")}})
            if heart_context:
                context["training_heart_rate"] = heart_context
            if training and training["latest_date"] == today:
                context["today_strength"] = training["latest_sessions"]
                exact = sorted(training["exact_same_weight_comparisons"], key=lambda pair: (
                    pair["latest"]["set_count"] == pair["previous"]["set_count"], pair["previous_date"]), reverse=True)
                context["same_weight_comparisons"] = exact[:16]
                context["recorded_peak_comparisons"] = training["recorded_peak_comparisons"][:16]
        return _save_report("evening", today, EVENING_TITLE, context, notify=notify, as_of=now.strftime("%H:%M"))


def weekly_context(rows, end_date, workouts):
    end = datetime.fromisoformat(end_date)
    start = (end - timedelta(days=6)).strftime("%Y-%m-%d")
    baseline_start = (end - timedelta(days=41)).strftime("%Y-%m-%d")
    week = [r for r in rows if start <= r["date"] <= end_date]
    baseline = [r for r in rows if baseline_start <= r["date"] < start]
    indexed = {r["date"]: r for r in week}
    calendar = [dict(indexed.get(d, {"date": d, "minutes_asleep": None})) for d in
                [(end - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(6, -1, -1)]]
    blocks = []
    for i in range(6):
        block_end = (end - timedelta(days=7*i)).strftime("%Y-%m-%d")
        block_start = (end - timedelta(days=7*i+6)).strftime("%Y-%m-%d")
        nights = [r for r in rows if block_start <= r["date"] <= block_end]
        blocks.append({"start": block_start, "end": block_end,
                       "sleep": stats(nights, "minutes_asleep"), "hrv": stats(nights, "hrv")})
    ordered = sorted(week, key=lambda r: r["minutes_asleep"])
    distribution = {
        "shortest_nights": [{"date": r["date"], "minutes": r["minutes_asleep"]} for r in ordered[:2]],
        "remaining_nights_sleep": stats(ordered[2:], "minutes_asleep"),
        "weekday_sleep": stats([r for r in week if datetime.fromisoformat(r["date"]).weekday() < 5], "minutes_asleep"),
        "weekend_sleep": stats([r for r in week if datetime.fromisoformat(r["date"]).weekday() >= 5], "minutes_asleep"),
    }
    return {"period": {"start": start, "end": end_date}, "valid_nights": len(week),
            "baseline_period": {"start": baseline_start, "end": start, "end_exclusive": True},
            "week_stats": {key: stats(week, key) for key in FIELDS},
            "baseline_stats": {key: stats(baseline, key) for key in FIELDS},
            "calendar": calendar, "baseline_nights": baseline,
            "weekly_blocks": blocks, "distribution": distribution,
            "recorded_workouts": [w for w in workouts if baseline_start <= w.get("datestr", "") <= end_date],
            "body": body_log.weekly_summary(start, end_date),
            "notes": "日历中null代表缺失，不代表没睡；bedtime_minutes/wake_minutes是当地时间自中午起的分钟数。训练缓存可能不完整。"}


def generate_weekly_observation(force=False, notify=True):
    from .openai_service import _require_ai_configured
    from .workout_data import get_training_workouts
    _require_ai_configured()
    with LOCK:
        # Exclude the incomplete current day. The report's date is the period end.
        end = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        context = weekly_context(load_sleep(43), end, get_training_workouts(43))
        insufficient = None
        if context["valid_nights"] < 3:
            insufficient = {"status": "insufficient_data", "findings": [],
                            "summary": f"最近七天只有{context['valid_nights']}晚有效主睡眠，暂不足以判断这一周的变化。",
                            "limitations": "缺失日期未计为零睡眠，也不能据此判断这一周睡得更少。"}
        return _save_report("weekly", end, "每周观察", context, weekly=True, force=force, notify=notify,
                            prepared_report=insufficient)
