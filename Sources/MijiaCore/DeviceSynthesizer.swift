import Foundation

// MARK: - Raw Home Assistant Registry & State DTOs

public struct HAAreaEntry: Codable, Equatable, Sendable {
    public let area_id: String
    public let name: String

    public init(area_id: String, name: String) {
        self.area_id = area_id
        self.name = name
    }
}

public struct HADeviceEntry: Codable, Equatable, Sendable {
    public let id: String
    public let area_id: String?
    public let name: String?
    public let name_by_user: String?
    public let manufacturer: String?
    public let model: String?
    public let disabled_by: String?
    public let identifiers: [[String]]?
    public let connections: [[String]]?
    public let serial_number: String?
    public let configuration_url: String?

    public init(
        id: String,
        area_id: String? = nil,
        name: String? = nil,
        name_by_user: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        disabled_by: String? = nil,
        identifiers: [[String]]? = nil,
        connections: [[String]]? = nil,
        serial_number: String? = nil,
        configuration_url: String? = nil
    ) {
        self.id = id
        self.area_id = area_id
        self.name = name
        self.name_by_user = name_by_user
        self.manufacturer = manufacturer
        self.model = model
        self.disabled_by = disabled_by
        self.identifiers = identifiers
        self.connections = connections
        self.serial_number = serial_number
        self.configuration_url = configuration_url
    }
}

public struct HAEntityEntry: Codable, Equatable, Sendable {
    public let entity_id: String
    public let device_id: String?
    public let area_id: String?
    public let name: String?
    public let original_name: String?
    public let platform: String?
    public let entity_category: String?
    public let disabled_by: String?
    public let hidden_by: String?
    public let unique_id: String?

    public init(
        entity_id: String,
        device_id: String? = nil,
        area_id: String? = nil,
        name: String? = nil,
        original_name: String? = nil,
        platform: String? = nil,
        entity_category: String? = nil,
        disabled_by: String? = nil,
        hidden_by: String? = nil,
        unique_id: String? = nil
    ) {
        self.entity_id = entity_id
        self.device_id = device_id
        self.area_id = area_id
        self.name = name
        self.original_name = original_name
        self.platform = platform
        self.entity_category = entity_category
        self.disabled_by = disabled_by
        self.hidden_by = hidden_by
        self.unique_id = unique_id
    }
}

public struct HAEntityState: Equatable, Sendable {
    public let entityId: String
    public var state: String
    public var attributes: [String: JSONValue]
    public var lastChanged: Date?

    public init(
        entityId: String,
        state: String,
        attributes: [String: JSONValue] = [:],
        lastChanged: Date? = nil
    ) {
        self.entityId = entityId
        self.state = state
        self.attributes = attributes
        self.lastChanged = lastChanged
    }

    public var isAvailable: Bool {
        state != "unavailable" && state != "unknown"
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let d = doubleValue else { return nil }
        // JSON numbers and numeric strings can exceed Int; `Int(_:)` traps on overflow.
        return Int(exactly: d.rounded())
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var stringArrayValue: [String] {
        guard case .array(let items) = self else { return [] }
        return items.compactMap(\.stringValue)
    }
}

// MARK: - Synthesized Home Snapshot

/// A Mi Home "家庭" the account can switch between.
public struct HomeOption: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var deviceCount: Int
    /// Set when the home belongs to one of several signed-in Mi accounts.
    public var accountId: String?
    public var accountLabel: String?

    public init(id: String, name: String, deviceCount: Int, accountId: String? = nil, accountLabel: String? = nil) {
        self.id = id
        self.name = name
        self.deviceCount = deviceCount
        self.accountId = accountId
        self.accountLabel = accountLabel
    }
}

public struct SynthesizedHome: Equatable, Sendable {
    public var rooms: [RoomArea]
    public var devices: [SmartDevice]
    public var environmentReadings: [EnvironmentReading]
    public var scenes: [HomeScene]
    /// Homes on the account (empty for backends without the concept).
    public var homes: [HomeOption] = []
    /// Per-account connection status when merged across several Mi accounts.
    public var accountStatuses: [String: ConnectionStatus] = [:]
    /// A Mi Cloud refresh emits the last values before the poll returns. That snapshot must not
    /// close the away gap, because the door may have opened while polling was paused.
    public var closesAwayGap: Bool = true
    /// Pairing evidence captured before `SmartDevice` dropped the did / MAC / HA unique id.
    public var deviceIdentities: [String: DeviceSourceIdentity] = [:]
    /// Which provider currently drives each merged card; empty on single-source snapshots.
    public var deviceBackends: [String: HomeBackend] = [:]
    /// Cards that matched one physical device in both sources; only these offer a source pin.
    public var pairedDeviceIDs: Set<String> = []
    /// Member did → owning Mi light-group did (`v2/groupv2/query_status`). Empty on backends
    /// without light groups; the panel only folds members whose group card is on screen (#189).
    public var lightGroupOwners: [String: String] = [:]
    /// Sources that contributed this merged snapshot.
    public var activeBackends: Set<HomeBackend> = []
    /// Per-source connection state for the bottom dual-source summary. Empty on single-source.
    public var sourceStatuses: [HomeBackend: ConnectionStatus] = [:]

