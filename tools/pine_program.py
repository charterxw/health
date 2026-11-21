#!/usr/bin/env python3
"""Pine's five-day training plan: one source for the templates, the plan's
documentation and the checks the plan must pass.

    python3 tools/pine_program.py          # write pine_program.json, exercises.json, docs
    python3 tools/pine_program.py --check  # verify only; exit 1 on any problem

Each day has a company half and a home half (9 work sets each), plus a
company-only and a home-only version of the whole day (18 sets). The checks
keep the three ways of training a day equivalent.
"""
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "backend" / "app" / "data"
DOC = ROOT / "docs" / "training-programs.md"
REVISION = "2026-11-22"

NEW_EXERCISES = [{
    "id": "flat-dumbbell-bench-press", "name": "平板哑铃卧推", "english_name": "flat dumbbell bench press",
    "aliases": ["哑铃平板卧推"], "equipment": "哑铃、训练凳", "load_mode": "external", "tracking": "reps",
    "training_type": "strength", "muscles": ["胸部"], "primary_muscles": ["chest"], "secondary_muscles": ["triceps", "deltoids"],
    "description": "平板凳上的哑铃卧推，练整个胸部；在家只用哑铃和训练凳就能稳定加重。",
    "instructions": ["训练凳放平，坐在凳头，哑铃立在大腿上；躺下时顺势把哑铃带到胸口两侧。",
                     "双脚踩稳地面，肩胛微收贴住凳面，把哑铃推到胸口上方，掌心朝脚的方向。",
                     "缓慢下放到哑铃接近胸口两侧，上臂和身体约成 45–60 度。",
                     "推回起点，哑铃在上方略靠拢但不相碰。",
                     "做完先把哑铃放回大腿，再坐起来。"],
    "equipment_evidence": "2026-11-22 用户确认家里有哑铃和可调训练凳", "weight_note": "每只哑铃重量。"}]

# (rep_min, rep_max, rest seconds)
RX = {
    "incline-dumbbell-press": (8, 12, 120), "flat-dumbbell-bench-press": (8, 12, 120), "machine-chest-press": (8, 12, 120),
    "machine-shoulder-press": (8, 12, 120), "seated-dumbbell-shoulder-press": (8, 12, 120),
    "assisted-dip": (8, 12, 120), "close-grip-push-up": (8, 15, 90),
    "wide-grip-pulldown": (8, 12, 120), "single-arm-pulldown": (10, 12, 75), "assisted-pull-up": (6, 10, 120),
    "band-assisted-pull-up": (6, 10, 120), "seated-cable-row": (8, 12, 120), "single-arm-dumbbell-row": (8, 12, 75),
    "leg-press": (10, 15, 120), "dumbbell-romanian-deadlift": (8, 12, 120), "bulgarian-split-squat": (8, 12, 75),
    "cable-single-arm-lateral-raise": (12, 20, 45), "dumbbell-lateral-raise": (12, 20, 75),
    "dumbbell-overhead-triceps-extension": (10, 15, 75), "dumbbell-lying-triceps-extension": (10, 15, 75),
    "cable-overhead-triceps-extension": (10, 15, 75), "machine-triceps-extension": (10, 15, 75),
    "machine-preacher-curl": (8, 12, 75), "incline-dumbbell-curl": (10, 15, 75), "bayesian-cable-curl": (10, 15, 45),
    "hammer-curl": (10, 15, 75), "cable-rope-hammer-curl": (10, 15, 75), "dumbbell-concentration-curl": (10, 15, 45),
    "incline-dumbbell-fly": (10, 15, 75), "low-cable-fly": (10, 15, 75),
    "chest-supported-reverse-fly": (12, 20, 60), "cable-reverse-fly": (12, 20, 60), "band-pull-apart": (15, 25, 60),
    "kneeling-cable-crunch": (10, 15, 60), "machine-abdominal-crunch": (10, 15, 60),
    "decline-weighted-crunch": (10, 15, 60), "reverse-crunch": (10, 15, 60),
}

