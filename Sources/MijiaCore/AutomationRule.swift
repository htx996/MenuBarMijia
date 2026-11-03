import Foundation

// MARK: - Mac-state Automation Rules (#59)

/// What wakes an automation rule. Every rule is off until the user creates one, and the settings
/// screen starts empty.
///
/// Sleep/lock/display-sleep signals are grouped into `away`, and unlock/wake/display-wake into
/// `back`, because macOS posts several notifications for one lid close. `AutomationPolicy` then
/// coalesces bursts of the same group.
public enum AutomationTrigger: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Screen locked, lid closed, or the Mac/display went to sleep.
    case away
    /// Screen unlocked, or the Mac/display woke up. No time-of-day condition yet.
    case back
    case externalDisplayConnected
    case externalDisplayDisconnected

    // MARK: Mac-only context signals (#174)

    /// A camera (built-in, Continuity or USB) is capturing. Detected through
    /// `kCMIODevicePropertyDeviceIsRunningSomewhere`, which needs no TCC grant.
    case cameraInUse
    case cameraNotInUse
    case microphoneInUse
    case microphoneNotInUse
    /// External power was connected / removed. The current source is read from IOKit.ps.
    case powerConnected
    case powerDisconnected
    /// Battery dropped below `AutomationTriggerOptions.batteryThresholdPercent` while unplugged.
    case batteryBelowThreshold
    /// Connected to a Wi-Fi network (optionally one specific SSID) after being elsewhere.
    case wifiNetworkJoined
    /// Left the current Wi-Fi network (optionally one specific SSID).
    case wifiNetworkLeft
    /// Focus mode turned on / off. The public API only exposes a boolean, not the Focus name.
    case focusModeEnabled
    case focusModeDisabled
    /// A calendar event starts within `AutomationTriggerOptions.calendarLeadMinutes`.
    case calendarMeetingStartingSoon
    /// The Mac is awake and unlocked inside `AutomationTriggerOptions.lateNightWindow`.
    case lateNightUsage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .away:
            return L10n.tr("离开（锁屏 / 合盖 / 睡眠）", "Away (lock, lid, sleep)")
        case .back:
            return L10n.tr("回来（解锁 / 唤醒）", "Back (unlock, wake)")
        case .externalDisplayConnected:
            return L10n.tr("接入外接显示器", "External display connected")
        case .externalDisplayDisconnected:
            return L10n.tr("断开外接显示器", "External display disconnected")
        case .cameraInUse:
            return L10n.tr("摄像头开始使用", "Camera in use")
        case .cameraNotInUse:
            return L10n.tr("摄像头停止使用", "Camera no longer in use")
        case .microphoneInUse:
            return L10n.tr("麦克风开始使用", "Microphone in use")
        case .microphoneNotInUse:
            return L10n.tr("麦克风停止使用", "Microphone no longer in use")
        case .powerConnected:
            return L10n.tr("接通电源", "Power connected")
        case .powerDisconnected:
            return L10n.tr("断开电源", "Power disconnected")
        case .batteryBelowThreshold:
            return L10n.tr("电量低于阈值", "Battery below threshold")
        case .wifiNetworkJoined:
            return L10n.tr("连接 Wi-Fi", "Wi-Fi network joined")
        case .wifiNetworkLeft:
            return L10n.tr("离开 Wi-Fi", "Wi-Fi network left")
        case .focusModeEnabled:
            return L10n.tr("专注模式开启", "Focus mode on")
        case .focusModeDisabled:
            return L10n.tr("专注模式关闭", "Focus mode off")
        case .calendarMeetingStartingSoon:
            return L10n.tr("日历会议即将开始", "Calendar meeting starting soon")
        case .lateNightUsage:
            return L10n.tr("深夜使用电脑", "Late-night computer use")
        }
    }

    public var symbolName: String {
        switch self {
        case .away: return "lock.fill"
        case .back: return "lock.open.fill"
        case .externalDisplayConnected: return "display"
        case .externalDisplayDisconnected: return "rectangle.on.rectangle"
        case .cameraInUse, .cameraNotInUse: return "video.fill"
        case .microphoneInUse, .microphoneNotInUse: return "mic.fill"
        case .powerConnected, .powerDisconnected, .batteryBelowThreshold: return "powerplug.fill"
        case .wifiNetworkJoined, .wifiNetworkLeft: return "wifi"
        case .focusModeEnabled, .focusModeDisabled: return "moon.fill"
        case .calendarMeetingStartingSoon: return "calendar.badge.clock"
        case .lateNightUsage: return "moon.stars.fill"
        }
    }

    /// The system permission this trigger needs before the observer can produce values. `nil` means
    /// the signal is readable without a TCC grant (away/back, displays, camera, microphone,
    /// power, late-night activity).
    public var requiredPermission: AutomationPermission? {
        switch self {
        case .wifiNetworkJoined, .wifiNetworkLeft: return .location
        case .focusModeEnabled, .focusModeDisabled: return .focus
        case .calendarMeetingStartingSoon: return .calendar
        default: return nil
        }
    }
}

