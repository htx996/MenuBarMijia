import Foundation

/// A merged card's live control route: the backend that currently drives it plus the
/// source-native device the backend knows. `sourceDeviceID` is what history and camera calls need.
public struct DeviceMergeRoute: Equatable, Sendable {
    public let backend: HomeBackend
    public let sourceDeviceID: String
    public let sourceDevice: SmartDevice

    public init(backend: HomeBackend, sourceDeviceID: String, sourceDevice: SmartDevice) {
        self.backend = backend
        self.sourceDeviceID = sourceDeviceID
        self.sourceDevice = sourceDevice
    }
}

public struct DeviceMergeResult: Equatable, Sendable {
    public var home: SynthesizedHome
    public var routes: [String: DeviceMergeRoute]
    public var canonical: CanonicalDeviceRegistry
    public var rooms: RoomIdentityRegistry

    public init(
        home: SynthesizedHome,
        routes: [String: DeviceMergeRoute],
        canonical: CanonicalDeviceRegistry,
        rooms: RoomIdentityRegistry
    ) {
        self.home = home
        self.routes = routes
        self.canonical = canonical
        self.rooms = rooms
    }
}

/// Whole-card merge of the two macOS sources (ADR-0008): one card per physical device, one
/// winning source per card, and canonical ids that keep the user's prefs across source handoffs.
public enum DeviceDeduplicator {
    public static func merge(
        homeAssistant: SynthesizedHome?,
        xiaomiCloud: SynthesizedHome?,
        canonical: CanonicalDeviceRegistry = CanonicalDeviceRegistry(),
        rooms: RoomIdentityRegistry = RoomIdentityRegistry(),
        knownPreferenceIDs: Set<String> = [],
        pinnedBackends: [String: HomeBackend] = [:]
    ) -> DeviceMergeResult {
        let haCandidates = candidates(in: homeAssistant, backend: .homeAssistant)
        let miCandidates = candidates(in: xiaomiCloud, backend: .xiaomiCloud)
        let haFallbackCounts = fallbackKeyCounts(in: haCandidates)
        let miFallbackCounts = fallbackKeyCounts(in: miCandidates)

        var pairing = PairingState()

        pairByHardwareKeys(
            haCandidates: haCandidates,
            miCandidates: miCandidates,
            pairing: &pairing
        )
        pairByFallbackGroups(
            haCandidates: haCandidates,
            miCandidates: miCandidates,
            pairing: &pairing,
            key: modelFallbackKey
        )
        pairByFallbackGroups(
            haCandidates: haCandidates,
            miCandidates: miCandidates,
            pairing: &pairing,
            key: nameFallbackKey
        )

        var draftCards: [DraftCard] = []
        for (haIndex, ha) in haCandidates.enumerated() {
            if let miIndex = pairing.miIndexForHA[haIndex] {
                let mi = miCandidates[miIndex]
                let winner = preferredCandidate(homeAssistant: ha, xiaomiCloud: mi)
                let other = winner.backend == .homeAssistant ? mi : ha
                let strongKeys = pairStrongCanonicalKeys(homeAssistant: ha, xiaomiCloud: mi)
                let fallbackKeys = uniqueFallbackKeys(
                    for: ha.identity,
                    haCounts: haFallbackCounts,
                    miCounts: miFallbackCounts
                ) + uniqueFallbackKeys(
                    for: mi.identity,
                    haCounts: haFallbackCounts,
                    miCounts: miFallbackCounts
                )
                draftCards.append(
                    DraftCard(
                        winner: winner,
                        other: other,
                        strongKeys: strongKeys,
                        fallbackKeys: deduplicatedPreservingOrder(fallbackKeys),
                        defaultPairedCanonical: preferredCanonicalID(
                            homeAssistant: ha.device.id,
                            xiaomiCloud: mi.device.id,
                            knownPreferenceIDs: knownPreferenceIDs
                        )
                    )
                )
            } else {
                draftCards.append(
                    DraftCard(
                        winner: ha,
                        other: nil,
                        strongKeys: deviceStrongCanonicalKeys(for: ha),
                        fallbackKeys: uniqueFallbackKeys(
                            for: ha.identity,
                            haCounts: haFallbackCounts,
                            miCounts: miFallbackCounts
                        ),
                        defaultPairedCanonical: nil
                    )
                )
            }
        }
        for (miIndex, mi) in miCandidates.enumerated() where !pairing.pairedMi.contains(miIndex) {
            draftCards.append(
                DraftCard(
                    winner: mi,
                    other: nil,
                    strongKeys: deviceStrongCanonicalKeys(for: mi),
                    fallbackKeys: uniqueFallbackKeys(
                        for: mi.identity,
                        haCounts: haFallbackCounts,
                        miCounts: miFallbackCounts
                    ),
                    defaultPairedCanonical: nil
                )
            )
        }

        var cardFallbackCounts: [String: Int] = [:]
        var strongClaimedCanonicals: Set<String> = []
        for draft in draftCards {
            for key in draft.fallbackKeys {
                cardFallbackCounts[key, default: 0] += 1
            }
            if let strongMatch = canonical.canonicalID(forKeys: draft.strongKeys) {
                strongClaimedCanonicals.insert(strongMatch)
            }
        }

        let cards: [Card] = draftCards.map { draft in
            let validFallbackKeys = draft.fallbackKeys.filter { cardFallbackCounts[$0] == 1 }
            let strongMatch = canonical.canonicalID(forKeys: draft.strongKeys)
            let fallbackMatch = strongMatch == nil
                ? canonical.canonicalID(forKeys: validFallbackKeys).flatMap {
                    strongClaimedCanonicals.contains($0) ? nil : $0
                }
                : nil
            let chosen = strongMatch ?? fallbackMatch ?? draft.defaultPairedCanonical
            return Card(
                winner: draft.winner,
                other: draft.other,
                canonicalKeys: draft.strongKeys + validFallbackKeys,
                chosenCanonical: chosen
            )
        }

        var pairedClaims: [String: Int] = [:]
        var unpairedClaims: [String: Int] = [:]
        for card in cards {
            guard let chosen = card.chosenCanonical else { continue }
            if card.other != nil {
                pairedClaims[chosen, default: 0] += 1
            } else {
                unpairedClaims[chosen, default: 0] += 1
            }
        }

        var updatedCanonical = canonical
        var updatedRooms = rooms
        for source in [homeAssistant, xiaomiCloud] {
            for room in roomIdentities(in: source) {
                if updatedRooms.idsByName[room.key] == nil {
                    updatedRooms.idsByName[room.key] = room.id
                }
                if updatedRooms.displayNames[room.key] == nil {
                    updatedRooms.displayNames[room.key] = room.displayName
                }
            }
        }

        var mergedDevices: [SmartDevice] = []
        mergedDevices.reserveCapacity(cards.count)
        var routes: [String: DeviceMergeRoute] = [:]
        var deviceBackends: [String: HomeBackend] = [:]
        var pairedDeviceIDs: Set<String> = []
        /// Mi source did → the card id it merges into, so group ownership survives pairing with HA.
        var miCanonicalIDs: [String: String] = [:]

        for card in cards {
            var card = card
            let canonicalID: String
            let canUseCanonical: Bool
            if card.other != nil {
                canUseCanonical = card.chosenCanonical.map { pairedClaims[$0] == 1 } ?? false
            } else {
                canUseCanonical = card.chosenCanonical.map {
                    unpairedClaims[$0] == 1 && pairedClaims[$0] == nil
                } ?? false
            }
            if let chosen = card.chosenCanonical, canUseCanonical {
                updatedCanonical.assign(chosen, toKeys: card.canonicalKeys)
                canonicalID = chosen
            } else {
                canonicalID = card.winner.device.id
            }

            let wasPaired = card.other != nil
            if let pinned = pinnedBackends[canonicalID],
               let other = card.other,
               let pinnedCandidate = [card.winner, other].first(where: {
                   $0.backend == pinned && $0.device.isOnline
               }),
               pinnedCandidate.backend != card.winner.backend {
                // A pin wins only while that source can actually drive the card; offline keeps the
                // automatic online/capability fallback (#111).
                card.other = card.winner
                card.winner = pinnedCandidate
            }
            if wasPaired { pairedDeviceIDs.insert(canonicalID) }
            for candidate in [card.winner, card.other].compactMap({ $0 }) where candidate.backend == .xiaomiCloud {
                miCanonicalIDs[candidate.device.id] = canonicalID
            }

            var merged = mergedDevice(for: card)
            let roomKey = DeviceIdentityNormalizer.normalizedRoomName(merged.roomName)
            if updatedRooms.idsByName[roomKey] == nil {
                updatedRooms.idsByName[roomKey] = merged.roomId
            }
            if updatedRooms.displayNames[roomKey] == nil {
                updatedRooms.displayNames[roomKey] = DeviceSynthesizer.normalizeRoomName(merged.roomName)
            }
            if let id = updatedRooms.idsByName[roomKey],
               !hasDistinctAccountScope(id, merged.roomId) {
                merged.roomId = id
            }
            if let name = updatedRooms.displayNames[roomKey] {
                merged.roomName = name
            }

            mergedDevices.append(
                SmartDevice(
                    id: canonicalID,
                    name: merged.name,
                    roomId: merged.roomId,
                    roomName: merged.roomName,
                    model: merged.model,
                    isOnline: merged.isOnline,
                    kind: merged.kind,
                    isSharedHome: merged.isSharedHome,
                    accountId: merged.accountId,
                    accountLabel: merged.accountLabel
                )
            )
            routes[canonicalID] = DeviceMergeRoute(
                backend: card.winner.backend,
                sourceDeviceID: card.winner.device.id,
                sourceDevice: card.winner.device
            )
            deviceBackends[canonicalID] = card.winner.backend
        }

        var roomNameOrder: [String: Int] = [:]
        func registerRoom(_ rawName: String) {
            let key = DeviceIdentityNormalizer.normalizedRoomName(rawName)
            let display = updatedRooms.displayNames[key] ?? DeviceSynthesizer.normalizeRoomName(rawName)
            guard !display.isEmpty else { return }
            if roomNameOrder[display] == nil {
                roomNameOrder[display] = roomNameOrder.count
            }
        }
        for room in homeAssistant?.rooms ?? [] { registerRoom(room.name) }
        for room in xiaomiCloud?.rooms ?? [] { registerRoom(room.name) }
        for device in mergedDevices { registerRoom(device.roomName) }

        var home = DeviceSynthesizer.assembleHome(
            devices: mergedDevices,
            readings: mergedDevices.compactMap(\.environmentReading),
            scenes: homeAssistant?.scenes ?? [],
            roomNameOrder: roomNameOrder
        )
        home.homes = xiaomiCloud?.homes ?? []
        home.accountStatuses = xiaomiCloud?.accountStatuses ?? [:]
        home.closesAwayGap = (homeAssistant?.closesAwayGap ?? true) && (xiaomiCloud?.closesAwayGap ?? true)
        var activeBackends: Set<HomeBackend> = []
        if homeAssistant != nil { activeBackends.insert(.homeAssistant) }
        if xiaomiCloud != nil { activeBackends.insert(.xiaomiCloud) }
        home.activeBackends = activeBackends
        home.deviceBackends = deviceBackends
        home.pairedDeviceIDs = pairedDeviceIDs
        let mergedIDs = Set(mergedDevices.map(\.id))
        // Ownership arrives keyed by Mi source dids. A member or group paired with an HA card is
        // shown under the canonical id, so translate both endpoints before keeping the pair (#189).
        home.lightGroupOwners = (xiaomiCloud?.lightGroupOwners ?? [:]).reduce(into: [:]) { owners, entry in
            guard let memberID = miCanonicalIDs[entry.key],
                  let groupID = miCanonicalIDs[entry.value],
                  mergedIDs.contains(memberID),
                  mergedIDs.contains(groupID) else { return }
            owners[memberID] = groupID
        }

        return DeviceMergeResult(
            home: home,
            routes: routes,
            canonical: updatedCanonical,
            rooms: updatedRooms
        )
    }