# One category per exercise for the volume checks.
CATEGORY = {
    "incline-dumbbell-press": "胸", "flat-dumbbell-bench-press": "胸", "machine-chest-press": "胸", "assisted-dip": "胸",
    "close-grip-push-up": "胸", "incline-dumbbell-fly": "胸", "low-cable-fly": "胸",
    "machine-shoulder-press": "肩前束", "seated-dumbbell-shoulder-press": "肩前束",
    "cable-single-arm-lateral-raise": "肩中束", "dumbbell-lateral-raise": "肩中束",
    "chest-supported-reverse-fly": "肩后束", "cable-reverse-fly": "肩后束", "band-pull-apart": "肩后束",
    "wide-grip-pulldown": "背·下拉", "single-arm-pulldown": "背·下拉", "assisted-pull-up": "背·下拉", "band-assisted-pull-up": "背·下拉",
    "seated-cable-row": "背·划船", "single-arm-dumbbell-row": "背·划船",
    "dumbbell-overhead-triceps-extension": "三头", "dumbbell-lying-triceps-extension": "三头",
    "cable-overhead-triceps-extension": "三头", "machine-triceps-extension": "三头",
    "machine-preacher-curl": "二头", "incline-dumbbell-curl": "二头", "bayesian-cable-curl": "二头",
    "hammer-curl": "二头", "cable-rope-hammer-curl": "二头", "dumbbell-concentration-curl": "二头",
    "kneeling-cable-crunch": "腹", "machine-abdominal-crunch": "腹", "decline-weighted-crunch": "腹", "reverse-crunch": "腹",
    "leg-press": "腿", "dumbbell-romanian-deadlift": "腿", "bulgarian-split-squat": "腿",
}

GOAL = "整体目标是好看的体型，上半身优先，穿衣好看、脱衣也好看。"
RULES = ("复合动作每组留 1–2 次余力，休息约 2 分钟；孤立动作最后一组练到只剩 0–1 次，休息 60–90 秒。"
         "所有组都做到次数上限后，下次加最小一档重量。第 1–2 周每组留 2–3 次，先熟悉动作。")
DELOAD = ("多个动作持续下降且恢复变差时，减量 5–7 天：组数减少 30%–50%，每组保留 3–4 次余力。"
          "出现持续疼痛、麻木、异常无力或活动受限时，停止相关动作并接受评估。")
FULL = "两部分合在一处完成，约 45–50 分钟；可以把不同部位的动作两两交替做（如弯举配臂屈伸），不要把练同一部位的两个动作配在一起。"