    public init(
        rooms: [RoomArea] = [],
        devices: [SmartDevice] = [],
        environmentReadings: [EnvironmentReading] = [],
        scenes: [HomeScene] = []
    ) {
        self.rooms = rooms
        self.devices = devices
        self.environmentReadings = environmentReadings
        self.scenes = scenes
    }
}

// MARK: - Deep Synthesizer Module

public enum DeviceSynthesizer {
    public static func synthesize(
        areas: [HAAreaEntry],
        devices: [HADeviceEntry],
        entities: [HAEntityEntry],
        states: [String: HAEntityState]
    ) -> SynthesizedHome {
        let areaNameById = Dictionary(uniqueKeysWithValues: areas.map { ($0.area_id, $0.name) })

        // Group active entities by device_id
        var entitiesByDevice: [String: [HAEntityEntry]] = [:]

        for entity in entities {
            guard entity.disabled_by == nil, entity.hidden_by == nil else { continue }
            if let devId = entity.device_id {
                entitiesByDevice[devId, default: []].append(entity)
            }
        }

        var smartDevices: [SmartDevice] = []
        var envReadings: [EnvironmentReading] = []
        var identities: [String: DeviceSourceIdentity] = [:]

        for dev in devices {
            guard dev.disabled_by == nil else { continue }
            guard let devEntities = entitiesByDevice[dev.id], !devEntities.isEmpty else { continue }

            let model = dev.model ?? ""
            // Skip duplicate DLNA/AppleTV discovery or pure gateway indicator devices
            if model == "hyperDLNA" || model.hasPrefix("Apple TV") || model.hasPrefix("lumi.gateway") {
                continue
            }

            let rawAreaId = dev.area_id ?? devEntities.compactMap(\.area_id).first ?? "other"
            let rawRoomName = areaNameById[rawAreaId] ?? "全屋"
            let roomName = normalizeRoomName(rawRoomName)
            let roomId = normalizedRoomId(for: roomName, fallback: rawAreaId)

            let rawDeviceName = dev.name_by_user ?? dev.name ?? "智能设备"
            let cleanName = cleanDeviceName(rawDeviceName, roomName: roomName, model: model)

            if let built = applyingSafetyObservations(
                buildSmartDevice(
                    deviceId: dev.id,
                    name: cleanName,
                    roomId: roomId,
                    roomName: roomName,
                    model: model,
                    entities: devEntities,
                    states: states
                ),
                deviceId: dev.id,
                name: cleanName,
                roomId: roomId,
                roomName: roomName,
                model: model,
                entities: devEntities,
                states: states
            ) {
                smartDevices.append(built)
                identities[built.id] = sourceIdentity(device: built, registry: dev, entities: devEntities)
            }
        }

        let registeredDeviceIds = Set(devices.map(\.id))
        let disabledDeviceIds = Set(devices.filter { $0.disabled_by != nil }.map(\.id))
        let entityById = Dictionary(uniqueKeysWithValues: entities.map { ($0.entity_id, $0) })
        for (eid, state) in states {
            guard eid.hasPrefix("light.") || eid.hasPrefix("climate.")
                    || eid.hasPrefix("fan.") || eid.hasPrefix("vacuum.")
                    || eid.hasPrefix("camera.") || eid.hasPrefix("switch.")
                    || eid.hasPrefix("media_player.") || eid.hasPrefix("sensor.")
                    || eid.hasPrefix("binary_sensor.") || eid.hasPrefix("button.") else { continue }
            let entity = entityById[eid]
            guard entity?.disabled_by == nil, entity?.hidden_by == nil else { continue }
            if let deviceId = entity?.device_id,
               registeredDeviceIds.contains(deviceId) || disabledDeviceIds.contains(deviceId) {
                continue
            }

            let areaId = entity?.area_id ?? "other"
            let roomName = normalizeRoomName(areaNameById[areaId] ?? "全屋")
            let name = entity?.name ?? state.attributes["friendly_name"]?.stringValue
                ?? entity?.original_name ?? eid
            let orphanName = cleanDeviceName(name, roomName: roomName, model: "")
            let orphanRoomId = normalizedRoomId(for: roomName, fallback: areaId)
            let orphanEntities = [entity ?? HAEntityEntry(entity_id: eid)]
            if let built = applyingSafetyObservations(
                buildSmartDevice(
                    deviceId: eid,
                    name: orphanName,
                    roomId: orphanRoomId,
                    roomName: roomName,
                    model: "",
                    entities: orphanEntities,
                    states: states
                ),
                deviceId: eid,
                name: orphanName,
                roomId: orphanRoomId,
                roomName: roomName,
                model: "",
                entities: orphanEntities,
                states: states
            ) {
                smartDevices.append(built)
                identities[built.id] = sourceIdentity(device: built, registry: nil, entities: orphanEntities)
            }
        }

        for device in smartDevices {
            if let reading = device.environmentReading {
                envReadings.append(reading)
            }
        }

        // Synthesize HA scenes and scripts
        var synthesizedScenes: [HomeScene] = []
        var seenSceneEntityIds: Set<String> = []
        let appendScene = { (eid: String, rawTitle: String) in
            let cleanTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            synthesizedScenes.append(
                HomeScene(
                    id: eid,
                    name: cleanTitle,
                    entityId: eid,
                    iconName: sceneSymbol(for: cleanTitle)
                )
            )
        }
        for entity in entities {
            let eid = entity.entity_id
            guard eid.hasPrefix("scene.") || eid.hasPrefix("script.") else { continue }
            seenSceneEntityIds.insert(eid)
            guard entity.disabled_by == nil && entity.hidden_by == nil else { continue }
            if let st = states[eid], !st.isAvailable { continue }
            let friendly = states[eid]?.attributes["friendly_name"]?.stringValue
                ?? entity.name
                ?? entity.original_name
                ?? eid
            appendScene(eid, friendly)
        }
        for (eid, st) in states where (eid.hasPrefix("scene.") || eid.hasPrefix("script.")) && !seenSceneEntityIds.contains(eid) && st.isAvailable {
            let friendly = st.attributes["friendly_name"]?.stringValue ?? eid
            appendScene(eid, friendly)
        }
        synthesizedScenes.sort { $0.name < $1.name }

        var home = assembleHome(
            devices: smartDevices,
            readings: envReadings,
            scenes: synthesizedScenes,
            roomNameOrder: roomNameOrder(from: areas.map(\.name))
        )
        home.deviceIdentities = identities
        return home
    }