/// Permissions the Mac context observer may ask for. They are requested only when the user has an
/// enabled rule that needs them, never at first launch.
public enum AutomationPermission: String, CaseIterable, Sendable {
    case location
    case focus
    case calendar

    public var title: String {
        switch self {
        case .location:
            return L10n.tr("定位（读取 Wi-Fi 名称）", "Location (to read the Wi-Fi name)")
        case .focus:
            return L10n.tr("专注状态", "Focus status")
        case .calendar:
            return L10n.tr("日历", "Calendar")
        }
    }
}

/// What a rule does. The three kinds mirror the issue: a built-in quick action, a group of devices
/// with one target state, or an existing Home Assistant scene.
public enum AutomationAction: Equatable, Sendable {
    case quickAction(QuickAction)
    case devices(ids: [String], isOn: Bool)
    case scene(sceneId: String)

    /// Intents handed to `HomeStore.runAutomation`. Quick actions are executed through their own
    /// store path because they aggregate devices dynamically.
    public func intents() -> [DeviceIntent] {
        switch self {
        case .quickAction:
            return []
        case .devices(let ids, let isOn):
            return ids.map { DeviceIntent(targetId: $0, operation: .power(isOn)) }
        case .scene(let sceneId):
            return [DeviceIntent(targetId: sceneId, operation: .activateScene)]
        }
    }

    public func summary(devices: [SmartDevice], scenes: [HomeScene]) -> String {
        switch self {
        case .quickAction(let action):
            return L10n.format("快捷动作：%@", "Quick action: %@", action.title)
        case .devices(let ids, let isOn):
            let names = ids.compactMap { id in devices.first(where: { $0.id == id })?.name }
            let verb = isOn ? L10n.tr("打开", "Turn on") : L10n.tr("关闭", "Turn off")
            let list: String
            if names.isEmpty {
                list = L10n.format("%@ 台设备", "%@ device(s)", String(ids.count))
            } else {
                let separator = L10n.tr("、", ", ")
                let shown = names.prefix(3).joined(separator: separator)
                let remainder = names.count - min(names.count, 3)
                // Chinese phrasing counts all devices ("A、B 等 6 台"), English counts the rest.
                let count = L10n.isEnglish ? remainder : names.count
                list = remainder > 0
                    ? L10n.format("%@ 等 %@ 台", "%@ and %@ more", shown, String(count))
                    : shown
            }
            // Whole sentence, so a zh-Hant/other table can reorder verb and list.
            return L10n.format("%@%@", "%@ %@", verb, list)
        case .scene(let sceneId):
            let name = scenes.first(where: { $0.id == sceneId })?.name ?? sceneId
            return L10n.format("场景：%@", "Scene: %@", name)
        }
    }
}

extension AutomationAction: Codable {
    private enum Kind: String, Codable {
        case quickAction, devices, scene
    }

    private enum CodingKeys: String, CodingKey {
        case kind, quickAction, deviceIds, isOn, sceneId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .quickAction:
            let raw = try container.decode(String.self, forKey: .quickAction)
            guard let action = QuickAction(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .quickAction,
                    in: container,
                    debugDescription: "Unknown quick action \(raw)"
                )
            }
            self = .quickAction(action)
        case .devices:
            self = .devices(
                ids: try container.decode([String].self, forKey: .deviceIds),
                isOn: try container.decode(Bool.self, forKey: .isOn)
            )
        case .scene:
            self = .scene(sceneId: try container.decode(String.self, forKey: .sceneId))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quickAction(let action):
            try container.encode(Kind.quickAction, forKey: .kind)
            try container.encode(action.rawValue, forKey: .quickAction)
        case .devices(let ids, let isOn):
            try container.encode(Kind.devices, forKey: .kind)
            try container.encode(ids, forKey: .deviceIds)
            try container.encode(isOn, forKey: .isOn)
        case .scene(let sceneId):
            try container.encode(Kind.scene, forKey: .kind)
            try container.encode(sceneId, forKey: .sceneId)
        }
    }
}

