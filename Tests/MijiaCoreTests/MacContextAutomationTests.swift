import Foundation
import Testing
@testable import MijiaCore

/// #174: pure Mac-context trigger evaluation, option decoding and per-signal edges.
struct MacContextAutomationTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 15) -> Date {
        utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func event(
        _ trigger: AutomationTrigger,
        previous: MacContextSnapshot?,
        current: MacContextSnapshot,
        options: AutomationTriggerOptions = AutomationTriggerOptions(),
        at now: Date? = nil,
        calendar: Calendar? = nil
    ) -> AutomationTriggerEvent? {
        let rule = AutomationRule(
            trigger: trigger,
            action: .quickAction(.lightsOff),
            triggerOptions: options
        )
        return MacContextAutomation.events(
            for: rule,
            previous: previous,
            current: current,
            at: now ?? date(12),
            calendar: calendar ?? utcCalendar
        ).first
    }

    @Test("Rules stored before #174 decode with default options")
    func legacyRuleDecodesWithDefaults() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "isEnabled": true,
            "trigger": "away",
            "action": ["kind": "quickAction", "quickAction": QuickAction.lightsOff.rawValue]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let rule = try JSONDecoder().decode(AutomationRule.self, from: data)

        #expect(rule.trigger == .away)
        #expect(rule.triggerOptions == AutomationTriggerOptions())
    }

    @Test("Trigger options round-trip and clamp out-of-range values")
    func optionsRoundTripAndClamp() throws {
        let options = AutomationTriggerOptions(
            batteryThresholdPercent: 0,
            wifiSSID: "  Home  ",
            lateNightStartHour: 30,
            lateNightEndHour: -1,
            calendarLeadMinutes: 999
        )
        #expect(options.batteryThresholdPercent == 1)
        #expect(options.wifiSSID == "Home")
        #expect(options.lateNightWindow.startHour == 23)
        #expect(options.lateNightWindow.endHour == 0)
        #expect(options.calendarLeadMinutes == 60)

        let blankSSID = AutomationTriggerOptions(wifiSSID: "   ")
        #expect(blankSSID.wifiSSID == nil)

        let decoded = try JSONDecoder().decode(
            AutomationTriggerOptions.self,
            from: JSONEncoder().encode(options)
        )
        #expect(decoded == options)
    }

    @Test("A disabled rule never produces an event")
    func disabledRuleProducesNoEvent() {
        let rule = AutomationRule(
            trigger: .cameraInUse,
            action: .quickAction(.lightsOff),
            isEnabled: false
        )
        let current = MacContextSnapshot(cameraInUse: true)
        #expect(MacContextAutomation.events(
            for: rule,
            previous: MacContextSnapshot(),
            current: current,
            at: date(12)
        ).isEmpty)
    }

    @Test("Camera and microphone fire only on the matching transition")
    func cameraAndMicrophoneTransitions() {
        let idle = MacContextSnapshot()
        var cameraOn = idle
        cameraOn.cameraInUse = true
        #expect(event(.cameraInUse, previous: idle, current: cameraOn) != nil)
        #expect(event(.cameraInUse, previous: cameraOn, current: cameraOn) == nil)
        #expect(event(.cameraNotInUse, previous: cameraOn, current: idle) != nil)
        #expect(event(.cameraInUse, previous: nil, current: cameraOn) == nil)

        var micOn = idle
        micOn.microphoneInUse = true
        #expect(event(.microphoneInUse, previous: idle, current: micOn) != nil)
        #expect(event(.microphoneInUse, previous: micOn, current: micOn) == nil)
        #expect(event(.microphoneNotInUse, previous: micOn, current: idle) != nil)
        #expect(event(.microphoneInUse, previous: nil, current: micOn) == nil)
    }

    @Test("Power connect, disconnect and the battery threshold use transitions")
    func powerAndBatteryTransitions() {
        let batteryHigh = MacContextSnapshot(powerSource: .battery, batteryPercent: 80)
        let ac = MacContextSnapshot(powerSource: .ac, batteryPercent: 80)
        #expect(event(.powerConnected, previous: batteryHigh, current: ac) != nil)
        #expect(event(.powerConnected, previous: ac, current: ac) == nil)
        #expect(event(.powerDisconnected, previous: ac, current: batteryHigh) != nil)
        #expect(event(.powerConnected, previous: nil, current: ac) == nil)

        let options = AutomationTriggerOptions(batteryThresholdPercent: 20)
        var batteryLow = batteryHigh
        batteryLow.batteryPercent = 19
        #expect(event(.batteryBelowThreshold, previous: batteryHigh, current: batteryLow, options: options) != nil)
        #expect(event(.batteryBelowThreshold, previous: batteryLow, current: batteryLow, options: options) == nil)
        #expect(event(.batteryBelowThreshold, previous: ac, current: batteryLow, options: options) != nil)
        #expect(event(.batteryBelowThreshold, previous: nil, current: batteryLow, options: options) == nil)
    }

    @Test("Wi-Fi join and leave can target one SSID or any network")
    func wifiTransitions() {
        let office = MacContextSnapshot(wifiSSID: "Office")
        let home = MacContextSnapshot(wifiSSID: "Home")
        let homeOnly = AutomationTriggerOptions(wifiSSID: "Home")

        #expect(event(.wifiNetworkJoined, previous: office, current: home, options: homeOnly) != nil)
        #expect(event(.wifiNetworkJoined, previous: office, current: home, options: .init(wifiSSID: "Work")) == nil)
        #expect(event(.wifiNetworkLeft, previous: home, current: office, options: homeOnly) != nil)
        #expect(event(.wifiNetworkLeft, previous: office, current: home, options: homeOnly) == nil)
        #expect(event(.wifiNetworkJoined, previous: office, current: home) != nil)
        #expect(event(.wifiNetworkJoined, previous: nil, current: home) == nil)

        let unauthorized = MacContextSnapshot(wifiSSID: nil, isWiFiAuthorized: false)
        #expect(event(.wifiNetworkLeft, previous: home, current: unauthorized, options: homeOnly) == nil)
        #expect(event(.wifiNetworkJoined, previous: unauthorized, current: home, options: homeOnly) == nil)
    }

    @Test("Focus on/off requires an observed transition, not a first snapshot")
    func focusTransitions() {
        let focusOff = MacContextSnapshot(isFocusActive: false)
        let focusOn = MacContextSnapshot(isFocusActive: true)

        #expect(event(.focusModeEnabled, previous: focusOff, current: focusOn) != nil)
        #expect(event(.focusModeEnabled, previous: focusOn, current: focusOn) == nil)
        #expect(event(.focusModeEnabled, previous: nil, current: focusOn) == nil)
        #expect(event(.focusModeDisabled, previous: focusOn, current: focusOff) != nil)
        #expect(event(.focusModeDisabled, previous: focusOff, current: focusOff) == nil)

        let permissionMissing = MacContextSnapshot(isFocusActive: nil)
        #expect(event(.focusModeEnabled, previous: permissionMissing, current: focusOn) == nil)
        #expect(event(.focusModeDisabled, previous: focusOn, current: permissionMissing) == nil)
    }

    @Test("Calendar fires inside the lead window and keys the dedupe by event")
    func calendarLeadWindow() {
        let now = date(10)
        let meeting = CalendarMeeting(
            id: "event-42",
            title: "Standup",
            startDate: now.addingTimeInterval(4 * 60),
            endDate: now.addingTimeInterval(34 * 60)
        )
        let snapshot = MacContextSnapshot(meetings: [meeting])
        let options = AutomationTriggerOptions(calendarLeadMinutes: 5)

        let fired = event(
            .calendarMeetingStartingSoon,
            previous: nil,
            current: snapshot,
            options: options,
            at: now
        )
        #expect(fired != nil)
        #expect(fired?.dedupeKey.contains("event-42") == true)

        #expect(event(
            .calendarMeetingStartingSoon,
            previous: nil,
            current: snapshot,
            options: .init(calendarLeadMinutes: 1),
            at: now
        ) == nil)
        #expect(event(
            .calendarMeetingStartingSoon,
            previous: nil,
            current: snapshot,
            options: options,
            at: now.addingTimeInterval(10 * 60)
        ) == nil)
    }

    @Test("All eligible calendar meetings become events in start order")
    func calendarMultipleMeetings() {
        let now = date(10)
        let first = CalendarMeeting(
            id: "first",
            title: "First",
            startDate: now.addingTimeInterval(10 * 60),
            endDate: now.addingTimeInterval(40 * 60)
        )
        let second = CalendarMeeting(
            id: "second",
            title: "Second",
            startDate: now.addingTimeInterval(20 * 60),
            endDate: now.addingTimeInterval(50 * 60)
        )
        let rule = AutomationRule(
            trigger: .calendarMeetingStartingSoon,
            action: .quickAction(.lightsOff),
            triggerOptions: AutomationTriggerOptions(calendarLeadMinutes: 30)
        )
        let events = MacContextAutomation.events(
            for: rule,
            previous: nil,
            current: MacContextSnapshot(meetings: [second, first]),
            at: now,
            calendar: utcCalendar
        )
        #expect(events.count == 2)
        #expect(events.map(\.dedupeKey).contains { $0.hasSuffix(".first") })
        #expect(events.map(\.dedupeKey).contains { $0.hasSuffix(".second") })
        #expect(events[0].dedupeKey.hasSuffix(".first"))
        #expect(events[1].dedupeKey.hasSuffix(".second"))
    }

    @Test("Late-night use fires inside the window only while the Mac is present")
    func lateNightWindow() {
        let options = AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6)
        let present = MacContextSnapshot(isUserPresent: true)
        let absent = MacContextSnapshot(isUserPresent: false)

        #expect(event(.lateNightUsage, previous: nil, current: present, options: options, at: date(23, 30)) != nil)
        #expect(event(.lateNightUsage, previous: nil, current: present, options: options, at: date(22, 30)) == nil)
        #expect(event(.lateNightUsage, previous: nil, current: present, options: options, at: date(12)) == nil)
        #expect(event(.lateNightUsage, previous: nil, current: absent, options: options, at: date(23, 30)) == nil)

        let fired = event(.lateNightUsage, previous: nil, current: present, options: options, at: date(23, 30))
        // From 23:30 until 06:00 the same night must not repeat the rule.
        #expect((fired?.cooldown ?? 0) > 6 * 60 * 60)
    }

    @Test("Late-night dedupe is anchored to one night")
    func lateNightNightlyKey() throws {
        let rule = AutomationRule(
            trigger: .lateNightUsage,
            action: .quickAction(.lightsOff),
            triggerOptions: AutomationTriggerOptions(lateNightStartHour: 23, lateNightEndHour: 6)
        )
        let present = MacContextSnapshot(isUserPresent: true)
        let beforeMidnight = try #require(MacContextAutomation.events(
            for: rule, previous: nil, current: present, at: date(23, 30), calendar: utcCalendar
        ).first)
        let afterMidnight = try #require(MacContextAutomation.events(
            for: rule, previous: nil, current: present, at: date(3, 30, day: 16), calendar: utcCalendar
        ).first)
        let nextNight = try #require(MacContextAutomation.events(
            for: rule, previous: nil, current: present, at: date(23, 30, day: 16), calendar: utcCalendar
        ).first)

        #expect(beforeMidnight.dedupeKey == afterMidnight.dedupeKey)
        #expect(beforeMidnight.dedupeKey != nextNight.dedupeKey)
        #expect(beforeMidnight.cooldown == AutomationPolicy.nightlyCooldown)
    }

    @Test("Late-night window math handles midnight crossing and same-day windows")
    func lateNightWindowMath() {
        let window = LateNightWindow(startHour: 23, endHour: 6)
        #expect(window.contains(date(23, 0), calendar: utcCalendar))
        #expect(window.contains(date(5, 59), calendar: utcCalendar))
        #expect(!window.contains(date(6, 0), calendar: utcCalendar))
        #expect(!window.contains(date(12, 0), calendar: utcCalendar))

        let afternoon = LateNightWindow(startHour: 13, endHour: 14)
        #expect(afternoon.contains(date(13, 30), calendar: utcCalendar))
        #expect(!afternoon.contains(date(14, 0), calendar: utcCalendar))

        #expect(window.nightAnchor(containing: date(23, 30), calendar: utcCalendar)
            == utcCalendar.startOfDay(for: date(23, 30)))
        #expect(window.nightAnchor(containing: date(3, 30, day: 16), calendar: utcCalendar)
            == utcCalendar.startOfDay(for: date(23, 30)))
        #expect(window.nightAnchor(containing: date(12), calendar: utcCalendar) == nil)

        let empty = LateNightWindow(startHour: 0, endHour: 0)
        #expect(!empty.contains(date(0), calendar: utcCalendar))
        #expect(empty.startHour == 0)
        #expect(empty.endHour == 0)
    }

    @Test("Decoded late-night windows clamp hostile hour values")
    func lateNightWindowDecoding() throws {
        let data = Data(#"{"startHour":99,"endHour":-5}"#.utf8)
        let window = try JSONDecoder().decode(LateNightWindow.self, from: data)
        #expect(window.startHour == 23)
        #expect(window.endHour == 0)
    }

    @Test("Only enabled rules contribute their required permissions")
    func requiredPermissions() {
        let rules = [
            AutomationRule(trigger: .wifiNetworkJoined, action: .quickAction(.lightsOff)),
            AutomationRule(trigger: .focusModeEnabled, action: .quickAction(.lightsOff)),
            AutomationRule(trigger: .calendarMeetingStartingSoon, action: .quickAction(.lightsOff)),
            AutomationRule(trigger: .cameraInUse, action: .quickAction(.lightsOff)),
            AutomationRule(trigger: .wifiNetworkLeft, action: .quickAction(.lightsOff), isEnabled: false)
        ]
        #expect(MacContextAutomation.requiredPermissions(for: rules) == [.location, .focus, .calendar])
    }

    @Test("Keyed cooldowns are independent and honor long windows")
    func keyedCooldown() throws {
        let suite = "test.mac.context.deduper.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let deduper = AutomationTriggerDeduper(defaults: defaults)
        #expect(deduper.shouldFire("calendar.1", at: start, cooldown: 600))
        #expect(!deduper.shouldFire("calendar.1", at: start.addingTimeInterval(300), cooldown: 600))
        #expect(deduper.shouldFire("calendar.1", at: start.addingTimeInterval(600), cooldown: 600))
        #expect(deduper.shouldFire("calendar.2", at: start.addingTimeInterval(10), cooldown: 600))
    }
}
