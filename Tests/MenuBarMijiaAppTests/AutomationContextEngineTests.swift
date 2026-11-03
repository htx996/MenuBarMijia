import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #174: the engine consumes snapshots from an injected observer, evaluates every enabled rule and
/// reuses the normal dispatch/undo path. Each Mac-only signal has a behavior test, plus the
/// disabled-by-default contract.
@MainActor
final class FakeMacContextProvider: MacContextProviding {
    private var handler: (@MainActor (MacContextSnapshot, Date) async -> Void)?
    private(set) var isStarted = false

    func start(_ handler: @escaping @MainActor (MacContextSnapshot, Date) async -> Void) {
        self.handler = handler
        isStarted = true
    }

    func stop() {
        handler = nil
        isStarted = false
    }

    func emit(_ snapshot: MacContextSnapshot, at now: Date = Date()) async {
        await handler?(snapshot, now)
    }
}

@MainActor
struct AutomationContextEngineTests {
    static let lightId = "light_study"
    static let workScene = HomeScene(id: "scene_work", name: "办公模式", entityId: "scene.work")

    static func studyLight(isOn: Bool = true) -> SmartDevice {
        SmartDevice(
            id: lightId,
            name: "书房台灯",
            roomId: "study",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: isOn))
        )
    }

    /// The engine references its store weakly and the provider callback references the engine
    /// weakly; tests keep both alive for the process so snapshots cannot silently no-op.
    private static var retainedEngines: [AutomationEngine] = []
    private static var retainedStores: [HomeStore] = []

    private func makeStore(
        lightOn: Bool = true,
        scenes: [HomeScene] = []
    ) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            devices: [Self.studyLight(isOn: lightOn)],
            scenes: scenes
        ))
        let store = HomeStore(
            provider: mock,
            defaultsSuiteName: "test.automation.context.\(UUID().uuidString)"
        )
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, mock)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "test.automation.context.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    private func makeEngine(
        rules: [AutomationRule],
        defaults: UserDefaults,
        lightOn: Bool = true,
        scenes: [HomeScene] = [],
        calendar: Calendar = .current
    ) async throws -> (AutomationEngine, HomeStore, MockHomeProvider, FakeMacContextProvider) {
        AutomationRuleStore(defaults: defaults).save(rules)
        let (store, mock) = try await makeStore(lightOn: lightOn, scenes: scenes)
        let provider = FakeMacContextProvider()
        let engine = AutomationEngine(
            defaults: defaults,
            contextProvider: provider,
            calendar: calendar
        )
        engine.attach(store: store)
        engine.startContextObservation()
        Self.retainedEngines.append(engine)
        Self.retainedStores.append(store)
        #expect(provider.isStarted)
        return (engine, store, mock, provider)
    }

    private func offCommand() -> DeviceCommand {
        .setLightPower(entityId: "light.study", isOn: false)
    }

    private func onCommand() -> DeviceCommand {
        .setLightPower(entityId: "light.study", isOn: true)
    }

    @Test("No rules means every Mac context signal stays inert")
    func noRulesIsInert() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (_, store, mock, provider) = try await makeEngine(rules: [], defaults: defaults)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(
            id: "event",
            title: "Meeting",
            startDate: start.addingTimeInterval(60),
            endDate: start.addingTimeInterval(3600)
        )
        await provider.emit(MacContextSnapshot(
            cameraInUse: true,
            microphoneInUse: true,
            powerSource: .ac,
            batteryPercent: 5,
            wifiSSID: "Home",
            isWiFiAuthorized: true,
            isFocusActive: true,
            isUserPresent: true,
            meetings: [meeting]
        ), at: start)

        #expect(await mock.executedCommands.isEmpty)
        #expect(store.devices.first?.isActiveOn == true)
    }

    @Test("A disabled Mac context rule never runs")
    func disabledRuleNeverRuns() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let rule = AutomationRule(
            trigger: .cameraInUse,
            action: .devices(ids: [Self.lightId], isOn: false),
            isEnabled: false
        )
        let (_, _, mock, provider) = try await makeEngine(rules: [rule], defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(), at: start)
        await provider.emit(MacContextSnapshot(cameraInUse: true), at: start.addingTimeInterval(10))
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("Camera and microphone rules fire on use / stop and coalesce flaps")
    func cameraAndMicrophoneRules() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cameraOn = AutomationRule(
            trigger: .cameraInUse,
            action: .devices(ids: [Self.lightId], isOn: false)
        )
        let cameraOff = AutomationRule(
            trigger: .cameraNotInUse,
            action: .devices(ids: [Self.lightId], isOn: true)
        )
        let micOn = AutomationRule(
            trigger: .microphoneInUse,
            action: .devices(ids: [Self.lightId], isOn: false)
        )
        let (_, store, mock, provider) = try await makeEngine(
            rules: [cameraOn, cameraOff, micOn],
            defaults: defaults
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(), at: start)
        await provider.emit(MacContextSnapshot(cameraInUse: true), at: start.addingTimeInterval(10))
        #expect(await mock.executedCommands == [offCommand()])
        #expect(store.devices.first?.isActiveOn == false)

        // Camera off, then back on within the one-minute cooldown: no extra dispatch.
        await provider.emit(MacContextSnapshot(), at: start.addingTimeInterval(20))
        await provider.emit(MacContextSnapshot(cameraInUse: true), at: start.addingTimeInterval(30))
        #expect(await mock.executedCommands.count == 2)

        await provider.emit(
            MacContextSnapshot(microphoneInUse: true),
            at: start.addingTimeInterval(40)
        )
        #expect(await mock.executedCommands == [offCommand(), onCommand(), offCommand()])
    }

    @Test("Power, disconnect and battery-threshold rules each run")
    func powerAndBatteryRules() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let powerConnected = AutomationRule(
            trigger: .powerConnected,
            action: .devices(ids: [Self.lightId], isOn: false)
        )
        let powerDisconnected = AutomationRule(
            trigger: .powerDisconnected,
            action: .devices(ids: [Self.lightId], isOn: true)
        )
        let lowBattery = AutomationRule(
            trigger: .batteryBelowThreshold,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(batteryThresholdPercent: 20)
        )
        let (_, _, mock, provider) = try await makeEngine(
            rules: [powerConnected, powerDisconnected, lowBattery],
            defaults: defaults
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let batteryHigh = MacContextSnapshot(powerSource: .battery, batteryPercent: 80)
        let ac = MacContextSnapshot(powerSource: .ac, batteryPercent: 80)
        let batteryLow = MacContextSnapshot(powerSource: .battery, batteryPercent: 10)

        await provider.emit(batteryHigh, at: start)
        await provider.emit(ac, at: start.addingTimeInterval(10))
        await provider.emit(batteryHigh, at: start.addingTimeInterval(20))
        await provider.emit(batteryLow, at: start.addingTimeInterval(30))

        #expect(await mock.executedCommands == [offCommand(), onCommand(), offCommand()])
    }

    @Test("Wi-Fi rules target a SSID and ignore unauthorized SSID reads")
    func wifiRules() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let joined = AutomationRule(
            trigger: .wifiNetworkJoined,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(wifiSSID: "Home")
        )
        let left = AutomationRule(
            trigger: .wifiNetworkLeft,
            action: .devices(ids: [Self.lightId], isOn: true),
            triggerOptions: AutomationTriggerOptions(wifiSSID: "Home")
        )
        let (_, _, mock, provider) = try await makeEngine(rules: [joined, left], defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(wifiSSID: "Office"), at: start)
        // Permission denied: a nil SSID must not look like leaving Home.
        await provider.emit(
            MacContextSnapshot(wifiSSID: nil, isWiFiAuthorized: false),
            at: start.addingTimeInterval(5)
        )
        #expect(await mock.executedCommands.isEmpty)

        await provider.emit(MacContextSnapshot(wifiSSID: "Office"), at: start.addingTimeInterval(7))
        await provider.emit(MacContextSnapshot(wifiSSID: "Home"), at: start.addingTimeInterval(10))
        await provider.emit(MacContextSnapshot(wifiSSID: "Office"), at: start.addingTimeInterval(20))
        #expect(await mock.executedCommands == [offCommand(), onCommand()])
    }

    @Test("Focus on/off rules run only when the observer exposes focus state")
    func focusRules() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let enabled = AutomationRule(
            trigger: .focusModeEnabled,
            action: .devices(ids: [Self.lightId], isOn: false)
        )
        let disabled = AutomationRule(
            trigger: .focusModeDisabled,
            action: .devices(ids: [Self.lightId], isOn: true)
        )
        let (_, _, mock, provider) = try await makeEngine(
            rules: [enabled, disabled],
            defaults: defaults,
            lightOn: false
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await provider.emit(MacContextSnapshot(isFocusActive: nil), at: start)
        await provider.emit(MacContextSnapshot(isFocusActive: true), at: start.addingTimeInterval(10))
        #expect(await mock.executedCommands.isEmpty)

        await provider.emit(MacContextSnapshot(isFocusActive: false), at: start.addingTimeInterval(20))
        await provider.emit(MacContextSnapshot(isFocusActive: true), at: start.addingTimeInterval(30))
        await provider.emit(MacContextSnapshot(isFocusActive: false), at: start.addingTimeInterval(40))
        // Focus-off at +20 (turn on), Focus-on at +30 (turn off), second Focus-off at +40 is
        // coalesced by the one-minute rule cooldown.
        #expect(await mock.executedCommands == [onCommand(), offCommand()])
    }

    @Test("A calendar meeting runs once and leaves the normal undo banner")
    func calendarMeetingRule() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let rule = AutomationRule(
            trigger: .calendarMeetingStartingSoon,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(calendarLeadMinutes: 5)
        )
        let (_, store, mock, provider) = try await makeEngine(rules: [rule], defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CalendarMeeting(
            id: "event-42",
            title: "Standup",
            startDate: start.addingTimeInterval(4 * 60),
            endDate: start.addingTimeInterval(34 * 60)
        )

        await provider.emit(MacContextSnapshot(meetings: [meeting]), at: start)
        #expect(await mock.executedCommands == [offCommand()])
        #expect(store.undoBanner != nil)

        // The same event must not re-run while its dedupe window is open.
        await provider.emit(MacContextSnapshot(meetings: [meeting]), at: start.addingTimeInterval(30))
        #expect(await mock.executedCommands == [offCommand()])
    }

    @Test("Calendar fallback runs a later meeting when the earliest already fired")
    func calendarFallbackAfterFiredMeeting() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let rule = AutomationRule(
            trigger: .calendarMeetingStartingSoon,
            action: .scene(sceneId: Self.workScene.id),
            triggerOptions: AutomationTriggerOptions(calendarLeadMinutes: 60)
        )
        let (_, _, mock, provider) = try await makeEngine(
            rules: [rule],
            defaults: defaults,
            scenes: [Self.workScene]
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CalendarMeeting(
            id: "first",
            title: "First",
            startDate: start.addingTimeInterval(30 * 60),
            endDate: start.addingTimeInterval(60 * 60)
        )
        let second = CalendarMeeting(
            id: "second",
            title: "Second",
            startDate: start.addingTimeInterval(59 * 60),
            endDate: start.addingTimeInterval(89 * 60)
        )

        await provider.emit(MacContextSnapshot(meetings: [first, second]), at: start)
        #expect(await mock.executedCommands == [.activateScene(entityId: "scene.work")])

        // Both meetings are still inside the lead window; the earliest key is now deduped and the
        // second meeting must get its own chance instead of being masked.
        await provider.emit(
            MacContextSnapshot(meetings: [first, second]),
            at: start.addingTimeInterval(10)
        )
        #expect(await mock.executedCommands == [
            .activateScene(entityId: "scene.work"),
            .activateScene(entityId: "scene.work")
        ])
    }

    @Test("Late-night use runs once per night, not once per observer tick")
    func lateNightRule() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let rule = AutomationRule(
            trigger: .lateNightUsage,
            action: .devices(ids: [Self.lightId], isOn: false),
            triggerOptions: AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let (_, _, mock, provider) = try await makeEngine(
            rules: [rule],
            defaults: defaults,
            calendar: calendar
        )
        let firstNight = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 15, hour: 23, minute: 30
        ))!
        let afterMidnight = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 16, hour: 3, minute: 30
        ))!
        let nextNight = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 16, hour: 23, minute: 30
        ))!

        await provider.emit(MacContextSnapshot(), at: firstNight)
        await provider.emit(MacContextSnapshot(), at: firstNight.addingTimeInterval(600))
        // The shrinking remaining window must not let the same night fire again at 03:30.
        await provider.emit(MacContextSnapshot(), at: afterMidnight)
        #expect(await mock.executedCommands == [offCommand()])

        await provider.emit(MacContextSnapshot(), at: nextNight)
        #expect(await mock.executedCommands.count == 2)
    }
}