/// Optional parameters for the Mac-only triggers (#174). Rules that do not use them keep the
/// defaults, and rules written before these fields existed decode with defaults too.
public struct AutomationTriggerOptions: Codable, Equatable, Sendable {
    /// Battery percentage (1...100) below which `.batteryBelowThreshold` fires.
    public var batteryThresholdPercent: Int
    /// When set, Wi-Fi rules only react to this SSID. `nil` means any network change.
    public var wifiSSID: String?
    /// Local-time window for `.lateNightUsage`; may cross midnight (for example 23 → 6).
    public var lateNightWindow: LateNightWindow
    /// How many minutes before a calendar event starts `.calendarMeetingStartingSoon` fires.
    public var calendarLeadMinutes: Int

    public init(
        batteryThresholdPercent: Int = 20,
        wifiSSID: String? = nil,
        lateNightStartHour: Int = 23,
        lateNightEndHour: Int = 6,
        calendarLeadMinutes: Int = 1
    ) {
        self.batteryThresholdPercent = min(100, max(1, batteryThresholdPercent))
        let trimmedSSID = wifiSSID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.wifiSSID = (trimmedSSID?.isEmpty ?? true) ? nil : trimmedSSID
        self.lateNightWindow = LateNightWindow(
            startHour: lateNightStartHour,
            endHour: lateNightEndHour
        )
        self.calendarLeadMinutes = min(60, max(1, calendarLeadMinutes))
    }

    private enum CodingKeys: String, CodingKey {
        case batteryThresholdPercent
        case wifiSSID
        case lateNightStartHour
        case lateNightEndHour
        case calendarLeadMinutes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            batteryThresholdPercent: try container.decodeIfPresent(Int.self, forKey: .batteryThresholdPercent) ?? 20,
            wifiSSID: try container.decodeIfPresent(String.self, forKey: .wifiSSID),
            lateNightStartHour: try container.decodeIfPresent(Int.self, forKey: .lateNightStartHour) ?? 23,
            lateNightEndHour: try container.decodeIfPresent(Int.self, forKey: .lateNightEndHour) ?? 6,
            calendarLeadMinutes: try container.decodeIfPresent(Int.self, forKey: .calendarLeadMinutes) ?? 1
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(batteryThresholdPercent, forKey: .batteryThresholdPercent)
        try container.encodeIfPresent(wifiSSID, forKey: .wifiSSID)
        try container.encode(lateNightWindow.startHour, forKey: .lateNightStartHour)
        try container.encode(lateNightWindow.endHour, forKey: .lateNightEndHour)
        try container.encode(calendarLeadMinutes, forKey: .calendarLeadMinutes)
    }
}

/// A local-time window that may cross midnight. `startHour == endHour` is treated as an empty
/// window rather than an all-day one, so a misconfigured rule never spams a scene.
public struct LateNightWindow: Codable, Equatable, Sendable {
    public var startHour: Int
    public var endHour: Int

    public init(startHour: Int = 23, endHour: Int = 6) {
        self.startHour = min(23, max(0, startHour))
        self.endHour = min(23, max(0, endHour))
    }

    private enum CodingKeys: String, CodingKey {
        case startHour
        case endHour
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startHour: try container.decodeIfPresent(Int.self, forKey: .startHour) ?? 23,
            endHour: try container.decodeIfPresent(Int.self, forKey: .endHour) ?? 6
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startHour, forKey: .startHour)
        try container.encode(endHour, forKey: .endHour)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard startHour != endHour else { return false }
        let hour = calendar.component(.hour, from: date)
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        }
        return hour >= startHour || hour < endHour
    }

    /// Identifies which night a timestamp belongs to. Times after midnight in a window such as
    /// 23 → 6 anchor to the previous evening, so every tick of one night shares a key.
    public func nightAnchor(containing date: Date, calendar: Calendar = .current) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        let startOfDay = calendar.startOfDay(for: date)
        if startHour < endHour {
            return startOfDay
        }
        let hour = calendar.component(.hour, from: date)
        if hour >= startHour {
            return startOfDay
        }
        return calendar.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay
    }

}