    /// Counts the control and reading features a whole card would keep, so a richer side wins a tie
    /// on online state. Field-level merging is out of scope (ADR-0008), so the score stays card-level.
    public static func capabilityScore(_ device: SmartDevice) -> Int {
        switch device.kind {
        case .light(let spec):
            var score = 0
            if spec.powerWritable { score += 1 }
            if spec.brightnessWritable && spec.brightnessPercent != nil { score += 1 }
            if spec.colorWritable && spec.colorTempKelvin != nil { score += 1 }
            if !spec.availableEffects.isEmpty { score += 2 }
            return score
        case .climate(let spec):
            var score = 0
            if spec.powerWritable { score += 1 }
            if spec.temperatureWritable { score += 1 }
            if !spec.availableModes.isEmpty { score += 1 }
            if !spec.availableFanModes.isEmpty { score += 1 }
            if !spec.availableSwingModes.isEmpty { score += 1 }
            if spec.currentTemperature != nil { score += 1 }
            return score
        case .fan(let spec):
            var score = 0
            if spec.powerWritable { score += 1 }
            if spec.speedWritable && spec.percentage != nil { score += 1 }
            if !spec.availablePresetModes.isEmpty { score += 1 }
            if spec.isOscillating != nil { score += 1 }
            if spec.pm25Density != nil { score += 1 }
            if spec.airQuality != nil { score += 1 }
            if spec.temperature != nil { score += 1 }
            if spec.humidity != nil { score += 1 }
            if spec.filterLifePercent != nil { score += 1 }
            return score
        case .plug(let spec):
            var score = 0
            if spec.powerWritable { score += 1 }
            if spec.powerWatts != nil { score += 1 }
            if spec.energyKwh != nil { score += 1 }
            if spec.childLockEntityId != nil { score += 1 }
            return score
        case .vacuum(let spec):
            var score = 0
            if spec.actionsWritable { score += 2 }
            if spec.modeEntityId != nil { score += 1 }
            if !spec.availableModes.isEmpty { score += 1 }
            if spec.battery != nil { score += 1 }
            return score
        case .speaker(let spec):
            var score = 0
            if !spec.mediaEntityId.isEmpty { score += 1 }
            if spec.ttsNotifyEntityId != nil { score += 2 }
            if spec.directiveNotifyEntityId != nil { score += 2 }
            if spec.playMusicButtonId != nil { score += 1 }
            if spec.stopAlarmButtonId != nil { score += 1 }
            if spec.muteSwitchEntityId != nil { score += 1 }
            if spec.sleepModeEntityId != nil { score += 1 }
            return score
        case .tv(let spec):
            var score = 0
            if spec.turnOnButtonId != nil { score += 1 }
            if !spec.availableSources.isEmpty { score += 1 }
            return score
        case .camera(let spec):
            var score = 0
            if spec.powerWritable { score += 1 }
            if !spec.availableNightShots.isEmpty { score += 1 }
            if spec.motionDetectionEntityId != nil { score += 1 }
            if spec.streamEntityId != nil { score += 1 }
            if spec.snapshotPath != nil { score += 1 }
            return score
        case .fridge(let spec):
            var score = 0
            if spec.modeEntityId != nil { score += 1 }
            if spec.fridgeTargetEntityId != nil { score += 1 }
            if spec.freezerTargetEntityId != nil { score += 1 }
            if spec.fridgeCurrentTemp != nil || spec.freezerCurrentTemp != nil { score += 1 }
            return score
        case .sensor:
            return 0
        }
    }