# Per day: company half, home half, company only, home only, as (exercise, work sets).
DAYS = [
    ("a", "A", "周一", "肩宽·胸·三头",
     [("incline-dumbbell-press", 3), ("machine-shoulder-press", 3), ("cable-single-arm-lateral-raise", 3)],
     [("flat-dumbbell-bench-press", 3), ("dumbbell-lateral-raise", 3), ("dumbbell-overhead-triceps-extension", 3)],
     [("incline-dumbbell-press", 3), ("machine-chest-press", 3), ("machine-shoulder-press", 3), ("cable-single-arm-lateral-raise", 6), ("cable-overhead-triceps-extension", 3)],
     [("incline-dumbbell-press", 3), ("flat-dumbbell-bench-press", 3), ("seated-dumbbell-shoulder-press", 3), ("dumbbell-lateral-raise", 6), ("dumbbell-overhead-triceps-extension", 3)]),
    ("b", "B", "周二", "背宽·二头",
     [("wide-grip-pulldown", 3), ("seated-cable-row", 3), ("machine-preacher-curl", 3)],
     [("incline-dumbbell-curl", 3), ("dumbbell-lateral-raise", 3), ("chest-supported-reverse-fly", 3)],
     [("wide-grip-pulldown", 3), ("seated-cable-row", 3), ("machine-preacher-curl", 3), ("bayesian-cable-curl", 3), ("cable-single-arm-lateral-raise", 3), ("cable-reverse-fly", 3)],
     [("band-assisted-pull-up", 3), ("single-arm-dumbbell-row", 3), ("dumbbell-concentration-curl", 3), ("incline-dumbbell-curl", 3), ("dumbbell-lateral-raise", 3), ("chest-supported-reverse-fly", 3)]),
    ("e", "E", "周三", "腹·腿",
     [("leg-press", 3), ("dumbbell-romanian-deadlift", 3), ("kneeling-cable-crunch", 3)],
     [("decline-weighted-crunch", 3), ("reverse-crunch", 3), ("band-pull-apart", 3)],
     [("leg-press", 3), ("dumbbell-romanian-deadlift", 3), ("kneeling-cable-crunch", 3), ("machine-abdominal-crunch", 3), ("reverse-crunch", 3), ("cable-reverse-fly", 3)],
     [("bulgarian-split-squat", 3), ("dumbbell-romanian-deadlift", 3), ("decline-weighted-crunch", 6), ("reverse-crunch", 3), ("band-pull-apart", 3)]),
    ("c", "C", "周四", "肩宽·上胸",
     [("assisted-dip", 3), ("cable-single-arm-lateral-raise", 3), ("cable-overhead-triceps-extension", 3)],
     [("dumbbell-lateral-raise", 3), ("incline-dumbbell-fly", 3), ("dumbbell-lying-triceps-extension", 3)],
     [("assisted-dip", 3), ("cable-single-arm-lateral-raise", 6), ("cable-overhead-triceps-extension", 3), ("low-cable-fly", 3), ("machine-triceps-extension", 3)],
     [("close-grip-push-up", 3), ("dumbbell-lateral-raise", 6), ("dumbbell-overhead-triceps-extension", 3), ("incline-dumbbell-fly", 3), ("dumbbell-lying-triceps-extension", 3)]),
    ("d", "D", "周五", "背宽·二头",
     [("assisted-pull-up", 3), ("seated-cable-row", 3), ("bayesian-cable-curl", 3)],
     [("flat-dumbbell-bench-press", 3), ("hammer-curl", 3), ("dumbbell-lateral-raise", 3)],
     [("assisted-pull-up", 3), ("seated-cable-row", 3), ("machine-chest-press", 3), ("bayesian-cable-curl", 3), ("cable-rope-hammer-curl", 3), ("cable-single-arm-lateral-raise", 3)],
     [("flat-dumbbell-bench-press", 3), ("band-assisted-pull-up", 3), ("single-arm-dumbbell-row", 3), ("incline-dumbbell-curl", 3), ("hammer-curl", 3), ("dumbbell-lateral-raise", 3)]),
]
VARIANTS = [("company", "公司", "在公司完成的一半。", 25, 30), ("home", "家庭", "在家完成的另一半。", 20, 25),
            ("gym", "公司全练", "今天只在公司练，优先用器械和绳索。", 45, 50),
            ("house", "家庭全练", "今天只在家练，用哑铃、训练凳、弹力带和引体杆。", 45, 50)]
SATURDAY = [("dumbbell-lateral-raise", 4), ("chest-supported-reverse-fly", 3), ("dumbbell-overhead-triceps-extension", 3)]
HOME_EQUIPMENT = {"哑铃", "训练凳", "弹力带", "瑜伽垫", "引体杆"}


def load_exercises():
    exercises = json.loads((DATA / "exercises.json").read_text(encoding="utf-8"))
    known = {e["id"] for e in exercises}
    for entry in NEW_EXERCISES:
        if entry["id"] in known:
            exercises = [entry if e["id"] == entry["id"] else e for e in exercises]
        else:
            exercises.append(entry)
    return exercises


def build(catalog):
    def plan(exercise_id, sets, first):
        e = catalog[exercise_id]
        lo, hi, rest = RX[exercise_id]
        warm = 1 if first and e["load_mode"] != "bodyweight" else 0
        item = {"exercise_id": exercise_id, "set_count": sets + warm, "warmup_count": warm, "unit": "lb",
                "rest_seconds": rest, "rep_min": lo, "rep_max": hi, "target_reps": lo}
        if e["load_mode"] != "bodyweight":
            item.update(progression="double", increment=2.5 if "哑铃" in e["equipment"] else 5.0)
        return item

    def moves(rows):
        # One warm-up set for a loaded first movement.
        return [plan(e, n, i == 0) for i, (e, n) in enumerate(rows)]

    notes = GOAL + RULES + DELOAD
    templates = []
    for key, letter, _, focus, *lists in DAYS:
        for (variant, label, purpose, lo, hi), rows in zip(VARIANTS, lists):
            templates.append({"id": f"pine-{key}-{variant}", "name": f"{letter} · {label}｜{focus}",
                              "description": purpose, "notes": (FULL + notes) if variant in ("gym", "house") else notes,
                              "duration_min": lo, "duration_max": hi, "exercises": moves(rows)})
    templates.append({"id": "pine-sat-optional", "name": "周六 · 选练｜肩宽·后束·三头", "description": "周六可练可休，只练小肌群。",
                      "notes": notes, "duration_min": 20, "duration_max": 25, "exercises": moves(SATURDAY)})
    return templates


