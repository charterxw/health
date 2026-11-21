import Foundation
import HealthCore

struct Failure: Error, CustomStringConvertible { let description: String }
func check(_ value: @autoclosure () throws -> Bool, _ text: String) throws { if try !value() { throw Failure(description: text) } }
func rejects(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw Failure(description: "Expected invalid operation to fail") }

@main struct NativeCoreChecks {
    static let exercise: JSONValue = ["id":"test-row","name":"划船","load_mode":"external","equipment":"绳索","tracking":"reps","training_type":"strength"]
    static let timed: JSONValue = ["id":"posture-test","name":"保持","load_mode":"bodyweight","tracking":"duration","training_type":"mobility"]
    static func make(_ ex: JSONValue = exercise, plan: JSONValue = ["exercise_id":"test-row","set_count":3,"rest_seconds":90,"unit":"lb","target_reps":8]) throws -> JSONValue {
        try NativeTraining.start(template:["id":"test-template","name":"测试训练","exercises":[plan]],catalog:[ex],history:[],now:Date().addingTimeInterval(-300),timezone:"America/New_York")
    }
    static func completed(_ m: JSONValue, count: Int = 3, reps: Int = 12, weight: Double = 50, missing: Bool = false) -> JSONValue {
        var movement = m
        movement["sets"] = .array((0..<count).map { i in NativeTraining.newSet(["weight":.number(weight),"reps":.number(Double(reps)),"completed_at":missing && i == count - 1 ? .null : NativeDate.stamp(Date().addingTimeInterval(-3600)),"warmup":false]) })
        return ["id":"prior","template_id":"test-template","started_at":NativeDate.stamp(Date().addingTimeInterval(-4000)),"ended_at":NativeDate.stamp(Date().addingTimeInterval(-3500)),"status":"completed","exercises":[movement]]
    }
    static func nativeCompletion() throws {
        var s = try make(); try rejects { _ = try NativeTraining.toggle(s,movement:0,set:0) }
        s["exercises"][0]["sets"][0]["weight"] = 50
        s = try NativeTraining.toggle(s,movement:0,set:0)
        try check(NativeTraining.progress(s).done == 1,"Prefilled unchecked sets counted as performed")
        try check(s["rest_set_id"] == s["exercises"][0]["sets"][0]["id"],"Rest lost its originating set")
        let undone = try NativeTraining.toggle(s,movement:0,set:0)
        try check(undone["rest_until"].isNull && undone["rest_set_id"].isNull,"Undo did not clear its own rest")
    }
    static func resumeMovement() throws {
        var s = try make(); let second = s["exercises"][0]; s["exercises"] = .array([second, second, second])
        try check(NativeTraining.resumeIndex(s) == 0, "Fresh workout did not start at movement 1")
        for i in 0..<3 { s["exercises"][0]["sets"][i]["weight"] = 50; s = try NativeTraining.toggle(s, movement: 0, set: i, at: Date().addingTimeInterval(Double(i))) }
        s["exercises"][1]["sets"][0]["weight"] = 50; s = try NativeTraining.toggle(s, movement: 1, set: 0, at: Date().addingTimeInterval(10))
        try check(NativeTraining.resumeIndex(s) == 1, "Resume left the movement being recorded")
        for i in 1..<3 { s["exercises"][1]["sets"][i]["weight"] = 50; s = try NativeTraining.toggle(s, movement: 1, set: i, at: Date().addingTimeInterval(Double(10 + i))) }
        try check(NativeTraining.resumeIndex(s) == 2, "Resume did not move past a finished movement")
    }
    static func strengthIndex() throws {
        let now = Date(), week = now.addingTimeInterval(-3 * 86400)
        func session(_ days: Double, _ lifts: [(String, String, Double, Double)]) -> JSONValue {
            let at = NativeDate.stamp(now.addingTimeInterval(-days * 86400))
            return ["id": .string(UUID().uuidString), "status": "completed", "started_at": at, "exercises": .array(lifts.map { id, mode, weight, reps -> JSONValue in
                ["exercise_id": .string(id), "name": .string(id), "load_mode": .string(mode), "unit": "lb", "tracking": "reps", "training_type": "strength",
                 "sets": [["weight": .number(weight), "reps": .number(reps), "completed_at": at, "warmup": false], ["weight": 200, "reps": 10, "completed_at": at, "warmup": true]]]
            })]
        }
        let rows = [session(10, [("press", "external", 50, 10), ("row", "external", 100, 8), ("dip", "bodyweight", 0, 10)]),
                    session(1, [("press", "external", 50, 12), ("row", "external", 100, 8), ("dip", "bodyweight", 0, 9), ("new", "external", 30, 10)])]
        let result = NativeDays.strength(sessions: rows, from: week, to: now.addingTimeInterval(60))
        try check(result.lifts.count == 3 && result.newCount == 1, "Strength index compared lifts without history")
        try check(abs((result.lifts.first { $0.id == "press|external" }?.change ?? 0) - (50 * 1.4 / (50 * (1 + 10.0 / 30)) - 1)) < 1e-9, "Estimated 1RM progress is wrong")
        try check(result.change == 0 && result.records == 1, "Median strength change ignored a flat lift")
    }
    static func postureStreak() throws {
        // 2026-11-16 is a Monday; planned Mon/Tue/Thu/Sun.
        let done: Set<String> = ["2026-11-16", "2026-11-17", "2026-11-19", "2026-11-22"]
        try check(NativeDays.postureStreak(done: done, today: "2026-11-22") == (4, "2026-11-16"), "Unplanned rest days broke the posture streak")
        try check(NativeDays.postureStreak(done: done, today: "2026-11-23").count == 4, "Today broke the streak before it was done")
        try check(NativeDays.postureStreak(done: done, today: "2026-11-24").count == 0, "A missed planned day kept the streak")
        try check(NativeDays.postureStreak(done: done.union(["2026-11-18"]), today: "2026-11-22").count == 5, "An extra practice day did not count")
    }
    static func weightRate() throws {
        // +0.02 kg a day from 70 kg: 0.6 kg a month, about 0.85 %.
        let rows = (0..<20).map { d in (date: String(format: "2026-11-%02d", d + 1), kg: 70 + 0.02 * Double(d)) }
        let rate = NativeDays.weightRate(rows, today: "2026-11-20")
        try check(rate.map { abs($0.kgPerMonth - 0.6) < 1e-6 && abs($0.percentPerMonth - 0.6 / $0.average * 100) < 1e-6 } == true, "Weight trend slope is wrong")
        try check(NativeDays.weightRate(Array(rows.suffix(5)), today: "2026-11-20") == nil, "Weight trend guessed from too few weigh-ins")
    }
    static func stall() throws {
        let now = Date()
        func session(_ days: Double, weight: Double, reps: [Double]) -> JSONValue {
            let at = NativeDate.stamp(now.addingTimeInterval(-days * 86400))
            return ["id": .string(UUID().uuidString), "status": "completed", "started_at": at, "exercises": [["exercise_id": "press", "load_mode": "external", "unit": "lb",
                "sets": .array(reps.map { ["weight": .number(weight), "reps": .number($0), "completed_at": at, "warmup": false] })]]]
        }
        let flat = [session(12, weight: 50, reps: [10, 9, 8]), session(9, weight: 50, reps: [10, 9, 8]), session(5, weight: 50, reps: [9, 9, 8]), session(2, weight: 50, reps: [10, 9, 8])]
        try check(NativeDays.stallCount(exerciseID: "press", loadMode: "external", history: flat, before: now) == 3, "Three sessions without progress were not counted")
        let growing = flat + [session(1, weight: 50, reps: [10, 10, 8])]
        try check(NativeDays.stallCount(exerciseID: "press", loadMode: "external", history: growing, before: now) == 0, "More reps at the same weight was not progress")
        let reset = flat + [session(1, weight: 45, reps: [12, 12, 12])]
        try check(NativeDays.stallCount(exerciseID: "press", loadMode: "external", history: reset, before: now) == 0, "A deliberate reset kept the stall warning")
    }
    static func bedtime() throws {
        // Wake 07:30 New York (12:30Z in November), need 7.5 h, 20 min awake in bed.
        let nights: [JSONValue] = (1...7).map { d in
            ["date": .string(String(format: "2026-11-%02d", d + 10)), "is_nap": false, "minutes_asleep": 420, "minutes_in_bed": 440,
             "end_time": .string(String(format: "2026-11-%02dT12:30:00Z", d + 10))]
        }
        try check(NativeDays.bedtime(sleeps: nights, needHours: 7.5, timezone: "America/New_York") == 23 * 60 + 40, "Bedtime ignored wake time, need or awake time")
        try check(NativeDays.bedtime(sleeps: Array(nights.prefix(4)), needHours: 7.5, timezone: "America/New_York") == nil, "Bedtime guessed from too few nights")
    }
    static func dayGlyphs() throws {
        let whole = NativeDaySession(id: "w", title: "B · 公司全练｜背宽·二头", start: nil, end: nil, ratio: 1, posture: false)
        let half = NativeDaySession(id: "h", title: "B · 公司｜背宽·二头", start: nil, end: nil, ratio: 1, posture: false)
        try check(NativeDays.halves([whole]) == [1, 1], "A whole-day session did not fill both halves")
        try check(NativeDays.halves([half]) == [1], "One half filled both halves")
        try check(NativeDays.focus(dayKey: "2026-11-23", sessions: [half], serverTag: "") == "背", "Day focus lost its letter")
        try check(NativeDays.focus(dayKey: "2026-11-21", sessions: [], serverTag: "") == "选", "Saturday is not optional")
        try check(NativeDays.focus(dayKey: "2026-11-22", sessions: [], serverTag: "") == "休", "Sunday is not rest")
    }
    static func timers() throws {
        let now=Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970));var s=try make();s["exercises"][0]["sets"][0]["weight"]=50
        s=try NativeTraining.toggle(s,movement:0,set:0,at:now)
        s=NativeTraining.pause(s,at:now.addingTimeInterval(10))
        try check(NativeTraining.snapshot(s,movement:0)?.restRemaining(at:now.addingTimeInterval(600)) == 80,"Paused native rest kept running")
        try rejects { _=try NativeTraining.toggle(s,movement:0,set:1) }
        s=NativeTraining.pause(s,at:now.addingTimeInterval(70))
        try check(NativeTraining.snapshot(s,movement:0)?.restRemaining(at:now.addingTimeInterval(70)) == 80,"Resume did not preserve the rest remainder")
        s=NativeTraining.finish(s,at:now.addingTimeInterval(90))
        try check(s["rest_until"].isNull && s["status"].text == "completed","Finish retained rest state")
    }
    static func timedMobility() throws {
        let s=try make(timed,plan:["exercise_id":"posture-test","set_count":2,"target_seconds":30,"unit":"kg"])
        let row=s["exercises"][0]["sets"][0]
        try check(row["weight"].isNull && row["reps"].isNull && row["duration_seconds"].integer == 30,"Timed exercise became a repetition exercise")
        let done=try NativeTraining.toggle(s,movement:0,set:0)
        try check(NativeTraining.progress(done).done == 1,"Posture progress missing")
        let p=NativeTraining.prescription(s["exercises"][0],history:[],before:Date(),timezone:"America/New_York")
        try check(p.isNull,"Mobility received automatic load progression")
    }
    static func mixedProgress() throws {
        var s=try make();var m=NativeTraining.movement(timed,plan:["set_count":1,"target_seconds":30]);m["sets"][0]["completed_at"]=NativeDate.stamp()
        s["exercises"] = .array(s["exercises"].array+[m]);try check(NativeTraining.progress(s).planned == 3 && NativeTraining.progress(s).done == 0,"Mobility inflated strength working sets")
    }
    static func doubleProgression() throws {
        var m=(try make())["exercises"][0]
        var config:JSONValue=["exercise_id":"test-row","load_mode":"external","unit":"lb","rep_min":8,"rep_max":12,"work_sets":3,"increment":5]
        let p=NativeTraining.prescription(config,history:[completed(m)],before:Date(),timezone:"America/New_York")
        try check(p["action"].text == "increase" && p["weight"].number == 55 && p["reps"].integer == 8,"Full upper-range completion did not progress")
        let held=NativeTraining.prescription(config,history:[completed(m,missing:true)],before:Date(),timezone:"America/New_York")
        try check(held["action"].text == "hold" && held["weight"].number == 50,"Unfinished sets advanced the load")
        config["load_mode"]="assistance";m["load_mode"]="assistance"
        let assistance=NativeTraining.prescription(config,history:[completed(m)],before:Date(),timezone:"America/New_York")
        try check(assistance["action"].text == "less_assistance" && assistance["weight"].number == 45,"Assistance progressed in the wrong direction")
    }
    static func templateBaseline() throws {
        let baseline=NativeDate.stamp(Date().addingTimeInterval(-100))
        let plan:JSONValue=["exercise_id":"test-row","set_count":2,"warmup_count":0,"unit":"lb","set_targets":[["weight":35,"reps":10],["weight":40,"reps":8]],"targets_updated_at":baseline,"progression":"double"]
        let previous=completed((try make())["exercises"][0])
        let s=try NativeTraining.start(template:["id":"test-template","name":"预设","exercises":[plan]],catalog:[exercise],history:[previous])
        try check(s["exercises"][0]["sets"][0]["weight"].number == 35,"History before edited targets overrode the new baseline")
        try check(s["exercises"][0]["prescription"].isNull,"Old history progressed a new template baseline")
        let remaining=try NativeTraining.start(template:["id":"test-template","name":"补练","exercises":[plan]],catalog:[exercise],history:[],remaining:[["exercise_id":"test-row","target":1]])
        try check(remaining["exercises"][0]["sets"].array.count == 1 && remaining["exercises"][0]["sets"][0]["weight"].number == 40,"Remaining plan did not retain the last prescribed work set")
    }
    static func editedTargets() throws {
        let plan: JSONValue = ["exercise_id":"test-row", "set_count":2, "warmup_count":0, "unit":"lb", "set_targets":[["weight":35,"reps":10],["weight":40,"reps":8]], "targets_updated_at":NativeDate.stamp()]
        let next = NativeTraining.changePlan(plan,key:"warmup_count",value:1)
        try check(next["set_targets"][0]["weight"].isNull && next["set_targets"][1]["weight"].number == 35,"Adding warmups shifted a working-set target into warmup data")
        let reps = NativeTraining.changePlan(next,key:"target_reps",value:12)
        try check(reps["set_targets"][0]["reps"].integer == 8 && reps["set_targets"][1]["reps"].integer == 12,"Default repetitions overwrote warmup prescriptions")
    }
    static func mergeAndInflightEdits() throws {
        let sent=try make();var local=NativeRecord(session:sent,version:1,dirty:true)
        local.session["notes"]="Edited while saving"
        let response:JSONValue=["session":sent,"version":2]
        let ack=NativeRecordMerge.acknowledge(local,sent:sent,response:response)
        try check(ack.dirty && ack.version == 2 && ack.session["notes"].text == "Edited while saving","Acknowledgement lost a concurrent local edit")
        let merged=NativeRecordMerge.merge([local.id:local],remote:[response],deleted:[])
        try check(merged[local.id]?.session == local.session,"Remote refresh overwrote an unsaved local draft")
        try check(NativeRecordMerge.merge(merged,remote:[response],deleted:[local.id]).isEmpty,"A deletion marker resurrected a dirty draft")
        let roundtrip=try JSONDecoder().decode(NativeRecord.self,from:JSONEncoder().encode(ack))
        try check(roundtrip == ack,"Native disk record lost sync metadata")
    }
    static func nullsAndUnknownFields() throws {
        let value:JSONValue=["missing":nil,"zero":0,"flag":false,"future":["stable":42]]
        let decoded=try JSONValue.read(value.data())
        try check(decoded == value && decoded["missing"].number == nil && decoded["zero"].number == 0,"Missing values became zero or metadata was lost")
        try check(NativeTraining.convert(100,from:"lb",to:"kg").number == 45.36,"Unit conversion drift")
        var m=(try make())["exercises"][0];m["sets"][0]["reps"]=0;try check(!NativeTraining.valid(m,m["sets"][0]),"Zero repetitions accepted")
    }
    static func recordsTimeline() throws {
        var s = try make(); s["exercises"][0]["sets"][0]["weight"] = 50
        s = try NativeTraining.toggle(s,movement:0,set:0); s = NativeTraining.finish(s)
        let archive: JSONValue = ["training":[["localid":"old-1","datestr":"2026-10-01","time":"09:00","title":"档案训练","movements":[["name":"下拉","sets":[]]]]],"exercises":[["date":"2026-10-02","time":"18:00","name":"WALKING","duration_minutes":25],["date":"2026-10-03","time":"18:00","name":"户外骑行","duration_minutes":20]]]
        let rows = NativeTimeline.items(records:[NativeRecord(session:s,version:1)],archive:archive)
        try check(rows.count == 4,"The unified timeline dropped an existing source")
        try check(rows.first(where:{$0.source == "app"})?.detail.contains("1/3 工作组") == true,"Unchecked sets inflated a timeline summary")
        try check(NativeTimeline.filter(rows,kind:"walk").count == 1,"The walking category did not match the device archive")
        try check(NativeTimeline.filter(rows,query:"档案 下拉",month:"2026-10").count == 1,"Name, movement and month filters did not combine")
        try check(rows.first(where:{$0.kind == "other"})?.title == "户外骑行","A Chinese device activity name was replaced with a machine-code fallback")
        try check(rows.first(where:{$0.source == "archive"})?.detail.contains("时长未记录") == true,"Missing imported duration became zero minutes")
    }
    static func emitContracts(_ input:String,_ output:String) throws {
        let catalog=try JSONValue.read(Data(contentsOf:URL(fileURLWithPath:input)))
        let templates=catalog["templates"].array
        let sessions=try templates.map { try NativeTraining.start(template:$0,catalog:catalog["exercises"].array,history:[]) }
        let payload:JSONValue=["sessions":.array(sessions),"templates":.array(templates)]
        try payload.data().write(to:URL(fileURLWithPath:output));print("Emitted \(sessions.count) sessions from the latest Pi template catalog")
    }
    static func main() throws {
        let cases:[(String,()throws->Void)]=[("Actual set completion and rest ownership",nativeCompletion),("Native pause/resume/finish clocks",timers),("Resume at the movement being recorded",resumeMovement),("Strength index against each lift's own best",strengthIndex),("Suggested bedtime from wake time and sleep need",bedtime),("Posture streak over planned days",postureStreak),("Weight gain pace",weightRate),("Stalled lifts",stall),("Whole-day sessions and weekday labels",dayGlyphs),("Duration-based mobility",timedMobility),("Strength/mobility separation",mixedProgress),("Double progression and incomplete work",doubleProgression),("Edited template baselines and remaining sets",templateBaseline),("Warmup and work-target edits",editedTargets),("In-flight edits, conflicts, tombstones and disk roundtrip",mergeAndInflightEdits),("Missing values, future fields and units",nullsAndUnknownFields),("Unified records, source semantics and combined filters",recordsTimeline),("Legacy cache, durable deltas, checkpoint races and tombstones",cacheJournalRecovery),("Atomic append failure preserves storage",cacheWriteFailure),("Cached timestamps, zones and concurrent access",cachedDateSemantics),("Live payload ignores numeric edits but publishes set completion",livePayloadIdentity),("Home payload matches the typed contract",homeContract)]
        for (name,run) in cases { try run();print("PASS: \(name)") }
        if CommandLine.arguments.count==4 && CommandLine.arguments[1]=="--contracts" { try emitContracts(CommandLine.arguments[2],CommandLine.arguments[3]) }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--performance" { try measurePerformance(CommandLine.arguments[2]) }
        print("\(cases.count) native training and persistence checks passed.")
    }
}