    // MARK: - Candidates, Cards & Winners

    private struct Candidate {
        let backend: HomeBackend
        let device: SmartDevice
        let identity: DeviceSourceIdentity?
    }

    private struct PairingState {
        var pairedHA: Set<Int> = []
        var pairedMi: Set<Int> = []
        var miIndexForHA: [Int: Int] = [:]

        mutating func pair(ha haIndex: Int, mi miIndex: Int) {
            pairedHA.insert(haIndex)
            pairedMi.insert(miIndex)
            miIndexForHA[haIndex] = miIndex
        }
    }

    private struct DraftCard {
        let winner: Candidate
        let other: Candidate?
        let strongKeys: [String]
        let fallbackKeys: [String]
        let defaultPairedCanonical: String?
    }

    private struct Card {
        var winner: Candidate
        var other: Candidate?
        let canonicalKeys: [String]
        let chosenCanonical: String?
    }

    private static func candidates(in home: SynthesizedHome?, backend: HomeBackend) -> [Candidate] {
        guard let home else { return [] }
        return home.devices.map { device in
            Candidate(backend: backend, device: device, identity: home.deviceIdentities[device.id])
        }
    }

    private static func preferredCandidate(homeAssistant: Candidate, xiaomiCloud: Candidate) -> Candidate {
        let ha = homeAssistant.device
        let mi = xiaomiCloud.device
        if ha.isOnline != mi.isOnline { return ha.isOnline ? homeAssistant : xiaomiCloud }
        let haScore = capabilityScore(ha)
        let miScore = capabilityScore(mi)
        if haScore != miScore { return haScore > miScore ? homeAssistant : xiaomiCloud }
        return homeAssistant
    }