    private static func sourceIdentity(
        device: SmartDevice,
        registry: HADeviceEntry?,
        entities: [HAEntityEntry]
    ) -> DeviceSourceIdentity {
        var rawDidValues: [String] = []
        var rawMacValues: [String] = []
        if let registry {
            for pair in registry.identifiers ?? [] where pair.count >= 2 {
                let domain = pair[0].lowercased()
                if domain.contains("xiaomi") || domain == "miio" || domain == "miot" {
                    rawDidValues.append(pair[1])
                } else if domain == "mac" {
                    rawMacValues.append(pair[1])
                }
            }
            for pair in registry.connections ?? [] where pair.count >= 2 && pair[0].lowercased() == "mac" {
                rawMacValues.append(pair[1])
            }
        }
        let uniqueIds = entities.compactMap(\.unique_id)
        rawDidValues.append(contentsOf: uniqueIds)
        return DeviceSourceIdentity(
            dids: DeviceIdentityNormalizer.didCandidates(from: rawDidValues),
            macAddresses: rawMacValues.compactMap { DeviceIdentityNormalizer.macAddress(from: $0) },
            uniqueIds: uniqueIds,
            model: device.model,
            name: device.name,
            roomName: device.roomName,
            kindTag: device.kind.tag
        )
    }

    /// Provider order for rooms (HA area registry, Mi Home room list) — no built-in name weights (#36).
    static func roomNameOrder(from rawNames: [String]) -> [String: Int] {
        var order: [String: Int] = [:]
        for (idx, rawName) in rawNames.enumerated() {
            let name = normalizeRoomName(rawName)
            if order[name] == nil { order[name] = idx }
        }
        return order
    }

    /// Shared tail of every backend's synthesis: derive the room list and apply the panel sort order.
    /// `roomNameOrder` comes from the provider's own room list; rooms missing from it keep their
    /// first-seen order after the provider rooms (#36).
    static func assembleHome(
        devices smartDevices: [SmartDevice],
        readings envReadings: [EnvironmentReading],
        scenes synthesizedScenes: [HomeScene],
        roomNameOrder: [String: Int] = [:]
    ) -> SynthesizedHome {
        var firstSeen: [String: Int] = [:]
        for d in smartDevices where firstSeen[d.roomName] == nil {
            firstSeen[d.roomName] = firstSeen.count
        }
        for reading in envReadings where firstSeen[reading.roomName] == nil {
            firstSeen[reading.roomName] = firstSeen.count
        }
        let fallbackBase = roomNameOrder.count + 1
        let roomOrder: (String) -> Int = { name in
            roomNameOrder[name] ?? (fallbackBase + (firstSeen[name] ?? 999))
        }

        // Build deduplicated room list from active smartDevices
        var roomDict: [String: RoomArea] = [:]
        for d in smartDevices {
            if roomDict[d.roomId] == nil {
                roomDict[d.roomId] = RoomArea(
                    id: d.roomId,
                    name: d.roomName,
                    sortOrder: roomOrder(d.roomName)
                )
            }
        }
        let sortedRooms = roomDict.values.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name < $1.name
        }