def check(templates, catalog):
    """Returns a list of problems; empty when the plan holds."""
    T = {t["id"]: t for t in templates}
    problems = []

    def work(tid):
        return [(m["exercise_id"], m["set_count"] - m["warmup_count"]) for m in T[tid]["exercises"]]

    def volume(tids):
        v = Counter()
        for tid in tids:
            for e, n in work(tid):
                v[CATEGORY[e]] += n
        return v

    for tid, t in T.items():
        for e, _ in work(tid):
            if e not in catalog:
                problems.append(f"{tid}: 动作 {e} 不在动作库")
            elif any(x in tid for x in ("home", "house", "sat")) and not set(catalog[e]["equipment"].split("、")) <= HOME_EQUIPMENT:
                problems.append(f"{tid}: {catalog[e]['name']} 需要 {catalog[e]['equipment']}")
    ways = {"公司+家庭": lambda d: [f"pine-{d}-company", f"pine-{d}-home"],
            "只公司": lambda d: [f"pine-{d}-gym"], "只家庭": lambda d: [f"pine-{d}-house"]}
    expected = {"胸": 15, "背·下拉": 6, "背·划船": 6, "三头": 9, "腹": 9}
    for name, ids in ways.items():
        week = volume([x for key, *_ in DAYS for x in ids(key)])
        for category, n in expected.items():
            if week[category] != n:
                problems.append(f"{name}: 每周{category} {week[category]} 组，应为 {n}")
        for key, letter, *_ in DAYS:
            total = sum(n for tid in ids(key) for _, n in work(tid))
            if total != 18:
                problems.append(f"{name}: {letter} 日 {total} 组，应为 18")
    for key, letter, *_ in DAYS:
        days = {name: volume(ids(key)) for name, ids in ways.items()}
        if len({tuple(sorted(v.items())) for v in days.values()}) != 1:
            problems.append(f"{letter} 日各练法部位组数不一致：{days}")
        company, home = {e for e, _ in work(f"pine-{key}-company")}, {e for e, _ in work(f"pine-{key}-home")}
        if company & home:
            problems.append(f"{letter} 日公司和家里重复：{sorted(company & home)}")
        for tid in [f"pine-{key}-{v}" for v, *_ in VARIANTS]:
            ids_ = [e for e, _ in work(tid)]
            if len(ids_) != len(set(ids_)):
                problems.append(f"{tid}: 同一场里动作重复")
    return problems


def week_table(templates):
    T = {t["id"]: t for t in templates}
    rows = []
    for name, suffixes in [("公司 + 家庭", ["company", "home"]), ("只公司", ["gym"]), ("只家庭", ["house"])]:
        v = Counter()
        for key, *_ in DAYS:
            for s in suffixes:
                for m in T[f"pine-{key}-{s}"]["exercises"]:
                    v[CATEGORY[m["exercise_id"]]] += m["set_count"] - m["warmup_count"]
        rows.append((name, v))
    order = ["肩中束", "肩后束", "肩前束", "胸", "背·下拉", "背·划船", "二头", "三头", "腹", "腿"]
    lines = ["| 练法 | " + " | ".join(order) + " |", "|" + "---|" * (len(order) + 1)]
    lines += [f"| {name} | " + " | ".join(str(v[c]) for c in order) + " |" for name, v in rows]
    return "\n".join(lines)


