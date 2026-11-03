import Foundation

// MARK: - Mac Context Automation (#174)

/// The power source reported by IOKit.ps. `.unknown` covers desktops without a battery and
/// transient states during sleep/wake.
public enum MacPowerSource: String, Codable, Equatable, Sendable {
    case ac
    case battery
    case unknown
}

/// The subset of an EventKit event the automation engine needs. Kept free of EventKit so rules can
/// be evaluated in unit tests without a calendar store or permission prompt.
public struct CalendarMeeting: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date

    public init(id: String, title: String, startDate: Date, endDate: Date) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// One observation of the Mac-only signals. The app target fills this from CoreMediaIO, CoreAudio,
/// IOKit, CoreWLAN, Intents and EventKit; tests construct it directly.
///
/// `nil` focus means the Focus-status permission was not granted; `isWiFiAuthorized == false` means
/// the SSID is hidden because Location permission was denied. Those are deliberately different from
/// "Focus is off" and "not connected to Wi-Fi", so revoking a permission cannot fabricate a trigger.
public struct MacContextSnapshot: Equatable, Sendable {
    public var cameraInUse: Bool
    public var microphoneInUse: Bool
    public var powerSource: MacPowerSource
    public var batteryPercent: Int?
    public var wifiSSID: String?
    public var isWiFiAuthorized: Bool
    public var isFocusActive: Bool?
    public var isUserPresent: Bool
    public var meetings: [CalendarMeeting]

    public init(
        cameraInUse: Bool = false,
        microphoneInUse: Bool = false,
        powerSource: MacPowerSource = .unknown,
        batteryPercent: Int? = nil,
        wifiSSID: String? = nil,
        isWiFiAuthorized: Bool = true,
        isFocusActive: Bool? = nil,
        isUserPresent: Bool = true,
        meetings: [CalendarMeeting] = []
    ) {
        self.cameraInUse = cameraInUse
        self.microphoneInUse = microphoneInUse
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.wifiSSID = wifiSSID
        self.isWiFiAuthorized = isWiFiAuthorized
        self.isFocusActive = isFocusActive
        self.isUserPresent = isUserPresent
        self.meetings = meetings
    }
}

/// A fire decision for one rule. `dedupeKey` is per rule (and per calendar event / night), so two
/// camera rules, or two battery thresholds, can fire independently.
public struct AutomationTriggerEvent: Equatable, Sendable {
    public var trigger: AutomationTrigger
    public var dedupeKey: String
    public var cooldown: TimeInterval

    public init(trigger: AutomationTrigger, dedupeKey: String, cooldown: TimeInterval) {
        self.trigger = trigger
        self.dedupeKey = dedupeKey
        self.cooldown = cooldown
    }
}