    private static func mergedDevice(for card: Card) -> SmartDevice {
        let winner = card.winner.device
        var roomId = winner.roomId
        var roomName = winner.roomName
        if let other = card.other?.device,
           isRoomUnassigned(roomName: roomName),
           !isRoomUnassigned(roomName: other.roomName) {
            roomId = other.roomId
            roomName = other.roomName
        }
        let name = isBlank(winner.name) ? (card.other?.device.name ?? winner.name) : winner.name
        let model = isBlank(winner.model) ? (card.other?.device.model ?? winner.model) : winner.model
        let accountId = winner.accountId ?? card.other?.device.accountId
        let accountLabel = winner.accountLabel ?? card.other?.device.accountLabel
        return SmartDevice(
            id: winner.id,
            name: name,
            roomId: roomId,
            roomName: roomName,
            model: model,
            isOnline: winner.isOnline,
            kind: winner.kind,
            isSharedHome: winner.isSharedHome,
            accountId: accountId,
            accountLabel: accountLabel
        )
    }

    /// Two Xiaomi account room IDs (`"<accountA>/<room>"` vs `"<accountB>/<room>"`) stay separate
    /// when no HA room unified them, so removing one account only removes its own room pills.
    private static func hasDistinctAccountScope(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsSlash = lhs.firstIndex(of: "/"),
              let rhsSlash = rhs.firstIndex(of: "/") else {
            return false
        }
        return lhs[..<lhsSlash] != rhs[..<rhsSlash]
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isRoomUnassigned(roomName: String) -> Bool {
        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "全屋" || name == "默认房间" || name == "未分配"
    }

    // MARK: - Pairing

    /// Pass 1 pairs by `did`, pass 2 by `macAddress`, so a shared gateway MAC never blocks a
    /// sub-device's exact `did` match from pairing first.
    private static func pairByHardwareKeys(
        haCandidates: [Candidate],
        miCandidates: [Candidate],
        pairing: inout PairingState
    ) {
        pairByHardwarePass(
            haCandidates: haCandidates,
            miCandidates: miCandidates,
            pairing: &pairing,
            predicate: sharesDID
        )
        pairByHardwarePass(
            haCandidates: haCandidates,
            miCandidates: miCandidates,
            pairing: &pairing,
            predicate: sharesMAC
        )
    }

    private static func pairByHardwarePass(
        haCandidates: [Candidate],
        miCandidates: [Candidate],
        pairing: inout PairingState,
        predicate: (DeviceSourceIdentity, DeviceSourceIdentity) -> Bool
    ) {
        for (haIndex, candidate) in haCandidates.enumerated() where !pairing.pairedHA.contains(haIndex) {
            guard let haIdentity = candidate.identity else { continue }
            let matches = miCandidates.indices.filter { miIndex in
                guard !pairing.pairedMi.contains(miIndex),
                      let miIdentity = miCandidates[miIndex].identity else { return false }
                return predicate(haIdentity, miIdentity)
            }
            guard matches.count == 1 else { continue }
            pairing.pair(ha: haIndex, mi: matches[0])
        }
    }

    private static func sharesDID(_ a: DeviceSourceIdentity, _ b: DeviceSourceIdentity) -> Bool {
        !Set(a.dids).isDisjoint(with: b.dids)
    }

    private static func sharesMAC(_ a: DeviceSourceIdentity, _ b: DeviceSourceIdentity) -> Bool {
        !Set(a.macAddresses).isDisjoint(with: b.macAddresses)
    }

    private static func pairByFallbackGroups(
        haCandidates: [Candidate],
        miCandidates: [Candidate],
        pairing: inout PairingState,
        key: (DeviceSourceIdentity) -> String?
    ) {
        struct Group {
            var homeAssistant: [Int] = []
            var xiaomiCloud: [Int] = []
        }

        var groups: [String: Group] = [:]
        for (index, candidate) in haCandidates.enumerated() where !pairing.pairedHA.contains(index) {
            guard let identity = candidate.identity, let groupKey = key(identity) else { continue }
            groups[groupKey, default: Group()].homeAssistant.append(index)
        }
        for (index, candidate) in miCandidates.enumerated() where !pairing.pairedMi.contains(index) {
            guard let identity = candidate.identity, let groupKey = key(identity) else { continue }
            groups[groupKey, default: Group()].xiaomiCloud.append(index)
        }
        for groupKey in groups.keys.sorted() {
            guard let group = groups[groupKey],
                  group.homeAssistant.count == 1,
                  group.xiaomiCloud.count == 1 else { continue }
            let haIndex = group.homeAssistant[0]
            let miIndex = group.xiaomiCloud[0]
            guard !pairing.pairedHA.contains(haIndex), !pairing.pairedMi.contains(miIndex) else { continue }
            pairing.pair(ha: haIndex, mi: miIndex)
        }
    }

    // MARK: - Canonical Keys

    private static func preferredCanonicalID(
        homeAssistant haID: String,
        xiaomiCloud miID: String,
        knownPreferenceIDs: Set<String>
    ) -> String {
        if knownPreferenceIDs.contains(miID) && !knownPreferenceIDs.contains(haID) {
            return miID
        }
        return haID
    }

    private static func pairStrongCanonicalKeys(homeAssistant: Candidate, xiaomiCloud: Candidate) -> [String] {
        var keys = [
            "pair:\(homeAssistant.device.id)|\(xiaomiCloud.device.id)",
            "ha:\(homeAssistant.device.id)",
            "mi:\(xiaomiCloud.device.id)",
        ]
        guard let haIdentity = homeAssistant.identity, let miIdentity = xiaomiCloud.identity else {
            return keys
        }
        let sharedDIDs = Set(haIdentity.dids).intersection(Set(miIdentity.dids))
        for did in sharedDIDs.sorted() {
            keys.append("did:\(did)")
        }
        let sharedMACs = Set(haIdentity.macAddresses).intersection(Set(miIdentity.macAddresses))
        for mac in sharedMACs.sorted() {
            keys.append("mac:\(mac)")
        }
        return keys
    }

    private static func deviceStrongCanonicalKeys(for candidate: Candidate) -> [String] {
        var keys: [String] = []
        switch candidate.backend {
        case .homeAssistant:
            keys.append("ha:\(candidate.device.id)")
        case .xiaomiCloud:
            keys.append("mi:\(candidate.device.id)")
        case .demo:
            break
        }
        guard let identity = candidate.identity else { return keys }
        for did in identity.dids { keys.append("did:\(did)") }
        for mac in identity.macAddresses { keys.append("mac:\(mac)") }
        return keys
    }

    private static func fallbackKeyCounts(in candidates: [Candidate]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for candidate in candidates {
            guard let identity = candidate.identity else { continue }
            if let modelKey = modelFallbackKey(identity) {
                counts[modelKey, default: 0] += 1
            }
            if let nameKey = nameFallbackKey(identity) {
                counts[nameKey, default: 0] += 1
            }
        }
        return counts
    }

    private static func uniqueFallbackKeys(
        for identity: DeviceSourceIdentity?,
        haCounts: [String: Int],
        miCounts: [String: Int]
    ) -> [String] {
        guard let identity else { return [] }
        var keys: [String] = []
        if let key = modelFallbackKey(identity),
           haCounts[key, default: 0] <= 1,
           miCounts[key, default: 0] <= 1 {
            keys.append(key)
        }
        if let key = nameFallbackKey(identity),
           haCounts[key, default: 0] <= 1,
           miCounts[key, default: 0] <= 1 {
            keys.append(key)
        }
        return keys
    }

    private static func deduplicatedPreservingOrder(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    private static func modelFallbackKey(_ identity: DeviceSourceIdentity) -> String? {
        fallbackKey(
            prefix: "fallback-model",
            value: DeviceIdentityNormalizer.normalizedToken(identity.model),
            identity: identity
        )
    }

    private static func nameFallbackKey(_ identity: DeviceSourceIdentity) -> String? {
        fallbackKey(
            prefix: "fallback-name",
            value: DeviceIdentityNormalizer.normalizedToken(identity.name),
            identity: identity
        )
    }

    private static func fallbackKey(prefix: String, value: String, identity: DeviceSourceIdentity) -> String? {
        guard !value.isEmpty else { return nil }
        let room = DeviceIdentityNormalizer.normalizedRoomName(identity.roomName)
        return "\(prefix):\(room)|\(value)|\(identity.kindTag.rawValue)"
    }

    // MARK: - Room Registry

    private static func roomIdentities(in home: SynthesizedHome?) -> [(key: String, id: String, displayName: String)] {
        guard let home else { return [] }
        var seen: Set<String> = []
        var identities: [(key: String, id: String, displayName: String)] = []
        func record(_ name: String, id: String) {
            let key = DeviceIdentityNormalizer.normalizedRoomName(name)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            identities.append((key: key, id: id, displayName: DeviceSynthesizer.normalizeRoomName(name)))
        }
        for room in home.rooms { record(room.name, id: room.id) }
        for device in home.devices { record(device.roomName, id: device.roomId) }
        return identities
    }
}
