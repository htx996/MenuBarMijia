import Foundation

// Backend connections, discovery, provider events, device naming and polling rhythm (#48).
extension HomeStore {
    // MARK: - Backend Summary

    public var serverHostSummary: String {
        let _ = effectiveLanguage
        if homeBackend == .demo {
            return L10n.tr("演示模式（虚拟设备）", "Demo Mode (Virtual Devices)")
        }
        let haHost = URL(string: serverURLString)?.host()
            ?? serverURLString
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
        let miSummary: String = if miAccounts.count > 1 {
            L10n.tr(
                "米家云端 (\(miAccounts.count) 个账号)",
                "Xiaomi Cloud (\(miAccounts.count) accounts)"
            )
        } else if let masked = miSessionMaskedUserId {
            L10n.tr("米家云端 (\(masked))", "Xiaomi Cloud (\(masked))")
        } else {
            L10n.tr("米家云端 (未登录)", "Xiaomi Cloud (Signed Out)")
        }
        if hasHASource && hasMiSource {
            return "Home Assistant (\(haHost)) + \(miSummary)"
        }
        if hasMiSource {
            return miSummary
        }
        if hasHASource {
            return haHost
        }
        if homeBackend == .xiaomiCloud {
            return miSummary
        }
        return haHost
    }

    // MARK: - LG TV & Provider Events