        // Sort devices: Online first -> Kind priority -> Room order -> Name
        let sortedDevices = smartDevices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
            let pa = kindPriority(a.kind)
            let pb = kindPriority(b.kind)
            if pa != pb { return pa < pb }
            let ra = roomOrder(a.roomName)
            let rb = roomOrder(b.roomName)
            if ra != rb { return ra < rb }
            return a.name < b.name
        }

        var readingPriorityById: [String: Int] = [:]
        for d in smartDevices {
            readingPriorityById[d.id] = d.kind.environmentReadingPriority
        }
        let sortedReadings = envReadings.sorted { a, b in
            let pa = readingPriorityById[a.id] ?? 0
            let pb = readingPriorityById[b.id] ?? 0
            if pa != pb { return pa < pb }
            let ra = roomOrder(a.roomName)
            let rb = roomOrder(b.roomName)
            if ra != rb { return ra < rb }
            return a.label < b.label
        }

        return SynthesizedHome(
            rooms: sortedRooms,
            devices: sortedDevices,
            environmentReadings: sortedReadings,
            scenes: synthesizedScenes
        )
    }

    private static func sceneSymbol(for name: String) -> String {
        if name.contains("观影") || name.contains("影院") || name.contains("电视") { return "tv.fill" }
        if name.contains("睡眠") || name.contains("晚安") || name.contains("夜") { return "moon.stars.fill" }
        if name.contains("离家") || name.contains("外出") { return "figure.walk.departure" }
        if name.contains("回家") || name.contains("欢迎") { return "house.fill" }
        if name.contains("阅读") || name.contains("工作") { return "book.fill" }
        return "sparkles"
    }

    // MARK: - Device Builders

    private static func applyingSafetyObservations(
        _ built: SmartDevice?,
        deviceId: String,
        name: String,
        roomId: String,
        roomName: String,
        model: String,
        entities: [HAEntityEntry],
        states: [String: HAEntityState]
    ) -> SmartDevice? {
        let observations = safetyObservations(deviceId: deviceId, entities: entities, states: states)
        if var built {
            guard case .sensor(var spec) = built.kind else { return built }
            spec.observations = observations
            built.kind = .sensor(spec)
            return built
        }
        let safetyEntities = entities.filter { safetyKind(of: $0, states: states) != nil }
        guard !safetyEntities.isEmpty else { return nil }
        // A safety sensor keeps its card while offline so its starred offline alert can fire (#199).
        let isOnline = safetyEntities.contains { states[$0.entity_id]?.isAvailable == true }
        return SmartDevice(
            id: deviceId,
            name: name,
            roomId: roomId,
            roomName: roomName,
            model: model,
            isOnline: isOnline,
            kind: .sensor(SensorSpec(observations: observations))
        )
    }

    private static func safetyObservations(
        deviceId: String,
        entities: [HAEntityEntry],
        states: [String: HAEntityState]
    ) -> [SensorObservation] {
        var observations: [SensorObservation] = []
        for entity in entities {
            guard let kind = safetyKind(of: entity, states: states),
                  let state = states[entity.entity_id] else { continue }
            let alarming: Bool
            switch state.state.lowercased() {
            case "on": alarming = true
            case "off": alarming = false
            default: continue
            }
            observations.append(SensorObservation(
                sourceId: "\(deviceId)#\(entity.entity_id)",
                kind: kind,
                alarming: alarming,
                reportedAt: state.lastChanged
            ))
        }
        return observations
    }

    private static func safetyKind(
        of entity: HAEntityEntry,
        states: [String: HAEntityState]
    ) -> SensorAlertKind? {
        guard entity.entity_id.hasPrefix("binary_sensor.") else { return nil }
        if entity.disabled_by != nil || entity.hidden_by != nil { return nil }
        switch entity.entity_category?.lowercased() {
        case "config", "diagnostic":
            return nil
        default:
            break
        }
        return safetyKind(deviceClass: states[entity.entity_id]?.attributes["device_class"]?.stringValue)
    }

    private static func safetyKind(deviceClass: String?) -> SensorAlertKind? {
        switch deviceClass?.lowercased() {
        case "moisture": .leak
        case "smoke": .smoke
        case "gas": .gas
        case "door", "window", "opening", "garage_door": .contact
        case "motion", "occupancy", "presence": .motion
        default: nil
        }
    }

    private static func buildSmartDevice(
        deviceId: String,
        name: String,
        roomId: String,
        roomName: String,
        model: String,
        entities: [HAEntityEntry],
        states: [String: HAEntityState]
    ) -> SmartDevice? {
        let eids = entities.map(\.entity_id)

        // 1. Climate (AC / Baseboard Heater)
        if let climateId = eids.first(where: { $0.hasPrefix("climate.") }),
           let st = states[climateId] {
            let spec = parseClimateSpec(entityId: climateId, state: st)
            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .climate(spec)
            )
        }

        // 2. Primary Light (excluding indicator lights)
        let primaryLights = entities.filter { ent in
            ent.entity_id.hasPrefix("light.")
                && ent.entity_category != "config"
                && !ent.entity_id.hasSuffix("_indicator_light")
        }
        if let lightEnt = primaryLights.first,
           let st = states[lightEnt.entity_id] {
            let isOn = (st.state == "on")
            let rawBri = st.attributes["brightness"]?.doubleValue
            let briPct = rawBri.flatMap { Self.roundedInt($0 / 255.0 * 100.0).map { max(1, min(100, $0)) } }
            let kelvin = st.attributes["color_temp_kelvin"]?.intValue
            let minK = st.attributes["min_color_temp_kelvin"]?.intValue ?? 2700
            let maxK = st.attributes["max_color_temp_kelvin"]?.intValue ?? 6500
            let effect = st.attributes["effect"]?.stringValue
            let effects = st.attributes["effect_list"]?.stringArrayValue ?? []

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .light(
                    LightSpec(
                        entityId: lightEnt.entity_id,
                        isOn: isOn,
                        brightnessPercent: briPct,
                        colorTempKelvin: kelvin,
                        minKelvin: minK,
                        maxKelvin: maxK,
                        currentEffect: effect,
                        availableEffects: effects
                    )
                )
            )
        }

        // 3. Fan & Air Purifier
        if let fanId = eids.first(where: { $0.hasPrefix("fan.") }),
           let st = states[fanId] {
            let isOn = (st.state == "on")
            let pct = st.attributes["percentage"]?.intValue
            let preset = st.attributes["preset_mode"]?.stringValue
            let presets = st.attributes["preset_modes"]?.stringArrayValue ?? []
            let osc = st.attributes["oscillating"]?.boolValue

            let pm25Id = eids.first {
                $0.hasPrefix("sensor.")
                    && (states[$0]?.attributes["device_class"]?.stringValue == "pm25"
                        || $0.contains("pm2_5") || $0.contains("pm25"))
            }
            let aqId = eids.first {
                $0.hasPrefix("sensor.")
                    && (states[$0]?.attributes["device_class"]?.stringValue == "aqi"
                        || $0.contains("air_quality"))
            }
            let fanTempId = eids.first {
                $0.hasPrefix("sensor.")
                    && (states[$0]?.attributes["device_class"]?.stringValue == "temperature"
                        || $0.contains("temperature"))
            }
            let fanHumId = eids.first {
                $0.hasPrefix("sensor.")
                    && (states[$0]?.attributes["device_class"]?.stringValue == "humidity"
                        || $0.contains("humidity"))
            }
            let filterId = eids.first { $0.hasPrefix("sensor.") && $0.contains("filter_life") }

            let pm25 = pm25Id.flatMap { states[$0] }.flatMap { $0.isAvailable ? Double($0.state).flatMap(Self.roundedInt) : nil }
                ?? st.attributes["pm25"]?.intValue
            let aq = aqId.flatMap { states[$0] }.flatMap { $0.isAvailable ? $0.state : nil }
                ?? st.attributes["air_quality"]?.stringValue
            let temp = fanTempId.flatMap { states[$0] }.flatMap { $0.isAvailable ? Double($0.state) : nil }
                ?? st.attributes["temperature"]?.doubleValue
            let hum = fanHumId.flatMap { states[$0] }.flatMap { $0.isAvailable ? Double($0.state) : nil }
                ?? st.attributes["humidity"]?.doubleValue
            let filterLife = filterId.flatMap { states[$0] }.flatMap { $0.isAvailable ? Double($0.state).flatMap(Self.roundedInt) : nil }
                ?? st.attributes["filter_life_remaining"]?.intValue

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .fan(
                    FanSpec(
                        entityId: fanId,
                        isOn: isOn,
                        percentage: pct,
                        presetMode: preset,
                        availablePresetModes: presets,
                        isOscillating: osc,
                        pm25Density: pm25,
                        airQuality: aq,
                        temperature: temp,
                        humidity: hum,
                        filterLifePercent: filterLife
                    )
                )
            )
        }

        // 4. Vacuum
        if let vacId = eids.first(where: { $0.hasPrefix("vacuum.") }),
           let st = states[vacId] {
            let batId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("battery_level") })
            let bat = batId.flatMap { states[$0]?.state }.flatMap { Self.roundedInt(Double($0) ?? -1) ?? -1 }
            let modeId = eids.first(where: { $0.hasPrefix("select.") && $0.contains("mode") })
            let modeState = modeId.flatMap { states[$0] }
            let currentMode = (modeState?.isAvailable == true) ? modeState?.state : nil
            let modes = modeState?.attributes["options"]?.stringArrayValue ?? []

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .vacuum(
                    VacuumSpec(
                        entityId: vacId,
                        status: st.state,
                        battery: (bat ?? -1) >= 0 ? bat : nil,
                        modeEntityId: modeId,
                        currentMode: currentMode,
                        availableModes: modes
                    )
                )
            )
        }

        // 5. Smart Refrigerator (midjd6.fridge.*)
        if model.contains("fridge") || eids.contains(where: { $0.contains("midjd6") }) {
            let modeId = eids.first(where: { $0.hasPrefix("select.") && $0.contains("mode") })
            let modeSt = modeId.flatMap { states[$0] }
            let curMode = modeSt?.state ?? "手动"
            let modes = modeSt?.attributes["options"]?.stringArrayValue ?? ["手动", "智能", "速冷", "速冻", "假日"]

            let fridgeTempId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("temperature_p_3") })
            let freezerTempId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("temperature_p_4") })
            let fridgeTargetId = eids.first(where: { $0.hasPrefix("number.") && $0.contains("target_temperature_p_3") })
            let freezerTargetId = eids.first(where: { $0.hasPrefix("number.") && $0.contains("target_temperature_p_4") })

            let fCur = fridgeTempId.flatMap { states[$0]?.state }.flatMap(Double.init)
            let zCur = freezerTempId.flatMap { states[$0]?.state }.flatMap(Double.init)
            let fTgt = fridgeTargetId.flatMap { states[$0]?.state }.flatMap(Double.init) ?? 4
            let zTgt = freezerTargetId.flatMap { states[$0]?.state }.flatMap(Double.init) ?? -18
            let online = (modeSt?.isAvailable == true) || (fCur != nil)

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: online,
                kind: .fridge(
                    FridgeSpec(
                        modeEntityId: modeId,
                        currentMode: curMode,
                        availableModes: modes,
                        fridgeCurrentTemp: fCur,
                        fridgeTargetTemp: fTgt,
                        fridgeTargetEntityId: fridgeTargetId,
                        freezerCurrentTemp: zCur,
                        freezerTargetTemp: zTgt,
                        freezerTargetEntityId: freezerTargetId
                    )
                )
            )
        }

        // 5b. Smart Camera (camera.* or camera model with control switches)
        let cameraEntityId = eids.first(where: { $0.hasPrefix("camera.") })
        let isCameraModel = model.contains("camera") || model.contains("cateye") || model.contains("doorbell")
        if cameraEntityId != nil || isCameraModel {
            let powerSwitchId = eids.first { eid in
                guard eid.hasPrefix("switch.") else { return false }
                let lower = eid.lowercased()
                return !lower.contains("motion")
                    && !lower.contains("indicator")
                    && !lower.contains("watermark")
                    && !lower.contains("wdr")
                    && !lower.contains("tracking")
                    && !lower.contains("distortion")
            }
            let camSt = cameraEntityId.flatMap { states[$0] }
            let powerSt = powerSwitchId.flatMap { states[$0] }
            if let primarySt = camSt ?? powerSt {
                let targetEntityId = powerSwitchId ?? cameraEntityId ?? deviceId
                let isOn: Bool
                if let powerSt {
                    isOn = powerSt.state == "on"
                } else if let camSt {
                    isOn = camSt.state != "off"
                } else {
                    isOn = false
                }
                let motionSw = eids.first { $0.hasPrefix("switch.") && $0.lowercased().contains("motion") }
                let motionEntityId = motionSw ?? (camSt?.attributes["motion_detection"]?.boolValue != nil && cameraEntityId != nil ? "\(cameraEntityId!)#motion" : nil)
                let isMotionOn = motionSw.flatMap { states[$0]?.state == "on" } ?? camSt?.attributes["motion_detection"]?.boolValue

                let nightSelectId = eids.first {
                    $0.hasPrefix("select.") && ($0.lowercased().contains("night") || $0.lowercased().contains("ir_mode"))
                }
                let nightSt = nightSelectId.flatMap { states[$0] }
                let nightShot = (nightSt?.isAvailable == true) ? nightSt?.state : nil
                let nightOptions = nightSt?.attributes["options"]?.stringArrayValue ?? []
                let controlEntityId = nightSelectId != nil ? "\(targetEntityId)|\(nightSelectId!)" : targetEntityId
                let snapshotPath = camSt?.attributes["entity_picture"]?.stringValue
                    ?? camSt?.attributes["access_token"]?.stringValue.flatMap { token in
                        cameraEntityId.map { "/api/camera_proxy/\($0)?token=\(token)" }
                    }

                return SmartDevice(
                    id: deviceId,
                    name: name,
                    roomId: roomId,
                    roomName: roomName,
                    model: model,
                    isOnline: primarySt.isAvailable,
                    kind: .camera(
                        CameraSpec(
                            entityId: controlEntityId,
                            isOn: isOn,
                            nightShot: nightShot,
                            availableNightShots: nightOptions,
                            motionDetectionEntityId: motionEntityId,
                            isMotionDetectionOn: isMotionOn,
                            streamEntityId: cameraEntityId,
                            snapshotPath: snapshotPath
                        )
                    )
                )
            }
        }

        let tempId = eids.first { eid in
            guard eid.hasPrefix("sensor.") else { return false }
            if let deviceClass = states[eid]?.attributes["device_class"]?.stringValue {
                return deviceClass == "temperature"
            }
            return eid.contains("temperature")
        }
        let humId = eids.first { eid in
            guard eid.hasPrefix("sensor.") else { return false }
            if let deviceClass = states[eid]?.attributes["device_class"]?.stringValue {
                return deviceClass == "humidity"
            }
            return eid.contains("humidity")
        }
        let batId = eids.first { eid in
            guard eid.hasPrefix("sensor.") else { return false }
            if let deviceClass = states[eid]?.attributes["device_class"]?.stringValue {
                return deviceClass == "battery"
            }
            return eid.contains("battery_level")
        }
        let primarySwitches = entities.filter { entity in
            guard entity.entity_id.hasPrefix("switch."),
                  entity.entity_category != "config", entity.entity_category != "diagnostic" else { return false }
            if states[entity.entity_id]?.attributes["device_class"]?.stringValue == "outlet" { return true }
            let objectId = entity.entity_id.dropFirst("switch.".count)
            return objectId.firstMatch(of: #/(?:^|_)(?:physical_controls_locked|child_lock|indicator|mute|sleep_mode)(?:_|$)/#) == nil
        }
        let outletSwitch = primarySwitches.first {
            states[$0.entity_id]?.attributes["device_class"]?.stringValue == "outlet"
        }
        // Companion switch.* entities (door relay, vendor power) must not hide lock.*.
        if Self.isLockModel(model) || eids.contains(where: { $0.hasPrefix("lock.") }) {
            let lockId = eids.first(where: { $0.hasPrefix("lock.") })
            let lockSt = lockId.flatMap { states[$0] }
            let batSt = batId.flatMap { states[$0] }
            let bVal = batSt.flatMap { Double($0.state).flatMap(Self.roundedInt) }
            let online = (lockSt?.isAvailable == true) || (batSt?.isAvailable == true)
            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: online,
                kind: .sensor(
                    SensorSpec(
                        battery: bVal,
                        statusText: Self.haLockStatusText(lockSt)
                    )
                )
            )
        }
        if model.contains("plug") || eids.contains(where: { $0.hasPrefix("switch.cuco") })
            || (!primarySwitches.isEmpty && (outletSwitch != nil || (tempId == nil && humId == nil))
                && !eids.contains(where: { $0.hasPrefix("media_player.") })) {
            guard let swId = outletSwitch?.entity_id
                    ?? primarySwitches.first(where: { $0.entity_id.contains("_on_") })?.entity_id
                    ?? primarySwitches.first?.entity_id,
                  let st = states[swId] else { return nil }

            let powerId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("electric_power") })
            let energyId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("power_consumption") })
            let lockId = eids.first(where: { $0.hasPrefix("switch.") && $0.contains("physical_controls_locked") })

            let watts = powerId.flatMap { states[$0]?.state }.flatMap(Double.init)
            let kwh = energyId.flatMap { states[$0]?.state }.flatMap(Double.init)
            let locked = lockId.flatMap { states[$0]?.state == "on" } ?? false

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .plug(
                    PlugSpec(
                        switchEntityId: swId,
                        isOn: st.state == "on",
                        powerWatts: watts,
                        energyKwh: kwh,
                        childLockEntityId: lockId,
                        isChildLocked: locked
                    )
                )
            )
        }

        // 7. Smart Speaker / TV (media_player.*)
        if let mediaId = eids.first(where: { $0.hasPrefix("media_player.") }),
           let st = states[mediaId] {
            let volDouble = st.attributes["volume_level"]?.doubleValue ?? 0.2
            let volPct = Self.roundedInt(volDouble * 100.0) ?? 20
            let devClass = st.attributes["device_class"]?.stringValue ?? ""

            if devClass == "tv" || model.contains("tv") {
                let src = st.attributes["source"]?.stringValue
                let srcs = st.attributes["source_list"]?.stringArrayValue ?? []
                let turnOnBtn = eids.first(where: { $0.hasPrefix("button.") && $0.contains("turn_on") })
                return SmartDevice(
                    id: deviceId,
                    name: name,
                    roomId: roomId,
                    roomName: roomName,
                    model: model,
                    isOnline: st.isAvailable,
                    kind: .tv(
                        TVSpec(
                            mediaEntityId: mediaId,
                            state: st.state,
                            volumePercent: volPct,
                            currentSource: src,
                            availableSources: srcs,
                            turnOnButtonId: turnOnBtn
                        )
                    )
                )
            } else {
                let muteSw = eids.first(where: { $0.hasPrefix("switch.") && $0.contains("mute") })
                let sleepSw = eids.first(where: { $0.hasPrefix("switch.") && $0.contains("sleep_mode") })
                let ttsNotify = eids.first(where: { $0.hasPrefix("notify.") && $0.contains("play_text") })
                let dirNotify = eids.first(where: { $0.hasPrefix("notify.") && $0.contains("execute_text_directive") })
                let playMusicBtn = eids.first(where: { $0.hasPrefix("button.") && $0.contains("play_music") })
                let stopAlarmBtn = eids.first(where: { $0.hasPrefix("button.") && $0.contains("stop_alarm") })

                let isMuted = muteSw.flatMap { states[$0]?.state == "on" }
                    ?? st.attributes["is_volume_muted"]?.boolValue
                    ?? false
                let isSleep = sleepSw.flatMap { states[$0]?.state == "on" } ?? false

                return SmartDevice(
                    id: deviceId,
                    name: name,
                    roomId: roomId,
                    roomName: roomName,
                    model: model,
                    isOnline: st.isAvailable,
                    kind: .speaker(
                        SpeakerSpec(
                            mediaEntityId: mediaId,
                            state: st.state,
                            volumePercent: volPct,
                            isMuted: isMuted,
                            muteSwitchEntityId: muteSw,
                            sleepModeEntityId: sleepSw,
                            isSleepMode: isSleep,
                            ttsNotifyEntityId: ttsNotify,
                            directiveNotifyEntityId: dirNotify,
                            playMusicButtonId: playMusicBtn,
                            stopAlarmButtonId: stopAlarmBtn
                        )
                    )
                )
            }
        }

        if tempId != nil || humId != nil {
            let tempSt = tempId.flatMap { states[$0] }
            let humSt = humId.flatMap { states[$0] }
            let batSt = batId.flatMap { states[$0] }

            let tVal = tempSt.flatMap { Double($0.state) }
            let hVal = humSt.flatMap { Double($0.state) }
            let bVal = batSt.flatMap { Double($0.state).flatMap(Self.roundedInt) }
            let online = (tempSt?.isAvailable == true) || (humSt?.isAvailable == true)

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: online,
                kind: .sensor(
                    SensorSpec(
                        temperature: tVal,
                        humidity: hVal,
                        battery: bVal
                    )
                )
            )
        }

        // 9. Standalone Action Button (e.g. Home Assistant Wake on LAN button.* entities, #100)
        let primaryButtons = entities.filter { entity in
            guard entity.entity_id.hasPrefix("button."), entity.entity_category == nil else { return false }
            if let devClass = states[entity.entity_id]?.attributes["device_class"]?.stringValue,
               devClass == "restart" || devClass == "update" || devClass == "identify" {
                return false
            }
            let objectId = entity.entity_id.dropFirst("button.".count)
            return objectId.firstMatch(of: #/(?:^|_)(?:reboot|restart|reset|identify|calibrate)(?:_|$)/#) == nil
        }
        if let btn = primaryButtons.first(where: { $0.entity_id.contains("wake_on_lan") }) ?? primaryButtons.first,
           let st = states[btn.entity_id] {
            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.state != "unavailable",
                kind: .plug(
                    PlugSpec(
                        switchEntityId: btn.entity_id,
                        isOn: false
                    )
                )
            )
        }

        return nil
    }

    /// `clock` and `block` contain the letters "lock" but are not door locks.
    static func isLockModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        if lower.contains(".lock.") || lower.hasPrefix("lock.") || lower.hasSuffix(".lock") {
            return true
        }
        if lower.contains("clock") || lower.contains("block") {
            return false
        }
        return lower.contains("lock")
    }

    /// Home Assistant `lock.*` states. Unavailable, unknown, and unrecognized values stay neutral.
    static func haLockStatusText(_ state: HAEntityState?) -> String {
        guard let state, state.isAvailable else {
            return L10n.tr("锁状态未知", "Lock status unknown")
        }
        switch state.state.lowercased() {
        case "locked":
            return L10n.tr("已上锁", "Locked")
        case "unlocked", "open":
            return L10n.tr("已开锁", "Unlocked")
        case "locking":
            return L10n.tr("正在上锁", "Locking")
        case "unlocking":
            return L10n.tr("正在开锁", "Unlocking")
        case "jammed":
            return L10n.tr("门锁卡住", "Jammed")
        default:
            return L10n.tr("锁状态未知", "Lock status unknown")
        }
    }

    private static func parseClimateSpec(entityId: String, state st: HAEntityState) -> ClimateSpec {
        let isOn = st.isAvailable && st.state != "off"
        let modes = st.attributes["hvac_modes"]?.stringArrayValue ?? ["cool", "heat", "dry", "fan_only", "off"]
        let target = st.attributes["temperature"]?.doubleValue
            ?? st.attributes["target_temp_low"]?.doubleValue
            ?? 26.0
        let current = st.attributes["current_temperature"]?.doubleValue
        let minT = st.attributes["min_temp"]?.doubleValue ?? 16.0
        let maxT = st.attributes["max_temp"]?.doubleValue ?? 30.0
        let step = st.attributes["target_temp_step"]?.doubleValue ?? 1.0
        let fanMode = st.attributes["fan_mode"]?.stringValue
        let fanModes = st.attributes["fan_modes"]?.stringArrayValue ?? []
        let swingMode = st.attributes["swing_mode"]?.stringValue
        let swingModes = st.attributes["swing_modes"]?.stringArrayValue ?? []

        return ClimateSpec(
            entityId: entityId,
            isOn: isOn,
            hvacMode: st.state,
            availableModes: modes,
            targetTemperature: target,
            currentTemperature: current,
            minTemp: minT,
            maxTemp: maxT,
            step: step,
            fanMode: fanMode,
            availableFanModes: fanModes,
            swingMode: swingMode,
            availableSwingModes: swingModes
        )
    }

    // MARK: - Naming & Normalization Helpers

    /// External numbers (HA attributes, sensor states) can be non-finite or exceed `Int`;
    /// converting them directly traps, so an unusable number degrades to "no reading".
    static func roundedInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    public static func normalizeRoomName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "默认房间" { return "全屋" }
        return trimmed
    }

    static func normalizedRoomId(for roomName: String, fallback: String) -> String {
        if !fallback.isEmpty && fallback != "other" && !fallback.hasPrefix("mi_room_") {
            return fallback
        }
        switch roomName {
        case "客厅": return "ke_ting"
        case "书房": return "shu_fang"
        case "卧室": return "wo_shi"
        case "主卧": return "zhu_wo"
        case "次卧": return "ci_wo"
        case "小卧室": return "xiao_wo_shi"
        case "厨房": return "chu_fang"
        case "阳台": return "yang_tai"
        default: return fallback
        }
    }

    public static func cleanDeviceName(_ raw: String, roomName: String, model: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip verbose duplicate suffixes appended by Home Assistant entity naming
        for suffix in ["  灯", "  电暖器", "  风扇", "  音箱", "  电视", "  开关 开关"] {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Prefix generic ceiling light names with their room name for clarity
        if s == "吸顶灯" && roomName != "全屋" {
            return "\(roomName)吸顶灯"
        }
        // Shorten verbose official Xiaomi product model names for compact cards
        if s.hasPrefix("米家互联网对开门冰箱") {
            return "对开门冰箱"
        }
        if s.contains("直流变频循环扇") {
            return "变频循环扇"
        }
        if s.hasPrefix("米家踢脚线电暖器") {
            return "踢脚线电暖器"
        }
        if s.hasPrefix("Yeelight LED 彩光灯带") {
            return roomName != "全屋" ? "\(roomName)彩光灯带" : "彩光灯带"
        }
        return s
    }

    private static func kindPriority(_ kind: DeviceKind) -> Int {
        kind.tag.rank
    }
}
