"""Compare recorded exercise performance before asking for a short interpretation."""
from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timedelta
import hashlib
import json
import unicodedata

from .database import get_db
from .observations import LOCK, number, render_text, report_schema, serialize, validate_report

VERSION = "training-observations-v1"

PROMPT = """生成中文「训练发现」，通常一个发现，最多两个独立发现，正文总计不超过300字。
标题直接说结论，每条用2-3句解释意义，不写固定栏目，不复述训练清单。正文每条最多两个关键数字，具体组次、日期放evidence。
优先解释最新一次训练与同动作历史的差别：是重量变化、同重量次数变化、组数变化，还是组间掉次数。
代码已计算exact_same_weight_comparisons和recorded_peak_comparisons；不要把总吨位或组数上升直接当成进步。
recorded_peak是记录中最高重量的组，不保证是工作组，更不是最大力量。重量变小只说明选用负重不同，不能断言能力下降。
相隔较久的记录也可作参照，但必须在正文点明间隔，不能称连续趋势，也不能把没有记录的日期当成停训。
两个动作都变轻时可合并成一个训练结构发现；另一个发现只有确实独立且有意义时才保留。
同重量各组次数相同只说明记录稳定，不能说余力充足/可以加重，不能凭记录推断动作质量、力竭、热身组。
辅助动作重量是辅助量：加辅助通常降低难度，绝不能算成实际负重增加或力量进步；不与外加负重合并。
哑铃单侧/双侧、杠铃是否含杆重未知，按原记录口径比较，不擅自翻倍或补杆重。单位、动作或负重模式不同不可合并。
恢复数据仅限与训练当天及次日准确配对的数据；只在确实改变主要结论时引用，不能把共现归因于训练。
不强制写恢复状态、过度训练风险、下次训练建议；不因缺少历史就填充通用训练处方。
严禁实验、习惯跟进、打卡、要求补记数据、建议执行反馈；不按HRV开精确减量比例。
证据不足以评价进退时，可以解释当次记录中的重要结构；如果只能复述清单则findings=[]并简短说暂无可靠新发现。
与上一份结构化分析对照；输入相同会由系统复用，不要为了新颖编造变化。
有发现时summary留空；局限放limitations，但关键局限（如52天记录间隔）必须在相关正文中交代。
每个发现的evidence必须给出动作名、日期、同口径重量/次数/组数和比较限制。只使用下列数据。
"""


def unit_name(value):
    value = str(value or "").strip().lower()
    return {"lbs": "lb", "pounds": "lb", "磅": "lb", "公斤": "kg", "千克": "kg"}.get(value, value)


def movement_key(value):
    return "".join(unicodedata.normalize("NFKC", str(value or "")).split())


def normalized_workouts(workouts, *, working_only=False):
    result, seen = [], set()
    for workout in sorted(workouts, key=lambda w: w.get("datestr", ""), reverse=True):
        date = workout.get("datestr", "")
        if not date:
            continue
        item = {"date": date, "session_id": workout.get("localid"), "title": workout.get("title", ""),
                "duration_minutes": workout.get("duration_minutes"), "movements": []}
        for order, movement in enumerate(workout.get("movements", []), 1):
            name = movement.get("name", "")
            assisted = movement.get("exetype") == "help" or any(t in name.lower() for t in ("辅助", "assisted", "assistance"))
            bodyweight = movement.get("exetype") in {"self", "bodyweight"}
            sets = []
            for index, s in enumerate(movement.get("sets", []), 1):
                if not s.get("done", True) or (working_only and s.get("warmup") is True):
                    continue
                reps = number(s.get("reps"))
                weight = number(s.get("weight"), zero_valid=True)
                if reps is None or weight is None or weight < 0:
                    continue
                mode = "assistance" if assisted else "bodyweight" if bodyweight or s.get("selfWeight") else "recorded_load"
                sets.append({"index": index, "weight": weight, "unit": unit_name(s.get("unit")),
                             "reps": reps, "rpe": number(s.get("rpe")), "mode": mode,
                             "warmup": s.get("warmup")})
            if not sets:
                continue
            groups = defaultdict(list)
            for s in sets:
                groups[(s["unit"], s["mode"], s["weight"])].append(s)
            loads = [{"unit": unit, "mode": mode, "weight": weight,
                      "reps": [s["reps"] for s in group], "set_indices": [s["index"] for s in group],
                      "set_count": len(group)} for (unit, mode, weight), group in groups.items()]
            peaks = []
            for unit, mode in sorted({(s["unit"], s["mode"]) for s in sets}):
                if mode != "recorded_load" or not unit:
                    continue
                peaks.append(max((g for g in loads if g["unit"] == unit and g["mode"] == mode), key=lambda g: g["weight"]))
            item["movements"].append({"name": name, "key": movement_key(name), "order": order,
                                       "sets": sets, "load_groups": loads, "recorded_peaks": peaks})
        if item["movements"]:
            identity = (date, str(item["session_id"])) if item["session_id"] is not None else json.dumps(item, sort_keys=True)
            if identity not in seen:
                seen.add(identity)
                result.append(item)
    return result


