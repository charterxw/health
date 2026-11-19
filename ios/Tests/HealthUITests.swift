import XCTest

final class HealthUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Native fixtures are available only in the simulator.")
        #endif
        continueAfterFailure = false
    }
    @MainActor func testServiceFailureCanRetryAndSignInNatively() {
        let app = launch(retry: true)
        XCTAssertTrue(app.staticTexts["Pine 暂时不可用"].waitForExistence(timeout: 30))
        app.buttons["重试"].tap(); signIn(app)
        XCTAssertEqual(app.webViews.count, 0)
        capture(app, "native-overview")
        app.buttons["recovery-score"].tap(); app.buttons["metric-resting_hr"].tap()
        XCTAssertTrue(app.navigationBars["静息心率"].waitForExistence(timeout: 5))
        capture(app, "native-recovery-detail");app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["metric-resting_hr"].waitForExistence(timeout: 5))
    }
    @MainActor func testThreeTabsAndOverviewSleepDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["HEALTH_DESIGN_PREVIEW"] = "1"
        app.launchEnvironment["HEALTH_DESIGN_SCREEN"] = "home"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["总览"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertFalse(app.tabBars.buttons["睡眠"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertTrue(app.buttons["home-feelings"].isHittable, "Overview must fit on the initial iPhone 18 Pro page")
        XCTAssertFalse(app.buttons["metric-resting_hr"].exists)
        capture(app, "redesign-overview")
        app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.staticTexts["当前安排"].waitForExistence(timeout: 5))
        capture(app, "redesign-training")
        app.tabBars.buttons["运动记录"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        capture(app, "redesign-records")
        app.tabBars.buttons["总览"].tap()
        app.buttons["recovery-score"].tap()
        let sleep = app.buttons["recovery-sleep"]
        XCTAssertTrue(sleep.waitForExistence(timeout: 5)); sleep.tap()
        XCTAssertTrue(app.navigationBars["睡眠与作息"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        capture(app, "redesign-sleep-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(sleep.waitForExistence(timeout: 5))
    }
    @MainActor func testOverviewDateSelectionAndLongBrief() {
        checkOverviewDateSelection(reduceMotion: false)
    }
    @MainActor func testOverviewDateSelectionWithReducedMotion() {
        checkOverviewDateSelection(reduceMotion: true)
    }
    @MainActor private func checkOverviewDateSelection(reduceMotion: Bool) {
        let app = XCUIApplication()
        app.launchEnvironment["HEALTH_DESIGN_PREVIEW"] = "1"
        app.launchEnvironment["HEALTH_DESIGN_BRIEF"] = "long"
        if reduceMotion { app.launchEnvironment["HEALTH_DESIGN_REDUCE_MOTION"] = "1" }
        app.launch()
        let today = app.buttons["home-day-2026-11-18"]
        XCTAssertTrue(today.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["home-feelings"].isHittable, "Longer observation must keep the initial overview on one page")
        let yesterday = app.buttons["home-day-2026-11-17"]
        yesterday.tap()
        XCTAssertTrue(yesterday.isSelected)
        XCTAssertEqual(app.staticTexts["home-selected-date"].label, "11/17")
        let future = app.buttons["home-day-2026-11-19"]
        XCTAssertTrue(future.label.contains("未来日期"))
        future.tap()
        XCTAssertTrue(future.isSelected)
        XCTAssertEqual(app.staticTexts["home-selected-date"].label, "11/19")
        today.tap()
        XCTAssertTrue(today.isSelected)
        XCTAssertEqual(app.staticTexts["home-selected-date"].label, "今日")
        app.buttons["home-observation"].tap()
        XCTAssertTrue(app.staticTexts["今天已训练，晚上照常遛狗即可，不必额外加量。"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        capture(app, reduceMotion ? "polished-overview-reduced" : "polished-overview-long")
    }
    @MainActor func testCompleteSetPauseResumeAndSave() async throws {
        let id = UUID().uuidString.lowercased(), app = launch(runID: id)
        signIn(app); app.navigationBars.firstMatch.buttons["继续训练"].tap()
        let complete = app.buttons["set-0-complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10));scrollTo(complete, app: app);complete.tap()
        XCTAssertTrue(app.buttons["撤销第 1 组"].exists)
        scrollTo(app.buttons["暂停"],app: app);app.buttons["暂停"].tap();XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 5));app.buttons["继续"].tap()
        capture(app,"native-workout")
        app.navigationBars.buttons["结束训练"].tap()
        app.alerts["完成这场训练？"].buttons["继续记录"].tap()
        app.navigationBars.buttons["结束训练"].tap();app.alerts["完成这场训练？"].buttons["完成并保存"].tap()
        XCTAssertTrue(app.navigationBars["训练总结"].waitForExistence(timeout: 10))
        try await waitForSaved(id, completed: true)
        let value = try await fixture(id)
        let records = value["records"] as! [String: [String: Any]], session = records.values.first!["session"] as! [String: Any]
        let movement = (session["exercises"] as! [[String: Any]])[0], sets = movement["sets"] as! [[String: Any]]
        XCTAssertEqual(sets.filter { !($0["completed_at"] is NSNull) }.count,1)
        XCTAssertNil(session["rest_until"] as? String)
        capture(app,"native-report")
    }
    @MainActor func testOfflineDraftSurvivesRelaunchAndRetries() async throws {
        let id = UUID().uuidString.lowercased(), app = launch(runID: id)
        signIn(app);_ = try await fixture(id, change:["offline":true])
        app.navigationBars.firstMatch.buttons["继续训练"].tap()
        let complete = app.buttons["set-0-complete"];XCTAssertTrue(complete.waitForExistence(timeout: 10));scrollTo(complete,app:app);complete.tap()
        app.terminate();app.launch()
        XCTAssertTrue(app.tabBars.buttons["总览"].waitForExistence(timeout: 30));app.navigationBars.firstMatch.buttons["继续训练"].tap()
        XCTAssertTrue(app.buttons["撤销第 1 组"].waitForExistence(timeout: 10))
        _ = try await fixture(id,change:["offline":false]);app.buttons["收起"].tap();app.navigationBars.firstMatch.buttons["设置"].tap();app.buttons["立即同步"].tap()
        try await waitForSaved(id, completed:false)
    }
    @MainActor func testVersionConflictKeepsAlternativeCopy() async throws {
        let id = UUID().uuidString.lowercased(), app = launch(runID:id)
        signIn(app);_ = try await fixture(id,change:["conflict":true])
        app.navigationBars.firstMatch.buttons["继续训练"].tap()
        let complete = app.buttons["set-0-complete"];XCTAssertTrue(complete.waitForExistence(timeout: 10));scrollTo(complete,app:app);complete.tap()
        let resolve = app.buttons["使用本机版本"]
        for _ in 0..<8 { if resolve.exists { break };app.swipeDown();try await Task.sleep(for:.milliseconds(500)) }
        XCTAssertTrue(resolve.waitForExistence(timeout: 10));scrollTo(resolve,app:app);resolve.tap();try await waitForSaved(id,completed:false)
        app.buttons["收起"].tap();app.navigationBars.firstMatch.buttons["设置"].tap()
        let alternative = app.buttons.containing(NSPredicate(format:"label CONTAINS %@","冲突副本")).firstMatch
        XCTAssertTrue(alternative.waitForExistence(timeout: 10))
    }
    @MainActor func testSettingsAndTimedMobilityAreNative() async throws {
        let id = UUID().uuidString.lowercased(), app = launch(runID:id)
        signIn(app);app.navigationBars.firstMatch.buttons["设置"].tap()
        let live = app.switches["训练实况"];XCTAssertTrue(live.waitForExistence(timeout:10));let old=live.value as? String;live.tap()
        XCTAssertTrue(app.switches["组间休息提醒"].exists);app.buttons["完成"].tap()
        app.navigationBars.firstMatch.buttons["设置"].tap();XCTAssertNotEqual(live.value as? String,old);live.tap();app.buttons["完成"].tap()
        app.navigationBars.firstMatch.buttons["继续训练"].tap();app.navigationBars.buttons["结束训练"].tap();app.alerts["完成这场训练？"].buttons["完成并保存"].tap()
        XCTAssertTrue(app.navigationBars["训练总结"].waitForExistence(timeout:10));app.buttons["完成"].tap()
        app.tabBars.buttons["训练"].tap();app.buttons["training-tools"].tap();app.buttons["全部模板"].tap()
        let posture=app.buttons.containing(NSPredicate(format:"label CONTAINS %@","体态计时练习")).firstMatch;XCTAssertTrue(posture.waitForExistence(timeout:5));posture.tap()
        let start=app.buttons["开始训练"];scrollTo(start,app:app);start.tap()
        XCTAssertTrue(app.textFields["第 1 组秒数"].waitForExistence(timeout:10));XCTAssertFalse(app.textFields["第 1 组重量"].exists)
        capture(app,"native-timed-mobility")
        app.buttons["set-0-complete"].tap();try await Task.sleep(for:.seconds(2))
        let data=try await fixture(id), records=data["records"] as! [String:[String:Any]]
        let active=records.values.compactMap { $0["session"] as? [String:Any] }.first { $0["status"] as? String == "active" }
        XCTAssertNotNil(active)
        let row=((active!["exercises"] as! [[String:Any]])[0]["sets"] as! [[String:Any]])[0]
        XCTAssertEqual(row["duration_seconds"] as? Int,30);XCTAssertTrue(row["reps"] is NSNull)
    }
    @MainActor private func launch(retry:Bool=false,runID:String=UUID().uuidString.lowercased()) -> XCUIApplication {
        let app=XCUIApplication();app.launchEnvironment["HEALTH_UI_TEST_PORT"]="43189";app.launchEnvironment["HEALTH_UI_TEST_ID"]=runID
        if retry { app.launchEnvironment["HEALTH_UI_TEST_RETRY"]="1" };app.launch();return app
    }
    @MainActor private func signIn(_ app:XCUIApplication) {
        let name=app.textFields["login-username"];XCTAssertTrue(name.waitForExistence(timeout:30));name.tap();name.typeText("test")
        let password=app.secureTextFields["login-password"];password.tap();password.typeText("sample-password");app.buttons["login-submit"].tap()
        XCTAssertTrue(app.tabBars.buttons["总览"].waitForExistence(timeout:20));XCTAssertEqual(app.webViews.count,0)
    }
    private func fixture(_ id:String,change:[String:Any]?=nil) async throws -> [String:Any] {
        var request=URLRequest(url:URL(string:"http://127.0.0.1:43189/__test/"+id)!,timeoutInterval:5)
        if let change { request.httpMethod="POST";request.httpBody=try JSONSerialization.data(withJSONObject:change) }
        let (data,_)=try await URLSession.shared.data(for:request);return try JSONSerialization.jsonObject(with:data) as! [String:Any]
    }
    private func waitForSaved(_ id:String,completed:Bool) async throws {
        for _ in 0..<30 {
            let result=try await fixture(id), rows=result["records"] as! [String:[String:Any]]
            if rows.values.contains(where:{ row in
                guard (row["version"] as? Int ?? 0)>1,let s=row["session"] as? [String:Any],s["status"] as? String == (completed ? "completed":"active") else{return false}
                return ((s["exercises"] as? [[String:Any]]) ?? []).contains { m in ((m["sets"] as? [[String:Any]]) ?? []).contains { !($0["completed_at"] is NSNull) } }
            }) { return }
            try await Task.sleep(for:.milliseconds(500))
        };XCTFail("Expected the actual completed set to reach the fixture server")
    }
    @MainActor private func scrollTo(_ element:XCUIElement,app:XCUIApplication) {
        for _ in 0..<6 { if element.isHittable{return};app.swipeUp() }
    }
    @MainActor private func capture(_ app:XCUIApplication,_ name:String) { let item=XCTAttachment(screenshot:app.screenshot());item.name=name;item.lifetime = .keepAlways;add(item) }
}