public struct AutomationRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    public var trigger: AutomationTrigger
    public var action: AutomationAction
    public var triggerOptions: AutomationTriggerOptions

    public init(
        id: UUID = UUID(),
        trigger: AutomationTrigger,
        action: AutomationAction,
        isEnabled: Bool = true,
        triggerOptions: AutomationTriggerOptions = AutomationTriggerOptions()
    ) {
        self.id = id
        self.trigger = trigger
        self.action = action
        self.isEnabled = isEnabled
        self.triggerOptions = triggerOptions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case trigger
        case action
        case triggerOptions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        trigger = try container.decode(AutomationTrigger.self, forKey: .trigger)
        action = try container.decode(AutomationAction.self, forKey: .action)
        // Rules persisted before #174 have no options and must keep working unchanged.
        triggerOptions = try container.decodeIfPresent(AutomationTriggerOptions.self, forKey: .triggerOptions)
            ?? AutomationTriggerOptions()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(action, forKey: .action)
        try container.encode(triggerOptions, forKey: .triggerOptions)
    }
}

/// Persists the rule list in `UserDefaults`; an absent key means “no automation”, which is the
/// default and also how the settings screen renders its empty state.
public struct AutomationRuleStore {
    public static let storageKey = "automation_rules_v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [AutomationRule] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        if let rules = try? JSONDecoder().decode([AutomationRule].self, from: data) {
            return rules
        }
        // A single unreadable entry (older/renamed trigger, corrupted write) must not silently drop
        // every other rule; decode element by element and keep what still parses.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { element in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(AutomationRule.self, from: elementData)
        }
    }

    public func save(_ rules: [AutomationRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// One-minute coalescing for trigger bursts (lock often arrives together with display sleep).
/// Timestamps are persisted so relaunching the app right after unlocking cannot replay a rule.
public struct AutomationTriggerDeduper {
    public static let storageKey = "automation_trigger_last_fired_v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func lastFireDate(for trigger: AutomationTrigger) -> Date? {
        lastFireDate(forKey: trigger.rawValue)
    }

    public func lastFireDate(forKey key: String) -> Date? {
        guard let stamps = defaults.dictionary(forKey: Self.storageKey),
              let stored = stamps[key] else {
            return nil
        }
        let seconds = (stored as? Double) ?? (stored as? NSNumber)?.doubleValue
        guard let seconds else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Returns true and records `now` when this trigger may run. A backwards clock jump is treated
    /// as a fresh start instead of blocking the rule until the clock catches up.
    public func shouldFire(_ trigger: AutomationTrigger, at now: Date = Date()) -> Bool {
        shouldFire(trigger.rawValue, at: now, cooldown: AutomationPolicy.triggerCooldown)
    }

    /// Keyed variant used by Mac context rules. Their per-rule options (battery threshold, SSID,
    /// calendar event) need independent cooldowns, and the calendar/late-night cooldowns are longer
    /// than the usual one minute.
    public func shouldFire(
        _ key: String,
        at now: Date = Date(),
        cooldown: TimeInterval = AutomationPolicy.triggerCooldown
    ) -> Bool {
        if let last = lastFireDate(forKey: key) {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0, elapsed < cooldown {
                return false
            }
        }
        var stamps = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        stamps[key] = now.timeIntervalSince1970
        defaults.set(stamps, forKey: Self.storageKey)
        return true
    }
}

public enum AutomationMatcher {
    /// All enabled rules for this trigger. The deduper runs once per trigger, so several rules can
    /// share one wake event (for example lock → lights off and lock → sleep climate off).
    public static func rules(for trigger: AutomationTrigger, in rules: [AutomationRule]) -> [AutomationRule] {
        rules.filter { $0.isEnabled && $0.trigger == trigger }
    }
}

public enum AutomationPolicy {
    public static let triggerCooldown: TimeInterval = 60
    /// Late-night dedupe keys are per night; the fixed cooldown only has to cover one night even
    /// if the clock jumps backwards.
    public static let nightlyCooldown: TimeInterval = 24 * 60 * 60
    /// Automation usually fires while the panel is closed; keep the undo banner long enough to be
    /// found after unlocking instead of expiring unseen in ten seconds.
    public static let undoWindow: TimeInterval = 5 * 60
}
