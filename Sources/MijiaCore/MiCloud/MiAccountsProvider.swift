import Foundation

/// `HomeProvider` over several Xiaomi accounts: one `MiCloudProvider` per account, merged into one
/// panel listing whose devices and homes carry the account they came from.
public actor MiAccountsProvider: HomeProvider {
    private let accounts: [MiAccount]
    private let apiFactory: MiCloudProvider.APIFactory
    private let specSource: any MiotSpecSource
    private let cameraBridge: any XiaomiCameraBridging
    private let pollInterval: Duration
    private let closedPollInterval: Duration
    private let deviceRefreshEveryPolls: Int
    private let followUpDelay: Duration
    private let cameraSessionReleaseDelay: Duration
    private let selectedHomeLoader: @Sendable () -> String?

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var children: [(account: MiAccount, provider: MiCloudProvider)] = []
    private var forwardTasks: [Task<Void, Never>] = []
    private var snapshots: [String: SynthesizedHome] = [:]
    private var statuses: [String: ConnectionStatus] = [:]
    /// Accounts that delivered a post-poll snapshot (`closesAwayGap == true`) in the current wake cycle.
    private var freshAccounts: Set<String> = []
    /// did → owning accounts in account order; a did shared by two accounts keeps its first owner first.
    private var deviceOwners: [String: [String]] = [:]
    private var lastStatus: ConnectionStatus?
    private var pollingContext = PollingContext()

    public init(
        accounts: [MiAccount],
        apiFactory: @escaping MiCloudProvider.APIFactory = { MiCloudClient(session: $0) },
        specSource: any MiotSpecSource = MiotSpecStore(),
        cameraBridge: any XiaomiCameraBridging = XiaomiCameraBridge.shared,
        pollInterval: Duration = PollingPolicy.panelOpenInterval,
        closedPollInterval: Duration = PollingPolicy.panelClosedInterval,
        deviceRefreshEveryPolls: Int = 20,
        followUpDelay: Duration = .milliseconds(800),
        cameraSessionReleaseDelay: Duration = .milliseconds(2500),
        selectedHomeLoader: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey)
        }
    ) {
        self.accounts = accounts
        self.apiFactory = apiFactory
        self.specSource = specSource
        self.cameraBridge = cameraBridge
        self.pollInterval = pollInterval
        self.closedPollInterval = closedPollInterval
        self.deviceRefreshEveryPolls = deviceRefreshEveryPolls
        self.followUpDelay = followUpDelay
        self.cameraSessionReleaseDelay = cameraSessionReleaseDelay
        self.selectedHomeLoader = selectedHomeLoader
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ cont: AsyncStream<HomeProviderEvent>.Continuation) async {
        continuation = cont
        guard !accounts.isEmpty else {
            cont.yield(.statusChanged(.disconnected(MiCloudError.notLoggedIn.localizedDescription)))
            return
        }
        if children.isEmpty { startChildren() }
        await applyPollingContext()
    }

    private func startChildren() {
        for account in accounts {
            let provider = MiCloudProvider(
                account: account,
                apiFactory: apiFactory,
                specSource: specSource,
                cameraBridge: cameraBridge,
                pollInterval: pollInterval,
                closedPollInterval: closedPollInterval,
                deviceRefreshEveryPolls: deviceRefreshEveryPolls,
                followUpDelay: followUpDelay,
                cameraSessionReleaseDelay: cameraSessionReleaseDelay,
                selectedHomeLoader: scopedSelection(for: account)
            )
            children.append((account: account, provider: provider))
            let stream = provider.events()
            forwardTasks.append(Task { [weak self] in
                for await event in stream {
                    await self?.handle(event, from: account.id)
                }
            })
        }
    }

    /// The child provider only understands raw home ids, while the app stores `"<accountID>/<homeID>"`.
    /// A bare id from before multi-account belongs to the first account. When another signed-in account's
    /// home is selected, this child hides its devices/rooms while still reporting its home options.
    private func scopedSelection(for account: MiAccount) -> @Sendable () -> String? {
        let loader = selectedHomeLoader
        let accountId = account.id
        let isFirst = accounts.first?.id == accountId
        let knownAccountIds = Set(accounts.map(\.id))
        return {
            guard let selection = loader(), !selection.isEmpty else { return nil }
            guard let slash = selection.firstIndex(of: "/") else {
                if isFirst { return selection }
                return knownAccountIds.count > 1 ? MiCloudProvider.otherAccountHomeSentinel : nil
            }
            let ownerId = String(selection[..<slash])
            guard ownerId == accountId else {
                return knownAccountIds.contains(ownerId) ? MiCloudProvider.otherAccountHomeSentinel : nil
            }
            let raw = String(selection[selection.index(after: slash)...])
            return raw.isEmpty ? nil : raw
        }
    }

    public func shutdown() async {
        for task in forwardTasks { task.cancel() }
        forwardTasks = []
        for child in children { await child.provider.shutdown() }
        children = []
        continuation?.finish()
        continuation = nil
    }

    public func refreshNow() async {
        let providers = children.map { $0.provider }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await provider.refreshNow() }
            }
        }
    }

    public func setPollingContext(_ context: PollingContext) async {
        if context.systemActive && !pollingContext.systemActive {
            freshAccounts.removeAll()
        }
        pollingContext = context
        await applyPollingContext()
    }

    private func applyPollingContext() async {
        let context = pollingContext
        let providers = children.map { $0.provider }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await provider.setPollingContext(context) }
            }
        }
    }

    // MARK: Merging Child Events

    private func handle(_ event: HomeProviderEvent, from accountId: String) {
        switch event {
        case .statusChanged(let status):
            statuses[accountId] = status
            publishStatus()
            if !snapshots.isEmpty {
                publishSnapshot()
            }
        case .sessionExpired(let session):
            continuation?.yield(.sessionExpired(session))
        case .sourceStatusesChanged:
            break
        case .snapshotUpdated(let home):
            snapshots[accountId] = home
            if home.closesAwayGap {
                freshAccounts.insert(accountId)
            } else {
                freshAccounts.remove(accountId)
            }
            rebuildDeviceOwners()
            publishSnapshot()
        }
    }

    /// Connected wins so one expired account cannot hide a working one.
    private func publishStatus() {
        var connected = false
        var seenConnecting = false
        var firstDisconnected: ConnectionStatus?
        for account in accounts {
            guard let status = statuses[account.id] else { continue }
            switch status {
            case .connected: connected = true
            case .connecting: seenConnecting = true
            case .disconnected: if firstDisconnected == nil { firstDisconnected = status }
            }
        }
        let aggregate: ConnectionStatus = connected
            ? .connected
            : (seenConnecting ? .connecting : (firstDisconnected ?? .connecting))
        guard aggregate != lastStatus else { return }
        lastStatus = aggregate
        continuation?.yield(.statusChanged(aggregate))
    }

    private func rebuildDeviceOwners() {
        var owners: [String: [String]] = [:]
        for account in accounts {
            guard let home = snapshots[account.id] else { continue }
            for device in home.devices {
                for key in [device.id] + device.miotCommandDids {
                    if owners[key]?.contains(account.id) == true { continue }
                    owners[key, default: []].append(account.id)
                }
            }
        }
        deviceOwners = owners
    }

    private func isDisconnectedWithNoDevices(_ accountId: String) -> Bool {
        guard case .disconnected = statuses[accountId],
              let home = snapshots[accountId],
              home.devices.isEmpty else {
            return false
        }
        return true
    }

    /// Account order first, first occurrence per id: a did shared by two accounts reaches the panel once.
    private func publishSnapshot() {
        let reported = accounts.compactMap { snapshots[$0.id] }
        guard !reported.isEmpty else { return }
        var rooms: [RoomArea] = []
        var devices: [SmartDevice] = []
        var readings: [EnvironmentReading] = []
        var scenes: [HomeScene] = []
        var homes: [HomeOption] = []
        var roomIds = Set<String>()
        var deviceIds = Set<String>()
        var readingIds = Set<String>()
        var sceneIds = Set<String>()
        var homeIds = Set<String>()
        var identities: [String: DeviceSourceIdentity] = [:]
        var lightGroupOwners: [String: String] = [:]
        var closesAwayGap = true
        for home in reported {
            closesAwayGap = closesAwayGap && home.closesAwayGap
            for room in home.rooms where roomIds.insert(room.id).inserted { rooms.append(room) }
            for device in home.devices where deviceIds.insert(device.id).inserted {
                devices.append(device)
                if let identity = home.deviceIdentities[device.id] {
                    identities[device.id] = identity
                }
            }
            for (id, identity) in home.deviceIdentities where identities[id] == nil {
                identities[id] = identity
            }
            for (memberDid, groupDid) in home.lightGroupOwners where lightGroupOwners[memberDid] == nil {
                lightGroupOwners[memberDid] = groupDid
            }
            for reading in home.environmentReadings where readingIds.insert(reading.id).inserted {
                readings.append(reading)
            }
            for scene in home.scenes where sceneIds.insert(scene.id).inserted { scenes.append(scene) }
            for option in home.homes where homeIds.insert(option.id).inserted { homes.append(option) }
        }
        var merged = SynthesizedHome(rooms: rooms, devices: devices, environmentReadings: readings, scenes: scenes)
        merged.homes = homes
        merged.accountStatuses = statuses
        merged.deviceIdentities = identities
        merged.lightGroupOwners = lightGroupOwners.filter {
            deviceIds.contains($0.key) && deviceIds.contains($0.value)
        }
        // A partially reported panel or a pre-sleep cached snapshot from another account must not
        // close an away gap: the missing account may hold the door sensor that changed while asleep.
        let allFreshAfterWake = accounts.allSatisfy {
            freshAccounts.contains($0.id) || isDisconnectedWithNoDevices($0.id)
        }
        merged.closesAwayGap = closesAwayGap && allFreshAfterWake
        continuation?.yield(.snapshotUpdated(merged))
    }

    private func childProvider(for accountId: String) -> MiCloudProvider? {
        children.first { $0.account.id == accountId }?.provider
    }

    // MARK: Commands & Device Calls

    public func execute(_ command: DeviceCommand) async throws {
        let entityId = command.targetEntityId
        guard let did = MiotAddress.parseAction(entityId)?.did ?? MiotAddress.parse(entityId)?.did else {
            throw MiotCommandError.invalidAddress(entityId)
        }
        let owners = deviceOwners[did] ?? []
        guard !owners.isEmpty else { throw MiotCommandError.unsupported(entityId) }
        var expired = false
        for ownerId in owners {
            guard let child = childProvider(for: ownerId) else { continue }
            do {
                try await child.execute(command)
                return
            } catch MiCloudError.sessionExpired {
                expired = true
            } catch {
                throw error
            }
        }
        throw expired ? MiCloudError.sessionExpired : MiCloudError.notLoggedIn
    }

    public func readBack(deviceId: String) async -> ControlReadBack {
        guard let ownerId = deviceOwners[deviceId]?.first,
              let child = childProvider(for: ownerId) else { return .failed }
        return await child.readBack(deviceId: deviceId)
    }

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        guard let ownerId = deviceOwners[deviceId]?.first,
              let child = childProvider(for: ownerId) else { return [] }
        return await child.fetchSensorHistory(deviceId: deviceId, window: window, now: now)
    }

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: .hd)
    }

    public func resolveCameraStream(for device: SmartDevice, quality: XiaomiCameraStreamQuality) async throws -> CameraStreamSource {
        let ownerId = deviceOwners[device.id]?.first ?? device.accountId
        guard let ownerId, let child = childProvider(for: ownerId) else {
            throw HomeProviderError.serviceCallFailed(
                501,
                L10n.tr("当前数据源暂未返回该摄像头的实时画面流", "Current backend did not return a live stream for this camera")
            )
        }
        return try await child.resolveCameraStream(for: device, quality: quality)
    }

    public func stopCameraStream(for device: SmartDevice) async {
        for ownerId in deviceOwners[device.id] ?? [] {
            guard let child = childProvider(for: ownerId) else { continue }
            await child.stopCameraStream(for: device)
        }
    }
}
