import Foundation
import os

/// `HomeProvider` that talks to Xiaomi cloud directly (no Home Assistant): discovers devices and
/// rooms, loads MIoT specs, polls properties and maps `DeviceCommand`s to MIoT writes.
public actor MiCloudProvider: HomeProvider {
    public typealias APIFactory = @Sendable (MiSession) -> any MiCloudAPI

    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "MiCloudProvider")
    /// The one account this provider polls; nil keeps the legacy single-session behaviour.
    private let account: MiAccount?
    private let sessionLoader: @Sendable () -> MiSession?
    private let apiFactory: APIFactory
    private let specSource: any MiotSpecSource
    private let cameraBridge: any XiaomiCameraBridging
    /// Poll interval while the panel is open; see `PollingPolicy` for the rest (#26).
    private let pollInterval: Duration
    private let closedPollInterval: Duration
    private let deviceRefreshEveryPolls: Int
    private let followUpDelay: Duration
    private let cameraSessionReleaseDelay: Duration
    private let selectedHomeLoader: @Sendable () -> String?

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    /// Whether the last status sent to the store was `.connected`; a transient read failure
    /// reports a disconnect that the next successful poll must clear (#201 review).
    private var lastReportedConnected = false
    private var loopTask: Task<Void, Never>?
    private var api: (any MiCloudAPI)?
    private var session: MiSession?
    /// A rejection is reported once; later failures must not re-open the re-auth prompt.
    private var didReportSessionExpired = false
    private var pendingCameraReleases: [String: Task<Void, Never>] = [:]

    private var devices: [MiDeviceRecord] = []
    private var rooms: [MiRoom] = []
    /// Light-group did → member dids, refreshed with the device list (#189).
    private var groupMembersByGroup: [String: [String]] = [:]
    private var specsByModel: [String: MiotDeviceSpec] = [:]
    private var values: [MiotPropKey: JSONValue] = [:]
    /// Lights whose `mode` write the cloud rejected as unsupported; their scene chips are hidden.
    private var effectsUnsupported: Set<String> = []

    private var pollingContext = PollingContext()
    private var lastFullPollAt: ContinuousClock.Instant?
    /// The loop's current wait; cancelling it makes the loop re-check `pollingContext` right away.
    private var waitTask: Task<Void, Never>?
    private var pollsSinceContextChange = 0
    /// Set on wake or unlock: poll once right away, however recent the last poll was.
    private var pollRequested = false

    public init(
        account: MiAccount? = nil,
        sessionLoader: @escaping @Sendable () -> MiSession? = { MiSessionStore.loadAccounts().first?.session },
        apiFactory: @escaping APIFactory = { MiCloudClient(session: $0) },
        specSource: any MiotSpecSource = MiotSpecStore(),
        cameraBridge: any XiaomiCameraBridging = XiaomiCameraBridge.shared,
        pollInterval: Duration = PollingPolicy.panelOpenInterval,
        closedPollInterval: Duration = PollingPolicy.panelClosedInterval,
        deviceRefreshEveryPolls: Int = 20,
        followUpDelay: Duration = .milliseconds(800),
        cameraSessionReleaseDelay: Duration = .milliseconds(2500),
        selectedHomeLoader: @escaping @Sendable () -> String? = { UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey) }
    ) {
        self.account = account
        self.sessionLoader = sessionLoader
        self.apiFactory = apiFactory
        self.specSource = specSource
        self.cameraBridge = cameraBridge
        self.pollInterval = pollInterval
        self.closedPollInterval = closedPollInterval
        self.deviceRefreshEveryPolls = max(1, deviceRefreshEveryPolls)
        self.followUpDelay = followUpDelay
        self.cameraSessionReleaseDelay = cameraSessionReleaseDelay
        self.selectedHomeLoader = selectedHomeLoader
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        continuation = cont
        restartLoop()
    }

    /// Stops polling and finishes the event stream; used when the user switches backends.
    public func shutdown() {
        loopTask?.cancel()
        loopTask = nil
        continuation?.finish()
        continuation = nil
    }

    public func refreshNow() async {
        guard let api else {
            restartLoop()
            return
        }
        // After switching homes, devices of a home never polled would flash as off; wait for their values.
        if !devices.isEmpty, hasValuesForScope() {
            emitSnapshot(closesAwayGap: false)
        }
        do {
            try await discover(api)
            try await poll(api, dids: nil)
            reportConnected()
        } catch {
            report(error)
        }
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = Task { await self.runLoop() }
    }

    private func runLoop() async {
        guard let session = account?.session ?? sessionLoader() else {
            api = nil
            continuation?.yield(.statusChanged(.disconnected(MiCloudError.notLoggedIn.localizedDescription)))
            return
        }
        self.session = session
        // The declaration is already stored, so a relaunch only reports it; no cloud call, no event.
        if session.expiryState(at: Date()) == .expired {
            api = nil
            continuation?.yield(.statusChanged(.disconnected(MiCloudError.sessionExpired.localizedDescription)))
            return
        }
        let api = apiFactory(session)
        self.api = api
        var backoff: Double = 2

        while !Task.isCancelled {
            continuation?.yield(.statusChanged(.connecting))
            lastReportedConnected = false
            do {
                try await discover(api)
                // Connected means a poll just succeeded. Marking it earlier shows the previous
                // snapshot as live while the cloud is still catching up.
                try await poll(api, dids: nil)
                reportConnected()
                backoff = 2
                var polls = 1
                while !Task.isCancelled {
                    try await waitForNextPoll()
                    try await poll(api, dids: nil)
                    reportConnected()
                    polls += 1
                    if polls % deviceRefreshEveryPolls == 0 {
                        try await refreshDeviceList(api)
                    }
                }
            } catch is CancellationError {
                return
            } catch MiCloudError.sessionExpired {
                self.api = nil
                if account != nil {
                    // An expired account must not keep showing stale devices in the merged panel.
                    devices = []
                    rooms = []
                    values = [:]
                    emitSnapshot()
                }
                report(MiCloudError.sessionExpired)
                return
            } catch {
                if Task.isCancelled { return }
                report(error)
                // Xiaomi throttles busy clients; back off for minutes instead of seconds (#26).
                let throttled = (error as? MiCloudError) == .http(429)
                if throttled { backoff = max(backoff, 60) }
                try? await Task.sleep(for: .seconds(backoff))
                await waitWhilePaused()
                backoff = min(backoff * 2, throttled ? 900 : 60)
            }
        }
    }

    // MARK: Polling Rhythm (#26)

    /// Called by the app when the panel opens or closes, the Mac sleeps or wakes, the screen locks, or
    /// Low Power Mode changes. Opening the panel or waking up polls right away if the data is older
    /// than the new interval.
    /// Declared `async` so it wins over the protocol's no-op default in async callers.
    public func setPollingContext(_ context: PollingContext) async {
        guard context != pollingContext else { return }
        logger.info("Mi cloud polling: \(context.description, privacy: .public) (\(self.pollsSinceContextChange, privacy: .public) polls since last change)")
        if context.systemActive && !pollingContext.systemActive { pollRequested = true }
        pollingContext = context
        pollsSinceContextChange = 0
        waitTask?.cancel()
    }

    private var currentInterval: Duration? {
        PollingPolicy.interval(for: pollingContext, panelOpen: pollInterval, panelClosed: closedPollInterval)
    }

    /// Sleeps until the next poll is due. A context change wakes it to re-check, so the panel
    /// opening after a minute polls at once, and closing it stretches the wait.
    private func waitForNextPoll() async throws {
        while true {
            try Task.checkCancellation()
            guard let interval = currentInterval else {
                await sleepUntilWoken(for: nil)
                continue
            }
            if pollRequested { return }
            let remaining = (lastFullPollAt ?? .now).advanced(by: interval) - ContinuousClock.now
            guard remaining > .zero else { return }
            await sleepUntilWoken(for: remaining)
        }
    }

    private func waitWhilePaused() async {
        while !Task.isCancelled, currentInterval == nil {
            await sleepUntilWoken(for: nil)
        }
    }

    /// Sleeps for `duration` (an hour when nil), returning early on `setPollingContext` or cancellation.
    private func sleepUntilWoken(for duration: Duration?) async {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: duration ?? .seconds(3600)) }
        waitTask = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        waitTask = nil
    }

    private func report(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logger.error("Mi cloud error: \(message, privacy: .public)")
        lastReportedConnected = false
        if (error as? MiCloudError) == .sessionExpired, let session, !didReportSessionExpired {
            didReportSessionExpired = true
            continuation?.yield(.sessionExpired(session))
        }
        continuation?.yield(.statusChanged(.disconnected(message)))
    }

    /// Clears a disconnect reported by a failed poll after the cloud answers again.
    private func reportConnected() {
        guard !lastReportedConnected else { return }
        lastReportedConnected = true
        continuation?.yield(.statusChanged(.connected))
    }

    // MARK: Discovery & Polling

    private func discover(_ api: any MiCloudAPI) async throws {
        // Rooms first: they name the shared-home devices the unfiltered device list leaves out (#134).
        do {
            rooms = try await api.homeRooms()
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            logger.notice("Room list unavailable, devices go to 全屋: \(error.localizedDescription, privacy: .public)")
        }
        logger.info("Mi cloud rooms: \(self.rooms.count, privacy: .public), homes: \(Self.homeOptions(from: self.rooms).count, privacy: .public)")
        try await refreshDeviceList(api, retryUnresolved: true)
    }

    /// Room dids the by-did lookup returned nothing for (IR remotes, removed devices); the periodic
    /// refresh skips them so it does not spend a request on them every time.
    private var unresolvedRoomDids: Set<String> = []

    private func refreshDeviceList(_ api: any MiCloudAPI, retryUnresolved: Bool = false) async throws {
        var list = try await api.deviceList()
        let listed = Set(list.map(\.did))
        var missingSet = Set(rooms.flatMap(\.dids)).subtracting(listed)
        if retryUnresolved { unresolvedRoomDids = [] }
        missingSet.subtract(unresolvedRoomDids)
        let missing = missingSet.sorted()
        if !missing.isEmpty {
            do {
                let extra = try await api.devices(dids: missing).filter { !listed.contains($0.did) }
                list += extra
                unresolvedRoomDids.formUnion(missingSet.subtracting(extra.map(\.did)))
                logger.info("Mi cloud shared-home devices: \(extra.count, privacy: .public) of \(missing.count, privacy: .public) room dids not in the device list")
            } catch MiCloudError.sessionExpired {
                throw MiCloudError.sessionExpired
            } catch {
                logger.error("Shared-home device lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        devices = list
        try await refreshGroupMembers(api)
        await loadMissingSpecs()

        var unsupported: Set<String> = []
        var supported = 0
        for d in devices {
            if let spec = specsByModel[d.model], MiotSynthesizer.supportedServiceName(for: spec) != nil {
                supported += 1
            } else {
                unsupported.insert(d.model)
            }
        }
        let online = devices.filter(\.isOnline).count
        logger.info("Mi cloud devices: \(self.devices.count, privacy: .public) total, \(online, privacy: .public) online, \(supported, privacy: .public) supported")
        if !unsupported.isEmpty {
            logger.notice("Unsupported models (skipped): \(unsupported.sorted().joined(separator: ", "), privacy: .public)")
        }
    }

    /// Fetches light-group membership for the listed `group.*` cards so the panel can fold their
    /// member lights into one card (#189). A failed lookup clears the cache: showing a member
    /// twice beats hiding a light whose group query went stale.
    private func refreshGroupMembers(_ api: any MiCloudAPI) async throws {
        var seen: Set<String> = []
        let groupDids = devices.map(\.did).filter { $0.hasPrefix("group.") && seen.insert($0).inserted }
        guard !groupDids.isEmpty else {
            groupMembersByGroup = [:]
            return
        }
        do {
            groupMembersByGroup = try await api.lightGroupMembers(groupDids: groupDids)
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            groupMembersByGroup = [:]
            logger.error("Light-group member lookup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Member did → owning group did for cards in `devices`, in device-list order. Members or groups
    /// outside this home are omitted, so switching homes cannot hide a light through a stale group.
    static func deviceGroupOwners(
        membersByGroup: [String: [String]],
        devices: [MiDeviceRecord]
    ) -> [String: String] {
        let listed = Set(devices.map(\.did))
        var owners: [String: String] = [:]
        for device in devices {
            guard device.did.hasPrefix("group."), let memberDids = membersByGroup[device.did] else { continue }
            for did in memberDids where listed.contains(did) && owners[did] == nil {
                owners[did] = device.did
            }
        }
        return owners
    }

    private struct SpecLoadOutcome: Sendable {
        let model: String
        let spec: MiotDeviceSpec?
        let errorDescription: String?
    }

    private func loadMissingSpecs() async {
        var pending: [String: String?] = [:]
        for d in devices where specsByModel[d.model] == nil {
            pending[d.model] = d.specType
        }
        guard !pending.isEmpty else { return }
        let source = specSource
        let loaded = await withTaskGroup(of: SpecLoadOutcome.self) { group in
            for (model, specType) in pending {
                group.addTask {
                    do {
                        let spec = try await source.spec(model: model, specType: specType)
                        return SpecLoadOutcome(model: model, spec: spec, errorDescription: nil)
                    } catch {
                        return SpecLoadOutcome(model: model, spec: nil, errorDescription: error.localizedDescription)
                    }
                }
            }
            var out: [SpecLoadOutcome] = []
            for await r in group { out.append(r) }
            return out
        }
        for outcome in loaded {
            if let spec = outcome.spec {
                specsByModel[outcome.model] = spec
            } else if let error = outcome.errorDescription {
                logger.error("Spec load failed for \(outcome.model, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Reads the selected home's devices only (all homes when none is selected) (#26).
    private func poll(_ api: any MiCloudAPI, dids: Set<String>?) async throws {
        let keys = propKeys(of: scopedDevicesAndRooms().devices, dids: dids)
        if !keys.isEmpty {
            let fresh = try await api.getProps(keys)
            // getProps omits items with a non-zero code. A missing door-state must not keep the
            // previous locked/unlocked claim while the device list still says online (#149).
            let requestedLocks = doorStateKeys(requested: keys)
            Self.applyPropRead(&values, fresh: fresh, requestedLockKeys: requestedLocks)
        }
        if dids == nil {
            lastFullPollAt = .now
            pollRequested = false
            pollsSinceContextChange += 1
        }
        emitSnapshot()
    }

    /// Successful reads replace cached values. A requested `door-state` that this round did not
    /// return is removed, so a per-item failure cannot keep rendering the previous security claim.
    static func applyPropRead(
        _ values: inout [MiotPropKey: JSONValue],
        fresh: [MiotPropKey: JSONValue],
        requestedLockKeys: [MiotPropKey]
    ) {
        values.merge(fresh) { _, new in new }
        for key in requestedLockKeys where fresh[key] == nil {
            values.removeValue(forKey: key)
        }
    }

    private func doorStateKeys(requested: [MiotPropKey]) -> [MiotPropKey] {
        let requestedSet = Set(requested)
        var keys: [MiotPropKey] = []
        for device in devices {
            guard let spec = specsByModel[device.model] else { continue }
            for key in MiotSynthesizer.doorStateKeys(for: device, spec: spec) where requestedSet.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    private func propKeys(of scoped: [MiDeviceRecord], dids: Set<String>?) -> [MiotPropKey] {
        var keys: [MiotPropKey] = []
        for d in scoped where d.isOnline && (dids?.contains(d.miotDid) ?? true) {
            guard let spec = specsByModel[d.model] else { continue }
            keys.append(contentsOf: MiotSynthesizer.requiredProps(for: d, spec: spec))
        }
        return keys
    }

    private func hasValuesForScope() -> Bool {
        propKeys(of: scopedDevicesAndRooms().devices, dids: nil).allSatisfy { values[$0] != nil }
    }

    /// The selected home's rooms and devices, plus parents of included split keys so their spec and
    /// values stay available. Everything when no (known) home is selected.
    private func scopedDevicesAndRooms() -> (devices: [MiDeviceRecord], rooms: [MiRoom]) {
        guard let selected = selectedHomeLoader() else {
            return (devices, rooms)
        }
        if selected == Self.otherAccountHomeSentinel {
            return ([], [])
        }
        guard Self.homeOptions(from: rooms).contains(where: { $0.id == selected }) else {
            return (devices, rooms)
        }
        let visibleRooms = rooms.filter { $0.homeId == selected }
        let dids = Set(visibleRooms.flatMap(\.dids))
        var visibleDevices = devices.filter { dids.contains($0.did) || ($0.splitParentDid.map(dids.contains) ?? false) }
        let parents = Set(visibleDevices.compactMap(\.splitParentDid))
        let includedIds = Set(visibleDevices.map(\.did))
        visibleDevices += devices.filter { parents.contains($0.did) && !includedIds.contains($0.did) }
        return (visibleDevices, visibleRooms)
    }

    /// UserDefaults key for the selected Mi Home id; absent or unknown means every home.
    public static let selectedHomeKey = "mi_selected_home_id"
    /// Returned to child providers when the user picked a home that belongs to another signed-in account.
    static let otherAccountHomeSentinel = "__other_account_home__"
    /// MIoT per-item code for "property not supported by this device".
    static let propertyUnsupportedCode = -704002000

    private func emitSnapshot(closesAwayGap: Bool = true) {
        let (visibleDevices, visibleRooms) = scopedDevicesAndRooms()
        var home = MiotSynthesizer.synthesize(devices: visibleDevices, rooms: visibleRooms, specs: specsByModel, values: values)
        home.closesAwayGap = closesAwayGap
        home.homes = Self.homeOptions(from: rooms)
        home.lightGroupOwners = Self.deviceGroupOwners(membersByGroup: groupMembersByGroup, devices: visibleDevices)
        // Light groups advertise `mode` but their members reject it; hide scenes there too.
        for i in home.devices.indices {
            guard case .light(var spec) = home.devices[i].kind,
                  home.devices[i].id.hasPrefix("group.") || effectsUnsupported.contains(home.devices[i].id) else { continue }
            spec.availableEffects = []
            home.devices[i].kind = .light(spec)
        }
        continuation?.yield(.snapshotUpdated(stamp(home)))
    }

    /// Namespaces room/home ids and tags devices with the account, so several accounts can be merged
    /// into one panel without id collisions. Device ids stay raw: MIoT calls address the did.
    private func stamp(_ home: SynthesizedHome) -> SynthesizedHome {
        guard let account else { return home }
        let prefix = "\(account.id)/"
        var stamped = home
        for i in stamped.rooms.indices {
            let room = stamped.rooms[i]
            stamped.rooms[i] = RoomArea(id: prefix + room.id, name: room.name, sortOrder: room.sortOrder)
        }
        for i in stamped.devices.indices {
            stamped.devices[i].roomId = prefix + stamped.devices[i].roomId
            stamped.devices[i].accountId = account.id
            stamped.devices[i].accountLabel = account.maskedUserId
        }
        for i in stamped.homes.indices {
            stamped.homes[i].id = prefix + stamped.homes[i].id
            stamped.homes[i].accountId = account.id
            stamped.homes[i].accountLabel = account.maskedUserId
        }
        return stamped
    }

    static func homeOptions(from rooms: [MiRoom]) -> [HomeOption] {
        var order: [String] = []
        var names: [String: String] = [:]
        var didsByHome: [String: Set<String>] = [:]
        for room in rooms where !room.homeId.isEmpty {
            if names[room.homeId] == nil { order.append(room.homeId); names[room.homeId] = room.homeName }
            didsByHome[room.homeId, default: []].formUnion(room.dids)
        }
        return order.map { HomeOption(id: $0, name: names[$0] ?? "", deviceCount: didsByHome[$0]?.count ?? 0) }
    }

    // MARK: Commands

    public func execute(_ command: DeviceCommand) async throws {
        let entityId = command.targetEntityId
        guard let (did, _) = MiotAddress.parse(entityId) else { throw MiotCommandError.invalidAddress(entityId) }
        guard let api else { throw MiCloudError.notLoggedIn }
        guard let record = devices.first(where: { $0.did == did }) ?? devices.first(where: { $0.miotDid == did }),
              let spec = specsByModel[record.model] else {
            throw MiotCommandError.unsupported("设备规格未加载")
        }
        let write = try MiotCommandMapper.map(command, spec: spec)
        do {
            switch write {
            case .setProps(let writes): try await api.setProps(writes)
            case .action(let call): try await api.action(call)
            }
        } catch MiCloudError.sessionExpired {
            report(MiCloudError.sessionExpired)
            throw MiCloudError.sessionExpired
        } catch MiCloudError.api(let code, let message) {
            if case .setLightEffect = command, code == Self.propertyUnsupportedCode {
                effectsUnsupported.insert(record.did)
                emitSnapshot()
            }
            throw MiCloudError.api(code: code, message: message)
        }

        let delay = followUpDelay
        // Split cards address `100.s2`; property reads are keyed by the parent `100`.
        let followUpDid = record.miotDid
        Task {
            try? await Task.sleep(for: delay)
            await self.followUpPoll(did: followUpDid)
        }
    }

    public func readBack(deviceId: String) async -> ControlReadBack {
        guard let api else { return .failed }
        // Split wall-switch cards report `100.s2` while property reads are keyed by `100`.
        let did = devices.first { $0.did == deviceId }?.miotDid ?? deviceId
        do {
            // Only a full poll may clear home-wide staleness; this read refreshes one device.
            try await poll(api, dids: [did])
            return .published
        } catch {
            report(error)
            return .failed
        }
    }

    private func followUpPoll(did: String) async {
        guard let api else { return }
        try? await poll(api, dids: [did])
    }

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        guard let api else { return [] }
        let record = devices.first { $0.did == deviceId } ?? devices.first { $0.miotDid == deviceId }
        let did = record?.miotDid ?? deviceId
        let keys: (temperature: String?, humidity: String?)
        if let record, let spec = specsByModel[record.model] {
            keys = MiotSynthesizer.sensorPropertyKeys(for: record, spec: spec)
        } else {
            keys = (nil, nil)
        }
        do {
            return try await api.sensorHistory(
                did: did,
                temperatureKey: keys.temperature,
                humidityKey: keys.humidity,
                window: window,
                now: now
            )
        } catch MiCloudError.sessionExpired {
            report(MiCloudError.sessionExpired)
            return []
        } catch {
            logger.notice("Sensor history fetch failed for \(did, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: Camera Live Stream Resolution

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: .hd)
    }

    public func resolveCameraStream(for device: SmartDevice, quality: XiaomiCameraStreamQuality) async throws -> CameraStreamSource {
        guard case .camera(let cameraSpec) = device.kind else {
            throw MiotCommandError.unsupported("camera")
        }
        try Task.checkCancellation()
        var failureReason: String?
        if let api,
           let record = devices.first(where: { $0.did == device.id }) ?? devices.first(where: { $0.miotDid == device.id }),
           let spec = specsByModel[record.model] {
            let did = record.miotDid
            if let pending = pendingCameraReleases[did] {
                await pending.value
                if pendingCameraReleases[did] == pending {
                    pendingCameraReleases.removeValue(forKey: did)
                }
            }
            try Task.checkCancellation()
            let streamService: MiotService? = {
                if let streamId = cameraSpec.streamEntityId,
                   let (_, siid) = MiotAddress.parse(streamId),
                   let svc = spec.service(iid: siid),
                   svc.action(named: "start-hls-stream") != nil {
                    return svc
                }
                return spec.services(named: "camera-stream-for-google-home").first { $0.action(named: "start-hls-stream") != nil }
            }()
            if let svc = streamService,
               let act = svc.action(named: "start-hls-stream") {
                if let result = try? await api.callAction(MiotActionCall(did: did, siid: svc.iid, aiid: act.iid, inputs: [])),
                   let url = Self.extractStreamURL(from: result) {
                    try Task.checkCancellation()
                    return .hls(url)
                }
                try Task.checkCancellation()
                if let result = try? await api.callAction(MiotActionCall(did: did, siid: svc.iid, aiid: act.iid, inputs: [.number(1)])),
                   let url = Self.extractStreamURL(from: result) {
                    try Task.checkCancellation()
                    return .hls(url)
                }
            }
            try Task.checkCancellation()

            var startedP2PSession = false
            let abortIfCancelled = { () async throws in
                if Task.isCancelled {
                    if startedP2PSession {
                        await self.stopCameraStream(for: device)
                    }
                    throw CancellationError()
                }
            }

            // Private CS2/TUTK P2P camera stream (e.g. chuangmi.camera.061a01, isa.camera.*)
            if let p2pService = spec.services.first(where: { $0.action(named: "start-p2p-stream") != nil }) {
                if let stopAct = p2pService.action(named: "stop-stream") {
                    if (try? await api.callAction(MiotActionCall(did: did, siid: p2pService.iid, aiid: stopAct.iid, inputs: []))) != nil {
                        try? await Task.sleep(for: cameraSessionReleaseDelay)
                    }
                }
                try Task.checkCancellation()
                if let startAct = p2pService.action(named: "start-p2p-stream") {
                    if (try? await api.callAction(MiotActionCall(did: did, siid: p2pService.iid, aiid: startAct.iid, inputs: []))) != nil {
                        startedP2PSession = true
                    }
                }
            }
            try await abortIfCancelled()

            let resolvedIP: String = await {
                let cached = record.localIp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !cached.isEmpty { return cached }
                let fetched = try? await api.cameraLocalIP(did: did)
                return fetched?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }()
            try await abortIfCancelled()

            if !resolvedIP.isEmpty {
                let kp = XiaomiCameraBridge.makeX25519KeyPair()
                if let vendor = try? await api.cameraP2PVendor(did: did, appPublicKey: kp.publicKeyHex),
                   !vendor.devicePublicKey.isEmpty,
                   !vendor.sign.isEmpty {
                    try await abortIfCancelled()
                    let endpoints: XiaomiCameraStreamEndpoints?
                    do {
                        endpoints = try await cameraBridge.startBridge(
                            did: did,
                            model: record.model,
                            localIP: resolvedIP,
                            clientPublic: kp.publicKeyHex,
                            clientPrivate: kp.privateKeyHex,
                            devicePublic: vendor.devicePublicKey,
                            sign: vendor.sign,
                            vendor: vendor.vendorName,
                            uid: vendor.p2pId,
                            quality: quality
                        )
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            await stopCameraStream(for: device)
                            throw CancellationError()
                        }
                        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        failureReason = detail
                        logger.error("Xiaomi camera P2P bridge failed for \(did, privacy: .public): \(detail, privacy: .public)")
                        endpoints = nil
                    }
                    if let endpoints {
                        if Task.isCancelled {
                            await stopCameraStream(for: device)
                            throw CancellationError()
                        }
                        return .liveMP4(endpoints.mp4, mjpegFallback: endpoints.mjpeg)
                    }
                } else {
                    failureReason = L10n.tr(
                        "该摄像机型号（\(record.model)）未返回受支持的局域网 P2P 加密协商参数，暂无法直连解码；可通过 Home Assistant 接入或点击右上角 🔗 填写流地址",
                        "Camera model (\(record.model)) did not return supported LAN P2P parameters; connect via Home Assistant or click 🔗 to set a custom stream URL"
                    )
                }
            } else {
                failureReason = L10n.tr(
                    "未能获取摄像机（\(record.model)）的局域网 IP 地址，请确认电脑与摄像机连接在同一路由器/局域网下后重试",
                    "Could not obtain LAN IP for camera (\(record.model)). Ensure your Mac and camera are on the same local network and retry"
                )
            }
            if startedP2PSession {
                await stopCameraStream(for: device)
            }
            try await abortIfCancelled()
        }

        try Task.checkCancellation()
        if let localURL = await probeLocalGo2RTC(for: device) {
            try Task.checkCancellation()
            return .hls(localURL)
        }

        throw HomeProviderError.serviceCallFailed(
            501,
            failureReason ?? L10n.tr(
                "米家云直连摄像头采用私有 P2P 加密流；可在下方填写本地 go2rtc / HLS 流地址，或接入 Home Assistant 观看实时画面",
                "Xiaomi Cloud cameras use private P2P streaming; enter a local go2rtc / HLS URL below or connect via Home Assistant"
            )
        )
    }

    public func stopCameraStream(for device: SmartDevice) async {
        let record = devices.first(where: { $0.did == device.id }) ?? devices.first(where: { $0.miotDid == device.id })
        let did = record?.miotDid ?? device.id
        let bridge = cameraBridge
        let apiClient = api
        let releaseDelay = cameraSessionReleaseDelay
        let stopCall: MiotActionCall? = {
            guard let record,
                  let spec = specsByModel[record.model],
                  let p2pService = spec.services.first(where: { $0.action(named: "stop-stream") != nil }),
                  let stopAct = p2pService.action(named: "stop-stream") else {
                return nil
            }
            return MiotActionCall(did: did, siid: p2pService.iid, aiid: stopAct.iid, inputs: [])
        }()
        let previousRelease = pendingCameraReleases[did]
        let releaseTask = Task<Void, Never> {
            await previousRelease?.value
            await bridge.stopBridge(did: did)
            if let apiClient, let stopCall {
                _ = try? await apiClient.callAction(stopCall)
                try? await Task.sleep(for: releaseDelay)
            }
        }
        pendingCameraReleases[did] = releaseTask
        await releaseTask.value
        if pendingCameraReleases[did] == releaseTask {
            pendingCameraReleases.removeValue(forKey: did)
        }
    }

    public static func extractStreamURL(from value: JSONValue) -> URL? {
        switch value {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"),
               let url = URL(string: trimmed) {
                return url
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = extractStreamURL(from: item) { return found }
            }
            return nil
        case .object(let dict):
            if let out = dict["out"], let found = extractStreamURL(from: out) { return found }
            if let addr = dict["stream_address"], let found = extractStreamURL(from: addr) { return found }
            if let val = dict["value"], let found = extractStreamURL(from: val) { return found }
            for v in dict.values {
                if let found = extractStreamURL(from: v) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private func probeLocalGo2RTC(for device: SmartDevice) async -> URL? {
        await cameraBridge.probeRegisteredStream(candidates: [device.id, device.name, device.model])
    }
}