    func startLGWebOSIfNeeded() {
        guard homeBackend != .demo else { return }
        let client = LGWebOSClient(
            config: lgConfig,
            onDeviceUpdated: { [weak self] dev in
                Task { @MainActor [weak self] in
                    self?.applyLGDeviceUpdate(dev)
                }
            },
            onClientKeyRegistered: { [weak self] key in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lgConfig.clientKey = key
                    self.showToast(L10n.tr("已成功配对 \(self.lgConfig.name)", "Paired with \(self.lgConfig.name)"))
                }
            },
            onSecurityFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.showToast(message, isError: true)
                }
            }
        )
        self.lgWebOSClient = client
        if lgConfig.isEnabled && lgConfig.hasConfiguredHost {
            Task { await client.start() }
        }
    }

    func applyLGDeviceUpdate(_ dev: SmartDevice) {
        // Demo mode never shows the LAN TV tile (#47), and a disabled or unconfigured TV drops it too.
        guard homeBackend != .demo, lgConfig.isEnabled, lgConfig.hasConfiguredHost else {
            latestLGDevice = nil
            devices.removeAll { $0.id == dev.id }
            return
        }
        var dev = dev
        if let matchedRoom = rooms.first(where: { $0.id == dev.roomId || $0.name == dev.roomName }) {
            dev.roomId = matchedRoom.id
        }
        latestLGDevice = dev
        rawDeviceNames[dev.id] = dev.name
        let now = ContinuousClock.now
        if let lockTime = optimisticLockUntil[dev.id], now < lockTime {
            return
        }
        if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
            devices[idx] = dev
        } else {
            devices.append(dev)
            if favoriteDeviceIds.contains(dev.id) == false && favoriteOrder.count < 8 {
                favoriteDeviceIds.insert(dev.id)
                favoriteOrder.insert(dev.id, at: 0)
            }
        }
        applyDeviceAliases()
        if !rooms.contains(where: { $0.id == dev.roomId || $0.name == dev.roomName }) {
            rooms.append(RoomArea(id: dev.roomId, name: dev.roomName, sortOrder: 1))
        }
    }

    public func startListening() {
        hasReceivedInitialSnapshot = false
        connectedBackends = []
        deviceBackends = [:]
        eventTask?.cancel()
        let stream = provider.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.handleProviderEvent(event)
            }
        }
        pushPollingContext()
    }

    public func waitForInitialSnapshot(timeout: Duration = .seconds(4)) async throws {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !hasReceivedInitialSnapshot {
            guard ContinuousClock.now < deadline else {
                throw HomeProviderError.networkError(L10n.tr(
                    "家居数据尚未加载，请稍后重试",
                    "Home data has not loaded yet. Try again shortly."
                ))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Polling Rhythm (#26)

    /// The control center panel opened or closed.
    public func setPanelVisible(_ visible: Bool) {
        updatePollingContext { $0.panelVisible = visible }
    }

    /// False while the Mac or display sleeps, the screen is locked, or another user is active.
    public func setSystemActive(_ active: Bool) {
        if !active {
            awayGap.includesAway = true
            userDefaults.set(true, forKey: MacAwayGap.storageKey)
        }
        updatePollingContext { $0.systemActive = active }
    }

    func finishPresenceSnapshot() {
        guard pollingContext.systemActive, awayGap.includesAway else { return }
        awayGap.includesAway = false
        userDefaults.set(false, forKey: MacAwayGap.storageKey)
    }

    public func setLowPowerMode(_ enabled: Bool) {
        updatePollingContext { $0.lowPower = enabled }
    }

    private func updatePollingContext(_ change: (inout PollingContext) -> Void) {
        var next = pollingContext
        change(&next)
        guard next != pollingContext else { return }
        pollingContext = next
        pushPollingContext()
    }

    /// Chained so quick open/close changes reach the provider in order.
    private func pushPollingContext() {
        let previous = pollingContextSync
        let target = provider
        let context = pollingContext
        pollingContextSync = Task {
            await previous?.value
            await target.setPollingContext(context)
        }
    }

    private func handleProviderEvent(_ event: HomeProviderEvent) {
        switch event {
        case .statusChanged(let status):
            if connectionStatus != status { connectionStatus = status }
            if case .disconnected = status {
                connectedBackends = []
            } else if case .connected = status, connectedBackends.isEmpty {
                connectedBackends = homeBackend == .demo ? [.demo] : [homeBackend]
            }

        case .sourceStatusesChanged(let statuses):
            if sourceStatuses != statuses { sourceStatuses = statuses }

        case .sessionExpired(let rejected):
            if let updated = MiSessionStore.markRejected(rejected, defaults: userDefaults) {
                if let idx = miAccounts.firstIndex(where: {
                    $0.session.userId == updated.userId && $0.session.serviceToken == updated.serviceToken
                }) {
                    miAccounts[idx].session = updated
                }
                miSessionExpiresAt = miAccounts.compactMap(\.session.expiresAt).min()
            }

        case .snapshotUpdated(let snapshot):
            snapshotGeneration &+= 1
            if !hasReceivedInitialSnapshot { hasReceivedInitialSnapshot = true }
            if !snapshot.accountStatuses.isEmpty, miAccountStatuses != snapshot.accountStatuses {
                miAccountStatuses = snapshot.accountStatuses
            }
            let previousBackends = deviceBackends
            let nextConnected: Set<HomeBackend> = snapshot.activeBackends.isEmpty
                ? [homeBackend]
                : snapshot.activeBackends
            if connectedBackends != nextConnected { connectedBackends = nextConnected }
            if deviceBackends != snapshot.deviceBackends { deviceBackends = snapshot.deviceBackends }
            if pairedDeviceIDs != snapshot.pairedDeviceIDs { pairedDeviceIDs = snapshot.pairedDeviceIDs }
            if lightGroupOwners != snapshot.lightGroupOwners { lightGroupOwners = snapshot.lightGroupOwners }
            if sourceStatuses != snapshot.sourceStatuses { sourceStatuses = snapshot.sourceStatuses }
            var nextRooms = snapshot.rooms
            if var lgDev = latestLGDevice, lgConfig.isEnabled {
                if let matchedRoom = nextRooms.first(where: { $0.id == lgDev.roomId || $0.name == lgDev.roomName }) {
                    lgDev.roomId = matchedRoom.id
                    latestLGDevice = lgDev
                } else {
                    nextRooms.append(RoomArea(id: lgDev.roomId, name: lgDev.roomName, sortOrder: 1))
                }
            }
            if rooms != nextRooms { rooms = nextRooms }
            if homes != snapshot.homes { homes = snapshot.homes }
            if environmentReadings != snapshot.environmentReadings {
                environmentReadings = snapshot.environmentReadings
                maybeRefreshProactiveSuggestionsInBackground()
            }
            if pendingLegacyMenuBarTargetMigration,
               let first = snapshot.environmentReadings.first(where: { $0.temperature != nil }) {
                self.menuBarTargetId = "temp:\(first.id)"
                pendingLegacyMenuBarTargetMigration = false
            }
            if scenes != snapshot.scenes { scenes = snapshot.scenes }

            let now = ContinuousClock.now
            var merged: [SmartDevice] = []
            let existingById = Dictionary(uniqueKeysWithValues: self.devices.map { ($0.id, $0) })

            for incoming in snapshot.devices {
                rawDeviceNames[incoming.id] = incoming.name
                let backendChanged = previousBackends[incoming.id] != nil
                    && previousBackends[incoming.id] != snapshot.deviceBackends[incoming.id]
                if backendChanged {
                    optimisticLockUntil.removeValue(forKey: incoming.id)
                    optimisticLockRevision[incoming.id, default: 0] &+= 1
                    let prefix = "\(incoming.id)."
                    for key in debounceTasks.keys where key == incoming.id || key.hasPrefix(prefix) {
                        debounceTasks.removeValue(forKey: key)?.cancel()
                    }
                }
                // A primary toggle is waiting for this read-back, so the lock from an older
                // command must not hide the device's own property snapshot.
                if let lockTime = optimisticLockUntil[incoming.id], now < lockTime,
                   let local = existingById[incoming.id],
                   !waitingDeviceIds.contains(incoming.id),
                   readBackInFlightTicket[incoming.id] == nil {
                    merged.append(local)
                } else {
                    merged.append(incoming)
                }
            }
            if let lgDev = latestLGDevice, lgConfig.isEnabled,
               !merged.contains(where: { $0.id == lgDev.id }) {
                rawDeviceNames[lgDev.id] = lgDev.name
                if let lockTime = optimisticLockUntil[lgDev.id], now < lockTime,
                   let local = existingById[lgDev.id] {
                    merged.insert(local, at: 0)
                } else {
                    merged.insert(lgDev, at: 0)
                }
            }
            // Compare the displayed names so aliases do not cause two observable writes per snapshot.
            let nextDevices = devicesWithAliases(merged)
            if devices != nextDevices { devices = nextDevices }
            seedDefaultFavoritesIfNeeded()
            let sampleNow = Date()
            energyHistory.record(devices: devices, now: sampleNow)
            sensorHistory.record(devices: devices, now: sampleNow)

            if enableSafetyAlerts, let handler = onSafetyAlert {
                for alert in evaluateSafetyAlerts(now: Date()) {
                    handler(alert)
                }
            }
            if snapshot.closesAwayGap {
                finishPresenceSnapshot()
            }
            notifyMissedScheduledCommandsIfNeeded()
        }
    }

    private func seedDefaultFavoritesIfNeeded() {
        guard favoriteDeviceIds.isEmpty,
              userDefaults.object(forKey: "favorite_device_ids") == nil,
              !devices.isEmpty else {
            return
        }
        // Automatically star online controllable devices on first launch
        let initial = devices
            .filter { $0.isOnline && ($0.isPrimaryToggleable || $0.hasDetailDrawer) }
            .prefix(6)
            .map(\.id)
        if !initial.isEmpty {
            self.favoriteDeviceIds = Set(initial)
            self.favoriteOrder = initial
        }
    }

    public func originalDeviceName(for deviceId: String) -> String? {
        rawDeviceNames[deviceId] ?? devices.first(where: { $0.id == deviceId })?.name
    }

    /// Updates `sensorHistory.connectionScope` so sensors on different Home Assistant servers,
    /// Xiaomi Cloud accounts, or Demo mode never share or overwrite each other's time series.
    func syncSensorHistoryScope() {
        let scope: String
        if homeBackend == .demo {
            scope = "demo"
        } else if hasHASource {
            let normalized = HAWebSocketProvider.canonicalHistoryScopeURL(serverURLString)
            scope = "ha:\(normalized)"
        } else if hasMiSource {
            scope = miSessionScopeIdentifier ?? "mi:signed-out"
        } else {
            switch homeBackend {
            case .demo:
                scope = "demo"
            case .homeAssistant:
                let normalized = HAWebSocketProvider.canonicalHistoryScopeURL(serverURLString)
                scope = "ha:\(normalized)"
            case .xiaomiCloud:
                scope = miSessionScopeIdentifier ?? "mi:signed-out"
            }
        }
        sensorHistory.setConnectionScope(scope)
    }

    /// Triggers an on-demand provider fetch for `deviceId`'s historical readings when due.
    public func requestSensorHistory(
        for deviceId: String,
        window: SensorHistoryWindow,
        force: Bool = false,
        now: Date = Date()
    ) {
        if !force {
            guard sensorHistory.shouldFetchCloud(deviceId: deviceId, window: window, now: now) else { return }
        }
        let activeProvider = provider
        let requestScope = sensorHistory.connectionScope
        sensorHistory.setLoading(true, deviceId: deviceId, window: window)
        Task { @MainActor [weak self] in
            let samples = await activeProvider.fetchSensorHistory(deviceId: deviceId, window: window, now: now)
            guard let self else { return }
            guard self.sensorHistory.connectionScope == requestScope else { return }
            self.sensorHistory.setLoading(false, deviceId: deviceId, window: window)
            self.sensorHistory.mergeCloudSamples(deviceId: deviceId, window: window, samples: samples, now: now)
        }
    }

    public func applyDeviceAliases(_ overrides: [String: String]? = nil) {
        let nextDevices = devicesWithAliases(devices, overrides: overrides)
        if devices != nextDevices { devices = nextDevices }
    }

    private func devicesWithAliases(_ input: [SmartDevice], overrides: [String: String]? = nil) -> [SmartDevice] {
        var result = input
        let aliases: [String: String]
        if let overrides {
            aliases = overrides
            if let data = try? JSONEncoder().encode(overrides),
               let raw = String(data: data, encoding: .utf8) {
                userDefaults.set(raw, forKey: Self.deviceAliasesKey)
            }
        } else if let raw = userDefaults.string(forKey: Self.deviceAliasesKey),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) {
            aliases = decoded
        } else {
            aliases = [:]
        }
        for idx in result.indices {
            let id = result[idx].id
            let baseName = rawDeviceNames[id] ?? result[idx].name
            rawDeviceNames[id] = baseName
            if let alias = aliases[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !alias.isEmpty,
               alias != baseName {
                result[idx].name = alias
            } else {
                result[idx].name = baseName
            }
        }
        return result
    }

    // MARK: - Connection & Settings Management

    func makeHAProvider(baseURLString: String, token: String) -> HAWebSocketProvider {
        let callback: (@Sendable (HADiscoveredInstance) -> Void)?
        if isTestEnvironment {
            callback = nil
        } else {
            callback = { @Sendable [weak self] instance in
                Task { @MainActor [weak self] in
                    self?.offerHAAddress(instance)
                }
            }
        }
        return HAWebSocketProvider(
            baseURLString: baseURLString,
            token: token,
            onAddressSuggestion: callback
        )
    }

    func makeLiveProvider() -> any HomeProvider {
        let token = KeychainHelper.loadToken(defaults: userDefaults)
        let ha: (any HomeProvider)? = (hasHASource || (!hasMiSource && homeBackend == .homeAssistant))
            ? makeHAProvider(baseURLString: serverURLString, token: token)
            : nil
        let mi: (any HomeProvider)? = (hasMiSource || (!hasHASource && homeBackend == .xiaomiCloud))
            ? makeMiAccountsProvider()
            : nil
        return Self.makeComposite(homeAssistant: ha, xiaomiCloud: mi, defaults: userDefaults)
    }

    static func makeComposite(
        homeAssistant: (any HomeProvider)?,
        xiaomiCloud: (any HomeProvider)?,
        defaults: UserDefaults
    ) -> DualSourceHomeProvider {
        let box = UncheckedUserDefaults(defaults)
        let stored = defaults.dictionary(forKey: ViewPreferenceKeys.canonicalDeviceIds) as? [String: String] ?? [:]
        return DualSourceHomeProvider(
            homeAssistant: homeAssistant,
            xiaomiCloud: xiaomiCloud,
            initialCanonicalIDs: stored,
            knownPreferenceIDs: {
                DevicePreferenceIndex.referencedIDs(defaults: box.defaults)
            },
            pinnedBackends: {
                DeviceSourcePinStorage.load(defaults: box.defaults)
            },
            persistCanonicalIDs: { assignments in
                box.defaults.set(assignments, forKey: ViewPreferenceKeys.canonicalDeviceIds)
            }
        )
    }

    private func rebuildLiveProvider() {
        eventTask?.cancel()
        shutdownCurrentProvider()
        self.provider = makeLiveProvider()
        startListening()
    }

    /// Shows a found address as a question instead of switching to it (#18). An address whose instance id
    /// differs from the Home Assistant the user chose before is ignored.
    public func offerHAAddress(_ instance: HADiscoveredInstance) {
        guard homeBackend != .demo else { return }
        guard HAAddressPolicy.canOffer(
            instance,
            currentURL: serverURLString,
            rememberedUUID: userDefaults.string(forKey: HAAddressPolicy.rememberedUUIDKey),
            dismissedURLs: dismissedHAAddressURLs
        ) else { return }
        if !discoveredHAInstances.contains(where: { $0.baseURL == instance.baseURL }) {
            discoveredHAInstances.insert(instance, at: 0)
        }
        pendingHAAddressSuggestion = instance
    }

    public func acceptHAAddressSuggestion() {
        guard let instance = pendingHAAddressSuggestion else { return }
        pendingHAAddressSuggestion = nil
        applyDiscoveredHAInstance(instance, reconnectProvider: true)
    }

    public func dismissHAAddressSuggestion() {
        guard let instance = pendingHAAddressSuggestion else { return }
        pendingHAAddressSuggestion = nil
        dismissedHAAddressURLs.insert(HAWebSocketProvider.normalizeBaseURL(instance.baseURL))
    }

    /// Remembers which Home Assistant the user picked so a look-alike elsewhere is not offered later.
    private func rememberHAInstanceId(forURL url: String) {
        let normalized = HAWebSocketProvider.normalizeBaseURL(url)
        if let uuid = discoveredHAInstances.first(where: { $0.baseURL == normalized })?.uuid {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        } else {
            userDefaults.removeObject(forKey: HAAddressPolicy.rememberedUUIDKey)
        }
    }

    public func switchBackend(_ backend: HomeBackend) {
        if backend == .demo, homeBackend == .demo, provider is DemoHomeProvider { return }
        if backend != .demo, homeBackend == backend, provider is DualSourceHomeProvider { return }
        invalidateUndoContext()

        let previousBackend = homeBackend
        self.homeBackend = backend
        if backend == .demo {
            eventTask?.cancel()
            shutdownCurrentProvider()
            // Strictly offline: stop any LAN TV and update work started by the previous backend (#47).
            if let lgClient = lgWebOSClient {
                Task { await lgClient.stop() }
            }
            latestLGDevice = nil
            updateTask?.cancel()
            updateTask = nil
            activeUpdateAttemptID = nil
            if case .readyToRelaunch(let staged) = updateState {
                updater.cleanupStagedApp(staged)
            }
            updateState = .idle
            self.provider = DemoHomeProvider()
            startListening()
        } else {
            if previousBackend == .demo {
                self.hasHASource = !KeychainHelper.loadToken(defaults: userDefaults)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            rebuildLiveProvider()
            // Leaving demo mode resumes the LAN TV link that demo stopped; `start()` no-ops when the
            // config is disabled or has no host.
            if previousBackend == .demo, let lgClient = lgWebOSClient {
                Task { await lgClient.start() }
            }
        }
    }

    public func completeMiLogin(_ session: MiSession) {
        guard MiSessionStore.upsert(session, defaults: userDefaults) else {
            showToast(
                L10n.tr("无法写入钥匙串，请授权钥匙串访问后重试", "Could not save to Keychain; allow Keychain access and try again"),
                isError: true
            )
            return
        }
        invalidateUndoContext()
        // The primary (first) account drives the summary and the history scope, so signing in a
        // second account must not relabel the panel with the newcomer.
        miAccounts = MiSessionStore.loadAccounts(defaults: userDefaults)
        self.miSessionMaskedUserId = miAccounts.first?.maskedUserId
        self.miSessionExpiresAt = miAccounts.compactMap(\.session.expiresAt).min()
        self.isShowingMiReauth = false
        self.miSessionScopeIdentifier = miAccounts.first?.session.historyScopeIdentifier
        if let region = MiCloudRegion(rawValue: session.region.lowercased()) {
            self.miCloudRegion = region
        }
        self.hasHASource = !KeychainHelper.loadToken(defaults: userDefaults)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        self.homeBackend = .xiaomiCloud
        self.completeOnboarding()
        rebuildLiveProvider()
        showToast(L10n.tr("已登录米家账号 (\(session.maskedUserId))", "Signed in to Xiaomi Home (\(session.maskedUserId))"))
    }

    /// Returns false when the Keychain/vault refused to delete the stored Mi session; the in-memory
    /// account is still signed out so the UI does not keep showing it.
    @discardableResult
    public func logoutMiAccount() -> Bool {
        let cleared = MiSessionStore.clear(defaults: userDefaults, vault: credentialVault)
        miAccounts = []
        miAccountStatuses = [:]
        self.miSessionMaskedUserId = nil
        self.miSessionExpiresAt = nil
        self.isShowingMiReauth = false
        self.miSessionScopeIdentifier = nil
        self.homes = []
        self.selectedMiHomeId = nil
        userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        if homeBackend == .xiaomiCloud || provider is DualSourceHomeProvider {
            invalidateUndoContext()
            self.devices = []
            self.rooms = []
            self.environmentReadings = []
            self.scenes = []
            selectRoom(nil)
            if hasHASource { self.homeBackend = .homeAssistant }
            rebuildLiveProvider()
        }
        showToast(L10n.tr("已退出米家账号", "Signed out of Xiaomi Home"))
        return cleared
    }

    /// The single destructive entry point behind Settings → 隐私 → 退出并吊销令牌 (#143): signs out
    /// every Mi account, deletes the Home Assistant token and drops that connection, forgets saved AI
    /// keys and cloud-consent records. Local preferences, aliases and history stay untouched.
    /// Returns false and shows an error when any credential survived the deletion.
    @discardableResult
    public func signOutAndRevokeAll() -> Bool {
        invalidateUndoContext()
        var complete = true
        if !logoutMiAccount() { complete = false }
        if !disconnectHomeAssistant() { complete = false }
        if !AssistantConfig.removeAllStoredAPIKeys(defaults: userDefaults, vault: credentialVault) {
            complete = false
        }
        revokeCloudConsent()
        if complete {
            showToast(L10n.tr("已退出并吊销本地保存的令牌", "Signed out and removed saved tokens"))
        } else {
            showToast(
                L10n.tr(
                    "部分凭据未能删除，请在钥匙串授权后重试",
                    "Some credentials could not be removed. Allow Keychain access and try again."
                ),
                isError: true
            )
        }
        return complete
    }

    /// Deletes the Home Assistant long-lived token and closes the live connection, keeping the saved
    /// instance URL so the user can reconnect by entering only a new token. A remaining Mi source
    /// keeps serving the panel after the composite provider is rebuilt. Returns false when the token
    /// could not be deleted, leaving the current connection untouched.
    @discardableResult
    public func disconnectHomeAssistant() -> Bool {
        guard KeychainHelper.saveToken("", defaults: userDefaults, vault: credentialVault) else {
            return false
        }
        hasHASource = false
        pendingHAAddressSuggestion = nil
        guard homeBackend != .demo,
              (provider is DualSourceHomeProvider || provider is HAWebSocketProvider) else { return true }
        invalidateUndoContext()
        rebuildLiveProvider()
        return true
    }

    /// Removes one account and keeps the rest: its devices, readings, rooms and homes leave the panel
    /// right away instead of waiting for the next merged snapshot.
    public func logoutMiAccount(id: String) {
        guard MiSessionStore.remove(accountID: id, defaults: userDefaults) else {
            showToast(
                L10n.tr("无法更新钥匙串，请授权钥匙串访问后重试", "Could not update Keychain; allow Keychain access and try again"),
                isError: true
            )
            return
        }
        invalidateUndoContext()
        miAccounts = MiSessionStore.loadAccounts(defaults: userDefaults)
        miAccountStatuses.removeValue(forKey: id)
        self.miSessionMaskedUserId = miAccounts.first?.maskedUserId
        self.miSessionExpiresAt = miAccounts.compactMap(\.session.expiresAt).min()
        self.miSessionScopeIdentifier = miAccounts.first?.session.historyScopeIdentifier
        if selectedMiHomeId?.hasPrefix(id + "/") == true {
            selectedMiHomeId = nil
            userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        }
        if homeBackend == .xiaomiCloud || provider is DualSourceHomeProvider {
            let removedDeviceIds = Set(devices.filter { $0.accountId == id }.map(\.id))
            devices.removeAll { $0.accountId == id }
            environmentReadings.removeAll { removedDeviceIds.contains($0.id) }
            rooms.removeAll { $0.id.hasPrefix(id + "/") }
            // Its homes leave too, so the home menu cannot offer a home nobody owns any more.
            homes.removeAll { $0.accountId == id }
            // A room pill pointing at the removed account would show an empty panel.
            if let roomId = selectedRoomId, roomId.hasPrefix(id + "/") {
                selectRoom(nil)
            }
            if miAccounts.isEmpty, hasHASource {
                self.homeBackend = .homeAssistant
            }
            rebuildLiveProvider()
        }
        showToast(miAccounts.isEmpty
            ? L10n.tr("已退出米家账号", "Signed out of Xiaomi Home")
            : L10n.tr("已移除米家账号", "Removed Xiaomi account"))
    }

    private func shutdownCurrentProvider() {
        if let old = provider as? DualSourceHomeProvider {
            Task { await old.shutdown() }
        } else if let old = provider as? MiAccountsProvider {
            Task { await old.shutdown() }
        } else if let old = provider as? MiCloudProvider {
            Task { await old.shutdown() }
        } else if let old = provider as? HAWebSocketProvider {
            Task { await old.shutdown() }
        }
    }

    public func updateConnection(serverURL: String, token: String) {
        invalidateUndoContext()
        let normalized = HAWebSocketProvider.normalizeBaseURL(serverURL)
        if normalized != HAWebSocketProvider.normalizeBaseURL(serverURLString) {
            rememberHAInstanceId(forURL: normalized)
        }
        pendingHAAddressSuggestion = nil
        self.serverURLString = normalized
        KeychainHelper.saveToken(token, defaults: userDefaults)
        self.hasHASource = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.homeBackend = preferredLiveBackend
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.completeOnboarding()
        }
        rebuildLiveProvider()
        showToast(L10n.tr("已保存并重新连接 Home Assistant", "Saved and reconnecting to Home Assistant"))
    }

    /// The user chose `instance` (a tap in setup or settings, or 切换 on a suggestion).
    public func applyDiscoveredHAInstance(_ instance: HADiscoveredInstance, reconnectProvider: Bool = true) {
        if !discoveredHAInstances.contains(where: { $0.baseURL == instance.baseURL }) {
            discoveredHAInstances.insert(instance, at: 0)
        }
        if let uuid = instance.uuid {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        }
        let normalizedCurrent = HAWebSocketProvider.normalizeBaseURL(serverURLString)
        if userDefaults.string(forKey: "home_name") == nil,
           !instance.locationName.isEmpty,
           instance.locationName != "Home Assistant" {
            self.homeName = instance.locationName
        }
        guard normalizedCurrent != instance.baseURL else { return }
        invalidateUndoContext()
        self.serverURLString = instance.baseURL
        if reconnectProvider {
            if let haProvider = provider as? HAWebSocketProvider {
                let token = KeychainHelper.loadToken(defaults: userDefaults)
                Task {
                    await haProvider.updateCredentials(baseURLString: instance.baseURL, token: token)
                }
            } else if provider is DualSourceHomeProvider {
                rebuildLiveProvider()
            }
        }
    }

    @discardableResult
    public func discoverHomeAssistantOnLAN(autoApplyIfDefault: Bool = false) async -> [HADiscoveredInstance] {
        // Demo mode is strictly offline: no LAN discovery, no network probe (#47).
        guard homeBackend != .demo else { return [] }
        isDiscoveringHA = true
        defer { isDiscoveringHA = false }
        let found = await HADiscovery.discoverOnLAN(currentURLHint: serverURLString)
        self.discoveredHAInstances = found
        // A user who typed the address by hand never went through a suggestion; the moment LAN
        // discovery identifies the instance the app is connected to, pin its id so look-alikes
        // elsewhere are filtered later (#18).
        if let uuid = HAAddressPolicy.uuidToPin(
            discovered: found,
            currentURL: serverURLString,
            rememberedUUID: userDefaults.string(forKey: HAAddressPolicy.rememberedUUIDKey)
        ) {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        }
        // Only pre-fills the address during first setup. With a token already saved, the user picks the
        // address, because connecting sends the token to it (#18).
        if autoApplyIfDefault, let first = found.first {
            let normalizedCurrent = HAWebSocketProvider.normalizeBaseURL(serverURLString)
            let isDefaultURL = (normalizedCurrent == KeychainHelper.defaultNASURL)
                || (userDefaults.string(forKey: "ha_server_url") == nil)
            let hasToken = !KeychainHelper.loadToken(defaults: userDefaults).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isDefaultURL && !hasToken && first.baseURL != normalizedCurrent {
                applyDiscoveredHAInstance(first, reconnectProvider: false)
            }
        }
        return found
    }

    public func updateLGWebOSConfig(_ newConfig: LGWebOSConfig) {
        if newConfig.host != lgConfig.host || newConfig.isEnabled != lgConfig.isEnabled || newConfig.clientKey != lgConfig.clientKey {
            invalidateUndoContext()
        }
        self.lgConfig = newConfig
        if !newConfig.isEnabled || !newConfig.hasConfiguredHost {
            latestLGDevice = nil
            devices.removeAll { $0.id == LGWebOSProtocol.deviceId }
        }
        // Demo mode persists the preference but never connects to the LAN (#47).
        guard homeBackend != .demo else {
            showToast(
                newConfig.isEnabled
                    ? L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs")
                    : L10n.tr("已停用 LG 电视局域网直连", "Disabled LG TV LAN direct connection")
            )
            return
        }
        if let lgClient = lgWebOSClient {
            Task {
                await lgClient.updateConfig(newConfig)
            }
        } else {
            startLGWebOSIfNeeded()
        }
        if newConfig.isEnabled {
            showToast(
                newConfig.hasConfiguredHost
                    ? L10n.tr("已保存并重连 \(newConfig.name)", "Saved and reconnecting to \(newConfig.name)")
                    : L10n.tr("请先填写或扫描电视局域网 IP", "Please enter or scan the TV LAN IP first"),
                isError: !newConfig.hasConfiguredHost
            )
        } else {
            showToast(L10n.tr("已停用 LG 电视局域网直连", "Disabled LG TV LAN direct connection"))
        }
    }

    public func triggerLGWebOSPairing() {
        guard homeBackend != .demo else {
            showToast(L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs"), isError: true)
            return
        }
        guard lgConfig.hasConfiguredHost else {
            showToast(L10n.tr("请先填写或扫描电视局域网 IP", "Please enter or scan the TV LAN IP first"), isError: true)
            return
        }
        if lgWebOSClient == nil {
            startLGWebOSIfNeeded()
        }
        guard let lgClient = lgWebOSClient else { return }
        showToast(L10n.tr("已向电视发送配对请求，请在电视屏幕点击「接受」", "Pairing request sent; accept the prompt on your TV screen"))
        Task {
            await lgClient.triggerPairing()
        }
    }

    /// Called only after Settings confirms discarding the saved TV identity.
    public func resetLGWebOSTrustAndPair() {
        guard homeBackend != .demo else {
            showToast(L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs"), isError: true)
            return
        }
        guard lgConfig.hasConfiguredHost, let client = lgWebOSClient else { return }
        let host = lgConfig.host
        Task {
            do {
                try await client.resetTrustAndPair()
                guard lgConfig.host == host else { return }
                lgConfig.clientKey = ""
                showToast(L10n.tr("旧电视身份已清除，请在电视上确认重新配对", "Saved TV identity cleared; confirm the new pairing on your TV"))
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    public func discoverLGWebOSTVs(hostHint: String? = nil) async -> [LGWebOSDiscoveredTV] {
        // Demo mode is strictly offline: no LAN discovery (#47).
        guard homeBackend != .demo else { return [] }
        let hint = (hostHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHint = hint.isEmpty ? lgConfig.host : hint
        return await LGWebOSClient.discoverOnLAN(hostHint: effectiveHint)
    }

    /// Switches the visible Mi Home; nil shows every home's devices.
    public func selectMiHome(_ id: String?) {
        guard selectedMiHomeId != id else { return }
        invalidateUndoContext()
        if let id {
            userDefaults.set(id, forKey: MiCloudProvider.selectedHomeKey)
        } else {
            userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
        }
        selectedMiHomeId = id
        selectRoom(nil)
        refreshNow()
    }

    public func refreshNow() {
        Task {
            await provider.refreshNow()
            if homeBackend != .demo, lgConfig.isEnabled, lgConfig.hasConfiguredHost, let lgClient = lgWebOSClient {
                await lgClient.start()
            }
        }
    }
}

// MARK: - Mi Session Expiry (#181)

extension HomeStore {
    public var miSessionExpiryState: MiSessionExpiryState {
        let _ = miSessionExpiryRevision
        return MiSessionExpiryPolicy.state(expiresAt: miSessionExpiresAt, now: Date())
    }

    /// Schedules a one-shot wake at the next boundary (`expiresAt - warningLeadTime` or `expiresAt`)
    /// so `@Observable` views update when a live session crosses into `.expiringSoon` or `.expired`.
    func scheduleMiSessionExpiryTransition(now: Date = Date()) {
        miSessionExpiryTimerTask?.cancel()
        miSessionExpiryTimerTask = nil
        guard let expiresAt = miSessionExpiresAt else { return }
        let warnAt = expiresAt.addingTimeInterval(-MiSessionExpiryPolicy.warningLeadTime)
        let nextBoundary: Date? = if now < warnAt {
            warnAt
        } else if now < expiresAt {
            expiresAt
        } else {
            nil
        }
        guard let nextBoundary else { return }
        let delay = max(0.05, nextBoundary.timeIntervalSince(now) + 0.05)
        miSessionExpiryTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.miSessionExpiryRevision &+= 1
            self.scheduleMiSessionExpiryTransition()
        }
    }

    /// Any active Xiaomi Cloud source (pure or dual-source) can name a session end; HA-only and demo never show this warning.
    private var usesMiSessionLifecycle: Bool {
        homeBackend != .demo && (homeBackend == .xiaomiCloud || hasMiSource)
    }

    public var miSessionShowsExpired: Bool {
        usesMiSessionLifecycle && miSessionExpiryState == .expired
    }

    public var miSessionExpiringSoonDate: Date? {
        guard usesMiSessionLifecycle,
              case .expiringSoon(let expiresAt) = miSessionExpiryState else { return nil }
        return expiresAt
    }

    public func presentMiReauth() {
        guard usesMiSessionLifecycle,
              miSessionMaskedUserId != nil || !miAccounts.isEmpty else { return }
        if let target = miAccounts.first(where: { $0.session.expiresAt == miSessionExpiresAt }) ?? miAccounts.first {
            miCloudRegion = target.region
        }
        isShowingMiReauth = true
    }

    public func dismissMiReauth() {
        isShowingMiReauth = false
    }
}
