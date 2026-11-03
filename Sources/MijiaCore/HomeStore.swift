import Foundation
import Observation

public struct ToastNotice: Equatable, Sendable {
    public let id: UUID
    public var message: String
    public var isError: Bool

    public init(id: UUID = UUID(), message: String, isError: Bool = false) {
        self.id = id
        self.message = message
        self.isError = isError
    }
}

public struct UndoBanner: Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var restoreCommands: [DeviceCommand]
    public var previousDevices: [SmartDevice]
    /// Habit records written while executing this action; undoing the banner takes them back (#34).
    public var habitReceipt: UserHabitMemory.RecordingReceipt?
    /// Explicit window for actions outside the panel (automation, #59); nil uses the device-count rule.
    public var duration: TimeInterval?
    /// True only for 全关, so the onboarding marker records an undo of the all-off lesson (#180).
    public var isAllOff: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        restoreCommands: [DeviceCommand],
        previousDevices: [SmartDevice],
        habitReceipt: UserHabitMemory.RecordingReceipt? = nil,
        duration: TimeInterval? = nil,
        isAllOff: Bool = false
    ) {
        self.id = id
        self.title = title
        self.restoreCommands = restoreCommands
        self.previousDevices = previousDevices
        self.habitReceipt = habitReceipt
        self.duration = duration
        self.isAllOff = isAllOff
    }
}

@Observable
@MainActor
public final class HomeStore {
    public static let shared = HomeStore()