def document(templates, catalog):
    T = {t["id"]: t for t in templates}

    def session(tid):
        out = []
        for m in T[tid]["exercises"]:
            e = catalog[m["exercise_id"]]
            sets = m["set_count"] - m["warmup_count"]
            warm = f"（另加 {m['warmup_count']} 组热身）" if m["warmup_count"] else ""
            out.append(f"- {e['name']}：{sets} × {m['rep_min']}–{m['rep_max']}{warm}，休息 {m['rest_seconds']} 秒")
        return "\n".join(out)

    parts = [f"# Pine 训练计划（{REVISION} 版）", "",
             "由 `tools/pine_program.py` 生成；改计划请改脚本后重新生成，`--check` 会验证组数和三种练法是否一致。", "",
             "## 目标", "", GOAL, "",
             "## 一周安排", "",
             "周一 A、周二 B、周三 E、周四 C、周五 D；周六选练（可练可休），周日休息。每天 18 个工作组，可以三种方式完成：",
             "", "- **公司 + 家庭**：公司一半（9 组，约 25–30 分钟）+ 家里一半（9 组，约 20–25 分钟）。",
             "- **只公司**：一场 18 组，约 45–50 分钟，优先器械和绳索。",
             "- **只家庭**：一场 18 组，约 45–50 分钟，只用哑铃、训练凳、弹力带和引体杆。", "",
             "五天为一轮（90 组），App 按完成的组数推进；周六选练不计入一轮。", "",
             "## 每周组数", "", week_table(templates), "",
             "胸 15 组里公司以上斜为主、家里用平板哑铃卧推，两种卧推分开记录，「上次成绩」互不干扰。", ""]
    for key, letter, weekday, focus, *_ in DAYS:
        parts += [f"## {weekday} {letter} · {focus}", ""]
        for (variant, label, *_rest) in VARIANTS:
            t = T[f"pine-{key}-{variant}"]
            parts += [f"### {label}（约 {t['duration_min']}–{t['duration_max']} 分钟）", "", session(t["id"]), ""]
    parts += ["## 周六 · 选练（肩宽·后束·三头）", "", session("pine-sat-optional"), "",
              "恢复偏低、或这周五天都练满时可以直接休息；练的话每组留 2–3 次余力，不练到力竭。", "",
              "## 训练规则", "", "- " + RULES.replace("。", "。\n- ").rstrip("- \n"), "",
              "## 减量与停止", "", DELOAD, "",
              "## 体态、饮食与睡眠", "",
              "- 每日体态 5–8 分钟：前臂靠墙滑手、坐姿胸椎伸展、门框胸肌拉伸（每侧）、下巴轻收。动作舒适、正常呼吸。",
              "- 工作中每 45–60 分钟起身 1–2 分钟。",
              "- 蛋白质每公斤体重约 1.6 克，分三四顿。",
              "- 增肌速度：每月体重增加 0.5%–1%；每周至少 3 次晨起空腹称重，看趋势而不是单次。",
              "- 睡眠目标 8 小时。",
              "- 腰围每周量一次，臂围和肩围每月一次；对比照片每月一次，同样光线和站姿。", "",
              "## 更新记录", "",
              f"- {REVISION}：胸每周 9 → 15 组（家里新增平板哑铃卧推，只公司用器械推胸），腹 12 → 9 组；"
              "周二公司的单手下拉换成坐姿绳索划船，背改为下拉 6 组 + 划船 6 组；A 日改名「肩宽·胸·三头」，D 日改名「背宽·二头」；"
              "计划说明加回减量规则并写入整体目标。",
              "- 2026-11-20：五天计划（A 肩、B 背、E 腹腿、C 肩、D 背），每天公司 + 家庭两半，或只公司 / 只家庭；取代 2.6 版。", ""]
    return "\n".join(parts)


def main():
    exercises = load_exercises()
    catalog = {e["id"]: e for e in exercises}
    templates = build(catalog)
    problems = check(templates, catalog)
    if f'PINE_REVISION = "{REVISION}"' not in (ROOT / "backend" / "app" / "strength_training.py").read_text(encoding="utf-8"):
        problems.append(f"strength_training.PINE_REVISION 应为 {REVISION}，否则线上模板不会更新")
    if "--check" in sys.argv:
        current = json.loads((DATA / "pine_program.json").read_text(encoding="utf-8"))
        if current != templates:
            problems.append("pine_program.json 与脚本不一致，请重新生成")
        if DOC.read_text(encoding="utf-8") != document(templates, catalog):
            problems.append("docs/training-programs.md 与脚本不一致，请重新生成")
    if problems:
        print("\n".join(problems))
        sys.exit(1)
    if "--check" not in sys.argv:
        (DATA / "exercises.json").write_text(json.dumps(exercises, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (DATA / "pine_program.json").write_text(json.dumps(templates, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        DOC.write_text(document(templates, catalog), encoding="utf-8")
    print(f"{len(templates)} templates OK")
    print(week_table(templates))


if __name__ == "__main__":
    main()