def training_context(workouts, metrics, *, working_only=False):
    sessions = normalized_workouts(workouts, working_only=working_only)
    if not sessions:
        return None
    latest_date = sessions[0]["date"]
    cutoff = (datetime.fromisoformat(latest_date) - timedelta(days=119)).strftime("%Y-%m-%d")
    sessions = [s for s in sessions if cutoff <= s["date"] <= latest_date]
    latest = [s for s in sessions if s["date"] == latest_date]
    previous = [s for s in sessions if s["date"] < latest_date]
    exact, peaks = [], []
    for session in latest:
        for movement in session["movements"]:
            matches = [(s, m) for s in previous for m in s["movements"] if m["key"] == movement["key"]]
            for old, other in matches[:5]:
                base = {"movement": movement["name"], "latest_date": latest_date, "previous_date": old["date"],
                        "gap_days": (datetime.fromisoformat(latest_date) - datetime.fromisoformat(old["date"])).days,
                        "latest_order": movement["order"], "previous_order": other["order"]}
                for group in movement["load_groups"]:
                    for old_group in other["load_groups"]:
                        if (group["weight"], group["unit"], group["mode"]) == (old_group["weight"], old_group["unit"], old_group["mode"]) and group["unit"]:
                            exact.append(dict(base, latest=group, previous=old_group))
                for peak in movement["recorded_peaks"]:
                    for old_peak in other["recorded_peaks"]:
                        if peak["unit"] == old_peak["unit"]:
                            peaks.append(dict(base, latest=peak, previous=old_peak,
                                              recorded_weight_delta=round(peak["weight"] - old_peak["weight"], 2),
                                              identical_reps_and_set_count=peak["reps"] == old_peak["reps"]))
    metric_index = {m["date"]: m for m in metrics if m.get("date")}
    paired = []
    for date in sorted({s["date"] for s in sessions}, reverse=True)[:6]:
        next_date = (datetime.fromisoformat(date) + timedelta(days=1)).strftime("%Y-%m-%d")
        pair = {"training_date": date}
        for label, day in (("training_day", date), ("next_wake_day", next_date)):
            row = metric_index.get(day, {})
            pair[label] = {"date": day, **{k: number(row.get(k)) for k in ("sleep_hours", "hrv", "resting_hr")}}
        paired.append(pair)
    return {"period": {"start": cutoff, "end": latest_date}, "latest_date": latest_date,
            "recorded_session_count": len(sessions), "latest_sessions": latest, "history_sessions": previous,
            "exact_same_weight_comparisons": exact, "recorded_peak_comparisons": peaks,
            "recovery_pairs": paired,
            "notes": "120日为历史检索范围，不代表每日记录完整。日期空白不是停训；未标记warmup时不能猜测。不同器械或记重口径仍可能不同。"}


def generate_training_observation(force=False, notify=True):
    from .openai_service import _require_ai_configured, _get_recent_metrics, _call_openai, AIServiceError, get_ai_model
    from .workout_data import get_training_workouts
    from .notifications import notify_analysis
    _require_ai_configured()
    with LOCK:
        workouts = get_training_workouts(366)
        app_dates = [workout["datestr"] for workout in workouts if workout.get("source") == "local"]
        if app_dates:
            latest_app_date = max(app_dates)
            workouts = [workout for workout in workouts
                        if workout.get("source") == "local" or workout["datestr"] < latest_app_date]
        if not normalized_workouts(workouts):
            raise AIServiceError("暂无可分析的重量和次数记录", "training_data_unavailable", 409)
        try:
            metrics = _get_recent_metrics(121)
        except AIServiceError:
            metrics = []
        context = training_context(workouts, metrics)
        snapshot = json.dumps(context, ensure_ascii=False, sort_keys=True)
        digest = hashlib.sha256((VERSION + snapshot).encode()).hexdigest()
        with get_db() as conn:
            cached = conn.execute("SELECT * FROM training_analysis WHERE input_hash=? AND prompt_version=? "
                                  "ORDER BY id DESC LIMIT 1", (digest, VERSION)).fetchone()
            previous = conn.execute("SELECT date, report_json FROM training_analysis WHERE report_json IS NOT NULL "
                                    "ORDER BY date DESC, id DESC LIMIT 1").fetchone()
        if cached and not force:
            return serialize(cached)
        schema = report_schema(weekly=True)
        schema["properties"]["findings"]["maxItems"] = 2
        request = dict(context, previous_observation=json.loads(previous["report_json"]) if previous else None)
        try:
            report = validate_report(json.loads(_call_openai(
                PROMPT + "\n训练证据（JSON）：\n" + json.dumps(request, ensure_ascii=False), schema=schema)), weekly=True)
            if len(report["findings"]) > 2 or len(render_text(report)) > 300:
                raise ValueError("Training observation too long")
        except (ValueError, TypeError, KeyError) as exc:
            raise AIServiceError("训练发现未满足篇幅或证据要求，请稍后重试", "invalid_observation") from exc
        report.update({"version": VERSION, "period": context["period"], "session_date": context["latest_date"]})
        content = render_text(report)
        today = datetime.now().strftime("%Y-%m-%d")
        with get_db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            if conn.execute("SELECT 1 FROM strength_session_deletions WHERE instr(?, id)>0 LIMIT 1", (snapshot,)).fetchone():
                raise AIServiceError("训练记录已删除，请重新生成分析", "training_data_changed", 409)
            saved = conn.execute("""INSERT INTO training_analysis
                (date,summary,trends,risks,recommendations,provider,model,report_json,input_hash,input_json,prompt_version)
                VALUES (?,?,?,?,?,'chatgpt_plan',?,?,?,?,?)""",
                (today, content, None, None, None, get_ai_model(), json.dumps(report, ensure_ascii=False), digest, snapshot, VERSION))
            conn.commit()
        if notify and report["status"] == "finding":
            notify_analysis("训练发现", content, today)
        return {"id": saved.lastrowid, "date": today, "summary": content, "report": report, "model": get_ai_model()}