    public internal(set) var connectionStatus: ConnectionStatus = .connecting {
        didSet { updateValueFreshness() }
    }
    public internal(set) var rooms: [RoomArea] = []
    /// Mi Home 家庭 list from the cloud backend; empty elsewhere.
    public internal(set) var homes: [HomeOption] = []
    public internal(set) var selectedMiHomeId: String? = UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey)
    public internal(set) var devices: [SmartDevice] = []
    /// Member did → Mi light-group did from the current snapshot; folding reads it (#189).
    public internal(set) var lightGroupOwners: [String: String] = [:]
    public internal(set) var environmentReadings: [EnvironmentReading] = []
    public internal(set) var scenes: [HomeScene] = []
    public internal(set) var hasReceivedInitialSnapshot = false
    public internal(set) var waitingDeviceIds: Set<String> = []
    /// True after the cloud drops once a snapshot has been shown. Cleared only by a later connect.
    /// A retry that is still `.connecting` leaves this set, so the last reading stays unmarked as current.
    public internal(set) var deviceValuesAreStale = false
    /// Bumped on every snapshot so a toggle can tell a read-back from the row it already had.
    var snapshotGeneration: UInt64 = 0
    /// How long to wait before a second property poll when the first read still shows the old power.
    var readBackEchoDelay: Duration = .milliseconds(800)
    /// Test latch: the echo retry waits until `releaseReadBackEcho` instead of sleeping.
    var holdReadBackEcho = false
    var isHoldingReadBackEcho = false
    var readBackEchoHold: CheckedContinuation<Void, Never>?
    var readBackOwner: [String: UInt64] = [:]
    /// Ticket of the read-back task still running, including the echo retry after the UI
    /// waiting state is released. Snapshots for these ids bypass an older optimistic lock.
    var readBackInFlightTicket: [String: UInt64] = [:]
    /// Latest ticket per device. Unlike `readBackOwner`, this survives a completed newer toggle,
    /// so an older echo retry can still tell that it has been superseded (#201 review).
    var latestReadBackTicket: [String: UInt64] = [:]
    var nextReadBackTicket: UInt64 = 0

    func releaseReadBackEcho() {
        isHoldingReadBackEcho = false
        readBackEchoHold?.resume()
        readBackEchoHold = nil
    }

    public internal(set) var listCut: DeviceListCut = .all
    public var expandedDeviceId: String? = nil
    public var focusedDeviceId: String? = nil
    public var isOptionKeyPressed: Bool = false
    public var isShowingSettings: Bool = false
    /// Transient flag for the QR re-auth overlay (#181).
    public var isShowingMiReauth: Bool = false

    let userDefaults: UserDefaults

    public var hideOfflineDevices: Bool {
        didSet { userDefaults.set(hideOfflineDevices, forKey: "hide_offline_devices") }
    }

    /// Hide lights that belong to a Mi light group while the group card itself is on screen (#189).
    public var hideGroupedLights: Bool {
        didSet { userDefaults.set(hideGroupedLights, forKey: "hide_grouped_lights") }
    }

    public var enableGlobalHotkey: Bool {
        didSet {
            userDefaults.set(enableGlobalHotkey, forKey: "enable_global_hotkey")
            onGlobalHotkeyPreferenceChanged?(enableGlobalHotkey)
        }
    }

    public var isCompactGridMode: Bool {
        didSet { userDefaults.set(isCompactGridMode, forKey: "compact_grid_mode") }
    }

    public var showQuickActionsBar: Bool {
        didSet { userDefaults.set(showQuickActionsBar, forKey: "show_quick_actions_bar") }
    }

    public var enableGrokBall: Bool {
        didSet { userDefaults.set(enableGrokBall, forKey: "enable_grok_ball") }
    }

    public var favoriteDeviceIds: Set<String> {
        didSet {
            userDefaults.set(Array(favoriteDeviceIds), forKey: ViewPreferenceKeys.favoriteDeviceIds)
        }
    }

    public var favoriteOrder: [String] {
        didSet {
            userDefaults.set(favoriteOrder, forKey: ViewPreferenceKeys.favoriteOrder)
        }
    }

    public var hiddenDeviceIds: Set<String> {
        didSet {
            userDefaults.set(Array(hiddenDeviceIds), forKey: ViewPreferenceKeys.hiddenDeviceIds)
        }
    }

    /// Per-device choice for 全关; a missing entry means the default from `joinsAllOffByDefault` (#23).
    public var allOffOverrides: [String: Bool] {
        didSet { userDefaults.set(allOffOverrides, forKey: ViewPreferenceKeys.allOffOverrides) }
    }

    public var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { userDefaults.set(menuBarDisplayMode.rawValue, forKey: "menubar_display_mode") }
    }

    public var menuBarTargetId: String {
        didSet { userDefaults.set(menuBarTargetId, forKey: ViewPreferenceKeys.menuBarTargetId) }
    }

    public var enableSafetyAlerts: Bool {
        didSet { userDefaults.set(enableSafetyAlerts, forKey: "enable_safety_alerts") }
    }

    /// Refuse user-initiated device control while the Mac screen is locked (#143). Defaults on:
    /// the only paths that can still fire while locked are external ones (URL links, App Intents,
    /// assistant commands), and automation/scheduled rules stay exempt. Settings can turn it off.
    public var blockControlWhileLocked: Bool {
        didSet { userDefaults.set(blockControlWhileLocked, forKey: "block_control_while_locked") }
    }

    /// Set by `SystemActivityMonitor` from the distributed screen-lock notifications, not persisted.
    public internal(set) var isScreenLocked = false

    /// Presents the second confirmation for a manual high-risk action. The app installs an AppKit
    /// alert; tests inject a closure so no window is needed.
    @ObservationIgnored public var manualControlConfirmationHandler: ((ManualControlConfirmation) -> Bool)?

    /// Test seam for revocation failures: when set, deleting credentials targets this vault even for
    /// a custom defaults suite. Production leaves it nil and uses the Keychain/suite store.
    @ObservationIgnored var credentialVault: CredentialVault?

    public var sensorAlertsOnlyWhenAway: Bool {
        didSet { userDefaults.set(sensorAlertsOnlyWhenAway, forKey: Self.sensorAlertsOnlyWhenAwayKey) }
    }

    /// Explicit per-kind overrides. Reading this from `isSensorAlertEnabled` lets SwiftUI
    /// observe toggles that previously only reached `UserDefaults` (#199).
    public internal(set) var sensorAlertPreferences: [SensorAlertKind: Bool] = [:]

    public var homeName: String {
        didSet { userDefaults.set(homeName, forKey: "home_name") }
    }

    public var appLanguagePreference: AppLanguagePreference = .system {
        didSet {
            userDefaults.set(appLanguagePreference.rawValue, forKey: "app_language")
            syncEffectiveLanguage()
        }
    }

    public private(set) var effectiveLanguage: AppLanguage = .zhHans

    public var miCloudRegion: MiCloudRegion = .cn {
        didSet {
            userDefaults.set(miCloudRegion.rawValue, forKey: "mi_cloud_region")
        }
    }

    public var isHabitLearningEnabled: Bool = true {
        didSet { userDefaults.set(isHabitLearningEnabled, forKey: "assistant_habit_learning_enabled") }
    }

    public var habitSharing: HabitSharing = .off {
        didSet { userDefaults.set(habitSharing == .on, forKey: "assistant_habit_share_enabled") }
    }

    /// Test seam for the manual-control debounce window (sliders fire continuously, #113).
    var controlDebounceInterval: Duration = .milliseconds(280)

    /// Ask macOS to keep speech recognition on this Mac (no audio sent to Apple) when the language supports it.
    /// Defaults on for privacy; an explicitly saved `false` still wins (#50).
    public var prefersOnDeviceSpeech: Bool = true {
        didSet { userDefaults.set(prefersOnDeviceSpeech, forKey: "assistant_on_device_speech") }
    }

    /// Persisted flag set once the user finishes or dismisses the first-launch onboarding guide.
    public var hasCompletedOnboarding: Bool = false {
        didSet { userDefaults.set(hasCompletedOnboarding, forKey: "has_completed_onboarding") }
    }

    /// Steps the guide has seen the user try (#180). Persisted so the checkmarks survive a relaunch.
    /// Connecting is deliberately not stored here: it is derived from the live connection state.
    public internal(set) var onboardingMilestones: Set<OnboardingMilestone> = []

    /// Plain-language "不确定时先问我" switch (#180). On by default, matching the shared
    /// confirmation rules both platforms ship with; the numeric threshold lives in advanced settings.
    public var askWhenUnsureBeforeAIActions: Bool = true {
        didSet { userDefaults.set(askWhenUnsureBeforeAIActions, forKey: Self.askWhenUnsureKey) }
    }

    /// Transient flag allowing the user to reopen the onboarding guide from Settings at any time.
    public var isShowingOnboarding: Bool = false

    /// Which onboarding surface to draw. The full guide only replaces the dashboard while nothing
    /// is configured; after connecting, the remaining lessons ride above the dashboard so search and
    /// All Off/Undo can be tried while the instructions stay visible (#180 review).
    public var onboardingPresentation: OnboardingPresentation {
        OnboardingPresentation.resolve(
            checklist: onboardingChecklist,
            hasCompletedOnboarding: hasCompletedOnboarding,
            isReopened: isShowingOnboarding
        )
    }

    /// Any onboarding surface is on screen: the full guide or the dashboard checklist.
    public var shouldShowOnboarding: Bool {
        onboardingPresentation != .hidden
    }

    /// The full-screen guide replaces the dashboard. Only true before a source is configured.
    public var showsFullOnboardingGuide: Bool {
        onboardingPresentation == .fullGuide
    }

    /// The compact next-steps card rides above the live dashboard.
    public var showsOnboardingChecklist: Bool {
        onboardingPresentation == .dashboardChecklist
    }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        isShowingOnboarding = false
    }

    public func reopenOnboarding() {
        isShowingSettings = false
        isShowingOnboarding = true
    }

    public var serverURLString: String {
        didSet {
            userDefaults.set(serverURLString, forKey: "ha_server_url")
            syncSensorHistoryScope()
        }
    }

    public internal(set) var homeBackend: HomeBackend {
        didSet {
            userDefaults.set(homeBackend.rawValue, forKey: "home_backend")
            syncSensorHistoryScope()
            if homeBackend == .demo { deviceValuesAreStale = false }
        }
    }

    public internal(set) var miSessionMaskedUserId: String?
    /// Every signed-in Mi account, primary (first) first. The panel groups by account when there is
    /// more than one, and adding an account never replaces the ones already signed in.
    public internal(set) var miAccounts: [MiAccount] = []
    /// Per-account connection state reported by `MiAccountsProvider` so Settings can flag an
    /// expired/disconnected account even while another account keeps `connectionStatus == .connected`.
    public internal(set) var miAccountStatuses: [String: ConnectionStatus] = [:]
    /// The session's one absolute end: carried by the login response, or the last rejection time (#181).
    public internal(set) var miSessionExpiresAt: Date? {
        didSet {
            if miSessionExpiresAt != oldValue {
                scheduleMiSessionExpiryTransition()
            }
        }
    }
    var miSessionExpiryRevision: UInt64 = 0
    var miSessionExpiryTimerTask: Task<Void, Never>?
    var miSessionScopeIdentifier: String? {
        didSet { syncSensorHistoryScope() }
    }

    /// Whether an HA token is saved. The chosen `homeBackend` no longer implies the only live source.
    public internal(set) var hasHASource: Bool = false
    public var hasMiSource: Bool { miSessionMaskedUserId != nil }
    public var isDualSourceActive: Bool {
        homeBackend != .demo && hasHASource && hasMiSource
    }
    public var preferredLiveBackend: HomeBackend {
        if hasHASource { return .homeAssistant }
        if hasMiSource { return .xiaomiCloud }
        return .homeAssistant
    }
    /// Which provider currently drives each merged card.
    public internal(set) var deviceBackends: [String: HomeBackend] = [:]
    /// Cards that exist in both sources; only these offer a source pin (#111).
    public internal(set) var pairedDeviceIDs: Set<String> = []
    /// Per-source state from the latest merged snapshot; drives the dual-source footer summary (#111).
    public internal(set) var sourceStatuses: [HomeBackend: ConnectionStatus] = [:]
    /// Explicit per-card source choices, keyed by canonical card id (#111).
    public internal(set) var pinnedDeviceSources: [String: HomeBackend] = [:] {
        didSet { DeviceSourcePinStorage.save(pinnedDeviceSources, defaults: userDefaults) }
    }
    /// Sources that contributed the latest merged snapshot.
    public internal(set) var connectedBackends: Set<HomeBackend> = []

    public func deviceBackend(for deviceId: String) -> HomeBackend {
        deviceBackends[deviceId] ?? homeBackend
    }

    /// A card is pinnable only when both sources supplied the same physical device.
    public func isPairedDualSourceDevice(_ deviceId: String) -> Bool {
        isDualSourceActive && pairedDeviceIDs.contains(deviceId)
    }

    public func pinnedSource(for deviceId: String) -> HomeBackend? {
        pinnedDeviceSources[deviceId]
    }

    /// `nil` restores automatic online → capability → Home Assistant selection.
    public func pinDeviceSource(_ deviceId: String, to backend: HomeBackend?) {
        var next = pinnedDeviceSources
        if let backend, backend != .demo {
            next[deviceId] = backend
        } else {
            next.removeValue(forKey: deviceId)
        }
        guard next != pinnedDeviceSources else { return }
        pinnedDeviceSources = next
        (provider as? any DualSourceRecomputing)?.requestRecompute()
    }

    private enum SourceState {
        case connected, connecting, offline
    }

    private func sourceState(_ backend: HomeBackend) -> SourceState {
        if let status = sourceStatuses[backend] {
            switch status {
            case .connected: return .connected
            case .connecting: return .connecting
            case .disconnected: return .offline
            }
        }
        return connectedBackends.contains(backend) ? .connected : .connecting
    }

    /// Bottom-bar summary while both sources are configured. `nil` on a single source, where the
    /// existing footer already names it.
    public var dualSourceStatusSummary: String? {
        guard isDualSourceActive else { return nil }
        if case .disconnected = connectionStatus {
            return L10n.tr("HA 与 米家云均未连接", "Home Assistant and Xiaomi Cloud are both offline")
        }
        let ha = sourceState(.homeAssistant)
        let mi = sourceState(.xiaomiCloud)
        switch (ha, mi) {
        case (.connected, .connected):
            return L10n.tr("HA + 米家云已连接", "HA + Xiaomi Cloud connected")
        case (.connected, .offline):
            return L10n.tr("HA 已连接（米家云离线已自动兜底）", "HA connected (Xiaomi Cloud offline, automatic fallback)")
        case (.offline, .connected):
            return L10n.tr("米家云已连接（HA 离线已自动兜底）", "Xiaomi Cloud connected (HA offline, automatic fallback)")
        case (.connected, .connecting):
            return L10n.tr("HA 已连接 · 米家云连接中", "HA connected · Xiaomi Cloud connecting")
        case (.connecting, .connected):
            return L10n.tr("米家云已连接 · HA 连接中", "Xiaomi Cloud connected · HA connecting")
        case (.connecting, .offline):
            return L10n.tr("HA 连接中 · 米家云未连接", "HA connecting · Xiaomi Cloud offline")
        case (.offline, .connecting):
            return L10n.tr("米家云连接中 · HA 未连接", "Xiaomi Cloud connecting · HA offline")
        case (.connecting, .connecting):
            return L10n.tr("HA 与 米家云连接中…", "Home Assistant and Xiaomi Cloud connecting…")
        case (.offline, .offline):
            return L10n.tr("HA 与 米家云均未连接", "Home Assistant and Xiaomi Cloud are both offline")
        }
    }

    public var connectionSourceSummary: String {
        if homeBackend == .demo { return L10n.tr("演示模式", "Demo Mode") }
        if hasHASource && hasMiSource {
            return L10n.tr("Home Assistant + 米家云端", "Home Assistant + Xiaomi Cloud")
        }
        if hasMiSource { return L10n.tr("米家云端", "Xiaomi Cloud") }
        if hasHASource { return "Home Assistant" }
        return L10n.tr("尚未配置数据源", "No data source configured")
    }

    public private(set) var toastNotice: ToastNotice?
    public internal(set) var undoBanner: UndoBanner? {
        didSet {
            if undoBanner != nil {
                undoStateRevision &+= 1
            }
        }
    }
    var undoStateRevision: UInt64 = 0
    public var onSafetyAlert: ((SafetyAlert) -> Void)?
    public var onGlobalHotkeyPreferenceChanged: ((Bool) -> Void)?

    public var onOpenCameraLiveView: ((SmartDevice) -> Void)?
    public internal(set) var activeLiveCameraDeviceId: String?
    public static let cameraStreamURLsKey = ViewPreferenceKeys.cameraStreamURLs
    public static let cameraStreamQualityKey = ViewPreferenceKeys.cameraStreamQuality
    public static let automaticUpdateCheckInterval: TimeInterval = 6 * 3600
    public internal(set) var updateState: AppUpdateState = .idle
    public var automaticallyChecksForUpdates: Bool = true {
        didSet {
            userDefaults.set(automaticallyChecksForUpdates, forKey: "automatically_checks_for_updates")
            if automaticallyChecksForUpdates && !oldValue {
                Task { @MainActor [weak self] in
                    await self?.checkForUpdatesIfNeeded()
                }
            }
        }
    }
    public var onTerminateForUpdate: (() -> Void)?
    public var updater: AppUpdater
    /// Local energy history fed by provider snapshots (#62).
    public let energyHistory: EnergyHistory
    /// Local + cloud merged history for temperature and humidity sensors.
    public let sensorHistory: SensorHistory
    var updateTask: Task<Void, Never>?
    var activeUpdateAttemptID: UUID?

    public var lgConfig: LGWebOSConfig {
        didSet { lgConfig.save(to: userDefaults) }
    }

    public internal(set) var discoveredHAInstances: [HADiscoveredInstance] = []
    /// Another Home Assistant address found after disconnects; only used if the user taps 切换 (#18).
    public internal(set) var pendingHAAddressSuggestion: HADiscoveredInstance?
    var dismissedHAAddressURLs: Set<String> = []
    public internal(set) var isDiscoveringHA: Bool = false

    var provider: any HomeProvider
    var controlContextID = UUID()
    var lgWebOSClient: LGWebOSClient?
    let isTestEnvironment: Bool
    var latestLGDevice: SmartDevice?
    var eventTask: Task<Void, Never>?
    /// Panel open, Mac awake, Low Power Mode; the provider paces polling with it (#26).
    public internal(set) var pollingContext = PollingContext()
    var pollingContextSync: Task<Void, Never>?
    var debounceTasks: [String: Task<Void, Never>] = [:]
    var undoTimerTask: Task<Void, Never>?
    private var toastTimerTask: Task<Void, Never>?
    var optimisticLockUntil: [String: ContinuousClock.Instant] = [:]
    var optimisticLockRevision: [String: UInt64] = [:]
    public static let deviceAliasesKey = ViewPreferenceKeys.deviceAliases
    var rawDeviceNames: [String: String] = [:]

    var lowBatteryAlertedAt: [String: Date] = [:]
    var sensorEdge: [String: Bool] = [:]
    var awayGap = MacAwayGap(includesAway: false)
    var activeSinceByDeviceId: [String: Date] = [:]
    var longRunAlertedForSession: Set<String> = []

    static let lastManualLightIdKey = ViewPreferenceKeys.lastManualLightId
    /// Last light the user switched on by hand; the 柔和夜灯 fallback uses it instead of "主卧" (#36).
    var lastManuallyUsedLightId: String?
    /// A legacy 主卧/阳台 menu-bar mode was migrated; pick the first temperature sensor when readings arrive.
    var pendingLegacyMenuBarTargetMigration = false
    var previousOnlineDeviceIds: Set<String> = []

    public init(
        provider: (any HomeProvider)? = nil,
        dualSource: (homeAssistant: any HomeProvider, xiaomiCloud: any HomeProvider)? = nil,
        defaultsSuiteName: String? = nil,
        updater: AppUpdater? = nil
    ) {
        let ud = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.userDefaults = ud
        self.pinnedDeviceSources = DeviceSourcePinStorage.load(defaults: ud)
        let isTestEnvironment = (provider != nil || dualSource != nil || defaultsSuiteName != nil)
        self.isTestEnvironment = isTestEnvironment
        self.updater = updater ?? AppUpdater()
        self.energyHistory = EnergyHistory(defaults: ud)
        self.sensorHistory = SensorHistory(defaults: ud)
        // ≤1.0.6 mirrored credentials into plain `UserDefaults`; move them into the Keychain before any read (#16).
        if !isTestEnvironment && ud === UserDefaults.standard {
            KeychainHelper.migratePlaintextCredentialsToKeychain(defaults: ud)
        }
        let boolOrDefaultTrue = { (key: String) -> Bool in
            ud.object(forKey: key) == nil ? true : ud.bool(forKey: key)
        }
        self.automaticallyChecksForUpdates = boolOrDefaultTrue("automatically_checks_for_updates")

        let savedLangPref = ud.string(forKey: "app_language").flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
        self.appLanguagePreference = savedLangPref
        let initialEffective: AppLanguage = (self.isTestEnvironment && savedLangPref == .system)
            ? .zhHans
            : savedLangPref.resolved()
        self.effectiveLanguage = initialEffective
        if !self.isTestEnvironment {
            L10n.currentLanguage = initialEffective
        }

        let initialAccounts = MiSessionStore.loadAccounts(defaults: ud)
        self.miAccounts = initialAccounts
        let initialMiSession = initialAccounts.first?.session
        let savedRegion = ud.string(forKey: "mi_cloud_region").flatMap(MiCloudRegion.init(rawValue:))
            ?? initialMiSession.flatMap { MiCloudRegion(rawValue: $0.region.lowercased()) }
            ?? .cn
        self.miCloudRegion = savedRegion

        let savedURL = ud.string(forKey: "ha_server_url") ?? KeychainHelper.defaultNASURL
        self.serverURLString = savedURL
        let initialBackend = ud.string(forKey: "home_backend").flatMap(HomeBackend.init(rawValue:)) ?? .homeAssistant
        self.homeBackend = initialBackend
        // Demo mode and injected providers must not touch the Keychain until live mode needs it.
        let needsInitialHAToken = provider == nil && dualSource == nil && initialBackend != .demo
        let initialHAToken = needsInitialHAToken ? KeychainHelper.loadToken(defaults: ud) : ""
        self.hasHASource = !initialHAToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.miSessionMaskedUserId = initialMiSession?.maskedUserId
        self.miSessionExpiresAt = initialAccounts.compactMap(\.session.expiresAt).min()
        self.miSessionScopeIdentifier = initialMiSession?.historyScopeIdentifier
        // A home id saved before multi-account has no account prefix. The only account owns it; with
        // zero or several accounts a bare id is ambiguous, so it is dropped rather than guessed.
        var initialSelectedHomeId = ud.string(forKey: MiCloudProvider.selectedHomeKey)
        if let selection = initialSelectedHomeId, !selection.contains("/") {
            if initialAccounts.count == 1, let onlyAccount = initialAccounts.first {
                let scoped = "\(onlyAccount.id)/\(selection)"
                initialSelectedHomeId = scoped
                ud.set(scoped, forKey: MiCloudProvider.selectedHomeKey)
            } else {
                initialSelectedHomeId = nil
                ud.removeObject(forKey: MiCloudProvider.selectedHomeKey)
            }
        }
        self.selectedMiHomeId = initialSelectedHomeId
        self.lgConfig = LGWebOSConfig.load(from: ud)
        self.homeName = ud.string(forKey: "home_name") ?? KeychainHelper.localizedDefaultHomeName
        self.isHabitLearningEnabled = boolOrDefaultTrue("assistant_habit_learning_enabled")
        let habitShareKey = "assistant_habit_share_enabled"
        let storedHabitShare: StoredHabitShare
        if let object = ud.object(forKey: habitShareKey) {
            if let flag = object as? Bool {
                storedHabitShare = flag ? .on : .off
            } else {
                storedHabitShare = .absent
            }
        } else {
            storedHabitShare = .absent
        }
        let habitShare = resolveHabitSharing(storedHabitShare)
        if habitShare.persistOff {
            ud.set(false, forKey: habitShareKey)
        }
        self.habitSharing = habitShare.sharing
        // Privacy-first default: ask for on-device recognition unless the user explicitly opted out (#50).
        self.prefersOnDeviceSpeech = boolOrDefaultTrue("assistant_on_device_speech")
        self.hasCompletedOnboarding = ud.bool(forKey: "has_completed_onboarding")
        self.onboardingMilestones = Set(
            (ud.stringArray(forKey: Self.onboardingMilestonesKey) ?? [])
                .compactMap(OnboardingMilestone.init(rawValue:))
        )
        self.askWhenUnsureBeforeAIActions = boolOrDefaultTrue(Self.askWhenUnsureKey)
        self.hideOfflineDevices = ud.bool(forKey: "hide_offline_devices")
        self.hideGroupedLights = boolOrDefaultTrue("hide_grouped_lights")
        self.enableGlobalHotkey = boolOrDefaultTrue("enable_global_hotkey")
        self.enableSafetyAlerts = boolOrDefaultTrue("enable_safety_alerts")
        self.blockControlWhileLocked = boolOrDefaultTrue("block_control_while_locked")
        self.sensorAlertsOnlyWhenAway = ud.bool(forKey: Self.sensorAlertsOnlyWhenAwayKey)
        self.sensorAlertPreferences = SensorAlertKind.allCases.reduce(into: [SensorAlertKind: Bool]()) { preferences, kind in
            if ud.object(forKey: kind.defaultsKey) != nil {
                preferences[kind] = ud.bool(forKey: kind.defaultsKey)
            }
        }
        self.awayGap = MacAwayGap(includesAway: ud.bool(forKey: MacAwayGap.storageKey))
        self.isCompactGridMode = (ud.object(forKey: "compact_grid_mode") as? Bool) ?? true
        self.showQuickActionsBar = boolOrDefaultTrue("show_quick_actions_bar")
        self.enableGrokBall = ud.bool(forKey: "enable_grok_ball")
        self.menuBarTargetId = ud.string(forKey: "menubar_target_id") ?? "auto:primary"
        self.lastManuallyUsedLightId = ud.string(forKey: Self.lastManualLightIdKey)
        self.lowBatteryAlertedAt = Self.loadLowBatteryAlertedAt(from: ud)
        self.sensorEdge = Self.loadSensorEdge(from: ud)

        let savedModeRaw = ud.string(forKey: "menubar_display_mode")
        if let savedModeRaw, let mode = MenuBarDisplayMode(rawValue: savedModeRaw) {
            self.menuBarDisplayMode = mode
        } else if let savedModeRaw, MenuBarDisplayMode.legacyTemperatureRawValues.contains(savedModeRaw) {
            // ≤1.0.x stored 主卧/阳台 modes. Keep the user on a temperature readout, but let the
            // generic sensor option pick whichever sensor exists in this home (#36).
            self.menuBarDisplayMode = .sensorTemperature
            ud.set(MenuBarDisplayMode.sensorTemperature.rawValue, forKey: "menubar_display_mode")
            let savedTarget = ud.string(forKey: "menubar_target_id")
            self.pendingLegacyMenuBarTargetMigration = savedTarget == nil || savedTarget == "auto:primary"
        } else {
            self.menuBarDisplayMode = .sensorTemperature
        }

        if let savedFavs = ud.stringArray(forKey: "favorite_device_ids") {
            self.favoriteDeviceIds = Set(savedFavs)
        } else {
            self.favoriteDeviceIds = []
        }
        self.favoriteOrder = ud.stringArray(forKey: "favorite_order") ?? []
        if let savedHidden = ud.stringArray(forKey: "hidden_device_ids") {
            self.hiddenDeviceIds = Set(savedHidden)
        } else {
            self.hiddenDeviceIds = []
        }
        self.allOffOverrides = ud.dictionary(forKey: "all_off_overrides") as? [String: Bool] ?? [:]

        let initialProvider: any HomeProvider
        if let provider {
            initialProvider = provider
        } else if let dualSource {
            initialProvider = Self.makeComposite(
                homeAssistant: dualSource.homeAssistant,
                xiaomiCloud: dualSource.xiaomiCloud,
                defaults: ud
            )
        } else if initialBackend == .xiaomiCloud {
            initialProvider = Self.makeMiAccountsProvider(accounts: initialAccounts, defaults: ud)
        } else if initialBackend == .demo {
            initialProvider = DemoHomeProvider()
        } else {
            initialProvider = HAWebSocketProvider(baseURLString: savedURL, token: initialHAToken)
        }
        self.provider = initialProvider
        if provider == nil, dualSource == nil, initialBackend != .demo {
            self.provider = makeLiveProvider()
        }
        syncSensorHistoryScope()
        scheduleMiSessionExpiryTransition()
        startListening()
        restoreScheduledCommands()
        // Demo mode is strictly offline: no LAN discovery, no LG connection (#47).
        if provider == nil, dualSource == nil, initialBackend != .demo {
            startLGWebOSIfNeeded()
            Task { [weak self] in
                _ = await self?.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
            }
        }
    }

    /// One `MiCloudProvider` per account behind a single `HomeProvider`, so a second sign-in merges
    /// into the panel instead of replacing the first account.
    private static func makeMiAccountsProvider(accounts: [MiAccount], defaults: UserDefaults) -> MiAccountsProvider {
        nonisolated(unsafe) let ud = defaults
        return MiAccountsProvider(
            accounts: accounts,
            selectedHomeLoader: { ud.string(forKey: MiCloudProvider.selectedHomeKey) }
        )
    }

    /// Re-reads the stored accounts (a login, a removal or a sign-out changed them) and rebuilds the
    /// provider around the current list.
    func makeMiAccountsProvider() -> MiAccountsProvider {
        miAccounts = MiSessionStore.loadAccounts(defaults: userDefaults)
        return Self.makeMiAccountsProvider(accounts: miAccounts, defaults: userDefaults)
    }

    /// Re-resolves `effectiveLanguage` and pushes it to `L10n`; also called from the language
    /// preference setter and from localization extensions (#52).
    func syncEffectiveLanguage() {
        let next: AppLanguage = (isTestEnvironment && appLanguagePreference == .system)
            ? .zhHans
            : appLanguagePreference.resolved()
        effectiveLanguage = next
        if !isTestEnvironment {
            L10n.currentLanguage = next
        }
        if homeName == "我的家" || homeName == "My Home" {
            let localizedDefault = next == .en ? "My Home" : "我的家"
            if homeName != localizedDefault {
                homeName = localizedDefault
            }
        }
    }

    public func showToast(_ message: String, isError: Bool = false) {
        let notice = ToastNotice(message: message, isError: isError)
        self.toastNotice = notice
        toastTimerTask?.cancel()
        toastTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            if self?.toastNotice?.id == notice.id {
                self?.toastNotice = nil
            }
        }
    }

    // MARK: - Command Execution & Optimistic Locks

    func updateValueFreshness() {
        switch connectionStatus {
        case .disconnected where hasReceivedInitialSnapshot && homeBackend != .demo:
            deviceValuesAreStale = true
        case .connected:
            deviceValuesAreStale = false
        case .connecting, .disconnected:
            break
        }
    }

    func executeDeviceCommand(_ command: DeviceCommand) async throws {
        if LGWebOSProtocol.isLGEntity(command.targetEntityId), let lgClient = lgWebOSClient {
            try await lgClient.execute(command)
        } else {
            try await provider.execute(command)
        }
    }

    @discardableResult
    func lockOptimistic(_ deviceId: String, duration: Duration) -> UInt64 {
        let rev = (optimisticLockRevision[deviceId] ?? 0) &+ 1
        optimisticLockRevision[deviceId] = rev
        optimisticLockUntil[deviceId] = ContinuousClock.now.advanced(by: duration)
        return rev
    }

    // MARK: - Assistant Commands & Personalized Jev Context

    public var isShowingAssistantBar: Bool = false
    /// Bumped to ask an already-visible command bar to take keyboard focus.
    public internal(set) var assistantFocusRequest: Int = 0
    /// Bumped to ask the command bar to start or toggle live speech recognition.
    public internal(set) var assistantVoiceRequest: Int = 0
    public internal(set) var assistantState: AssistantState = .idle
    /// Receipt for the latest command, cleared as soon as the reply resets (#93).
    public internal(set) var lastAssistantReceipt: AssistantExecutionReceipt?
    /// A command or suggestion request waiting for the user to allow sending it to a cloud AI service (#20).
    public internal(set) var pendingCloudConsent: PendingCloudConsent?
    public internal(set) var assistantSuggestions: [AssistantSuggestion] = []
    /// Cached model proactive recommendations for `lastProactiveRefreshSignature` (#113).
    var aiProactiveSuggestions: [AssistantSuggestion]?
    public internal(set) var isProactiveRecommending: Bool = false
    /// Ambient signature (time bucket + rounded readings) the suggestion cache was built from (#113).
    var lastProactiveRefreshSignature: String?
    /// Earliest moment a failed background refresh may retry (Codex #116 review).
    var proactiveRetryEarliest: Date?
    /// Cooldown before a failed background refresh retries; test seam.
    var proactiveRetryCooldown: TimeInterval = 300
    /// The running silent refresh, exposed so tests can await it.
    var proactiveRefreshTask: Task<Void, Never>?
    /// Whether the GrokBall star stage with its 4 radial suggestions is open (#114).
    public internal(set) var isGrokBallStageExpanded: Bool = false
    /// GrokBall shows `33` (confetti) until this moment after a successful control (#114).
    public internal(set) var grokBallCelebrationUntil: Date?
    var grokBallCelebrationTask: Task<Void, Never>?
    var assistantResetTask: Task<Void, Never>?
    /// Test seam replacing the network resolver built from `assistantConfig`.
    var assistantResolverOverride: ModelIntentResolver?
    /// Test seam replacing only the HTTP transport while still resolving `assistantConfig` from `userDefaults`.
    var assistantTransportOverride: ModelIntentResolver.Transport?
    /// Test seam replacing the on-device resolver built by `localCommandResolver(for:)`.
    var localAssistantResolverOverride: (any AssistantCommandResolving)?
    /// Test seam overriding whether Apple's on-device model is usable on this machine.
    var localAssistantAvailabilityOverride: AssistantLocalModelAvailability?
    /// Commands waiting on a spoken delay ("10 分钟后关灯"), soonest first. Persisted across launches.
    public internal(set) var scheduledCommands: [ScheduledCommand] = []
    /// Timers that came due while the app was closed or the Mac slept. Never auto-executed without user confirmation.
    public internal(set) var missedScheduledCommands: [ScheduledCommand] = []
    public var onMissedScheduledCommand: ((ScheduledCommand) -> Void)?
    var notifiedMissedTimerIds: Set<UUID> = []
    var scheduledTasks: [UUID: Task<Void, Never>] = [:]
    /// The most recent assistant action, kept so "撤销" can restore it after the 5 s banner is gone.
    var lastAssistantUndo: (
        reply: String,
        restore: [DeviceCommand],
        previous: [SmartDevice],
        at: Date,
        habitReceipt: UserHabitMemory.RecordingReceipt?
    )? {
        didSet {
            if lastAssistantUndo != nil {
                undoStateRevision &+= 1
            }
        }
    }
    public var lastAssistantActionAt: Date? { lastAssistantUndo?.at }
    /// How long a spoken "撤销" can still reach back.
    static let voiceUndoWindow: TimeInterval = 10 * 60
    /// Test seam for the delay before a scheduled command fires.
    var assistantSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Test seam for "now" when a timer wakes up, so a Mac that slept through it can be simulated.
    var assistantNow: @Sendable () -> Date = { Date() }
    /// A timer that wakes up later than this (the Mac slept, the app was frozen) waits for the user (#22).
    static let lateTimerGrace: TimeInterval = 60
}