/// Pure evaluation of the #174 signals. One `switch` owns every trigger's semantics so the engine
/// never grows signal-specific conditionals.
///
/// Notification-driven triggers (`away`, `back`, displays) return no events; `AutomationEngine`
/// keeps its existing one-minute coalescing for those. Transitions return at most one event. A
/// calendar rule can return several eligible meetings so the engine can skip already-fired events
/// and still run for a later meeting; late-night rules also return one event, whose key is anchored
/// to the particular night.
public enum MacContextAutomation {
    public static func events(
        for rule: AutomationRule,
        previous: MacContextSnapshot?,
        current: MacContextSnapshot,
        at now: Date,
        calendar: Calendar = .current
    ) -> [AutomationTriggerEvent] {
        guard rule.isEnabled else { return [] }
        let options = rule.triggerOptions

        switch rule.trigger {
        case .away, .back, .externalDisplayConnected, .externalDisplayDisconnected:
            return []

        case .cameraInUse:
            guard let previous, !previous.cameraInUse, current.cameraInUse else { return [] }
            return [transitionEvent(rule)]
        case .cameraNotInUse:
            guard let previous, previous.cameraInUse, !current.cameraInUse else { return [] }
            return [transitionEvent(rule)]
        case .microphoneInUse:
            guard let previous, !previous.microphoneInUse, current.microphoneInUse else { return [] }
            return [transitionEvent(rule)]
        case .microphoneNotInUse:
            guard let previous, previous.microphoneInUse, !current.microphoneInUse else { return [] }
            return [transitionEvent(rule)]

        case .powerConnected:
            guard let previous,
                  previous.powerSource != .ac,
                  current.powerSource == .ac else { return [] }
            return [transitionEvent(rule)]
        case .powerDisconnected:
            guard let previous,
                  previous.powerSource == .ac,
                  current.powerSource != .ac else { return [] }
            return [transitionEvent(rule)]
        case .batteryBelowThreshold:
            guard let previous,
                  current.powerSource == .battery,
                  let percent = current.batteryPercent,
                  percent < options.batteryThresholdPercent else { return [] }
            let wasAlreadyBelow = previous.powerSource == .battery
                && (previous.batteryPercent ?? Int.max) < options.batteryThresholdPercent
            guard !wasAlreadyBelow else { return [] }
            return [transitionEvent(rule)]

        case .wifiNetworkJoined:
            guard let previous, current.isWiFiAuthorized, previous.isWiFiAuthorized else { return [] }
            let previousSSID = previous.wifiSSID
            guard current.wifiSSID != previousSSID else { return [] }
            if let target = options.wifiSSID {
                guard current.wifiSSID == target else { return [] }
            } else {
                guard current.wifiSSID != nil else { return [] }
            }
            return [transitionEvent(rule)]
        case .wifiNetworkLeft:
            guard let previous, current.isWiFiAuthorized, previous.isWiFiAuthorized else { return [] }
            let previousSSID = previous.wifiSSID
            guard previousSSID != nil, current.wifiSSID != previousSSID else { return [] }
            if let target = options.wifiSSID, previousSSID != target {
                return []
            }
            return [transitionEvent(rule)]

        case .focusModeEnabled:
            guard let previous, previous.isFocusActive == false, current.isFocusActive == true else {
                return []
            }
            return [transitionEvent(rule)]
        case .focusModeDisabled:
            guard let previous, previous.isFocusActive == true, current.isFocusActive == false else {
                return []
            }
            return [transitionEvent(rule)]

        case .calendarMeetingStartingSoon:
            let lead = TimeInterval(options.calendarLeadMinutes * 60)
            return current.meetings
                .filter { $0.startDate > now && $0.startDate.timeIntervalSince(now) <= lead }
                .sorted { $0.startDate < $1.startDate }
                .map { meeting in
                    AutomationTriggerEvent(
                        trigger: rule.trigger,
                        dedupeKey: "\(rule.trigger.rawValue).\(rule.id.uuidString).\(meeting.id)",
                        cooldown: max(AutomationPolicy.triggerCooldown, lead + 60)
                    )
                }

        case .lateNightUsage:
            guard current.isUserPresent,
                  let night = options.lateNightWindow.nightAnchor(containing: now, calendar: calendar)
            else { return [] }
            return [AutomationTriggerEvent(
                trigger: rule.trigger,
                // The night anchor makes each night an independent dedupe key, while the fixed
                // cooldown blocks every later tick in the same night even as the window shrinks.
                dedupeKey: "\(rule.trigger.rawValue).\(rule.id.uuidString).\(Int(night.timeIntervalSince1970))",
                cooldown: AutomationPolicy.nightlyCooldown
            )]
        }
    }

    public static func requiredPermissions(for rules: [AutomationRule]) -> Set<AutomationPermission> {
        Set(rules.filter(\.isEnabled).compactMap(\.trigger.requiredPermission))
    }

    private static func transitionEvent(_ rule: AutomationRule) -> AutomationTriggerEvent {
        AutomationTriggerEvent(
            trigger: rule.trigger,
            dedupeKey: "\(rule.trigger.rawValue).\(rule.id.uuidString)",
            cooldown: AutomationPolicy.triggerCooldown
        )
    }
}
