import Foundation
import Testing
@testable import MijiaCore

/// Replays sanitised recordings of the external payloads the app parses (#186).
///
/// Each fixture keeps the value types and envelope shape of the live response, with
/// identifiers, names and addresses replaced. When Xiaomi or Home Assistant changes a
/// field the app depends on, these assertions fail before a user reports a bug.
struct ContractReplayTests {
    private static func fixture(_ relativePath: String) throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Linux copies test sources into scripts/linux-check/.work; fixtures stay at the repo root.
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Tests/Fixtures/contracts/\(relativePath)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func decode(_ relativePath: String) throws -> JSONValue {
        let data = try fixture(relativePath)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let root) = value,
              case .object(let meta)? = root["_fixture"],
              meta["sanitised"]?.stringValue?.isEmpty == false else {
            throw ContractReplayError.missingFixtureMetadata(relativePath)
        }
        return value
    }

    private enum ContractReplayError: Error {
        case missingFixtureMetadata(String)
    }

    // MARK: - Mi cloud

    @Test("Device list page keeps the fields synthesis reads")
    func deviceListPage() throws {
        let result = try MiCloudClient.unwrapResult(Self.decode("mi_device_list_page.json"))
        let records = MiCloudClient.parseDeviceList(result)

        // The record without a model is skipped instead of surfacing an unusable card.
        #expect(records == [
            MiDeviceRecord(
                did: "did-light-0001",
                name: "Contract Ceiling Light",
                model: "yeelink.light.ceiling22",
                isOnline: true,
                specType: "urn:miot-spec-v2:device:light:0000A001:yeelink-ceiling22:2",
                localIp: "192.0.2.10",
                mac: "02:00:00:00:00:01"
            ),
            MiDeviceRecord(
                did: "did-switch-0002.s2",
                name: "Contract Downlight",
                model: "lemesh.switch.sw2f12",
                isOnline: false,
                splitParentDid: "did-switch-0002",
                splitSiid: 2
            ),
            MiDeviceRecord(
                did: "did-camera-0003",
                name: "Contract Camera",
                model: "chuangmi.camera.81ac1",
                isOnline: true,
                localIp: "192.0.2.11",
                mac: "02:00:00:00:00:03"
            ),
        ])
        let split = try #require(records.first { $0.splitParentDid != nil })
        #expect(split.miotDid == "did-switch-0002")
        #expect(result["next_start_did"]?.stringValue == "")
        #expect(result["has_more"]?.boolValue == false)
    }

    @Test("Shared homes and their rooms survive the merge response")
    func sharedHomesAndRooms() throws {
        let result = try MiCloudClient.unwrapResult(Self.decode("mi_home_rooms_merged.json"))
        let rooms = MiCloudClient.parseRooms(result)

        #expect(rooms == [
            MiRoom(id: "room-2001", name: "Living Room", dids: ["did-light-0001"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "room-2002", name: "Study", dids: ["did-camera-0003"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "home_home-1001", name: "", dids: ["did-light-0001", "did-switch-0002"], homeId: "home-1001", homeName: "Contract Home"),
            MiRoom(id: "room-2003", name: "Kitchen", dids: [], homeId: "home-1002", homeName: "Contract Beach House"),
            MiRoom(id: "room-2004", name: "Guest Room", dids: ["did-switch-0002.s2"], homeId: "home-1003", homeName: "Contract Shared Home", isSharedHome: true),
        ])
        // The same home id in share_home_list is an attachment, not a second home.
        #expect(!rooms.contains { $0.id == "room-9999" })
        #expect(MiCloudProvider.homeOptions(from: rooms) == [
            HomeOption(id: "home-1001", name: "Contract Home", deviceCount: 3),
            HomeOption(id: "home-1002", name: "Contract Beach House", deviceCount: 0),
            HomeOption(id: "home-1003", name: "Contract Shared Home", deviceCount: 1),
        ])
    }

    @Test("Light-group status keeps the member dids and tolerates both membership spellings")
    func lightGroupStatus() throws {
        let result = try MiCloudClient.unwrapResult(Self.decode("mi_group_query_status.json"))
        let members = MiCloudClient.parseLightGroupMembers(result)

        #expect(Set(members.keys) == ["group.1000001", "group.1000002"])
        #expect(members["group.1000001"]?.sorted() == ["did-light-0001", "did-light-0002"])
        #expect(members["group.1000002"] == ["did-light-0003"])
    }

    @Test("Property results keep values and drop per-property failures")
    func propertyValues() throws {
        let result = try MiCloudClient.unwrapResult(Self.decode("mi_props_get.json"))
        let values = MiCloudClient.parsePropValues(result)

        #expect(values == [
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 1): .bool(true),
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 2): .number(80),
            MiotPropKey(did: "did-light-0001", siid: 2, piid: 3): .number(4000),
            MiotPropKey(did: "did-camera-0003", siid: 2, piid: 1): .string("off"),
        ])
    }

    @Test("Numeric ids outside Int64 range are skipped instead of trapping")
    func hostileNumericIDs() {
        let result: JSONValue = .object(["list": .array([
            .object(["did": .number(1e308), "model": .string("contract.ghost")]),
            .object(["did": .number(42), "model": .string("contract.numeric")]),
            .object(["did": .string("did-light-0001"), "model": .string("contract.light")]),
        ])])
        #expect(MiCloudClient.parseDeviceList(result).map(\.did) == ["42", "did-light-0001"])
    }

    // MARK: - MIoT spec

    @Test("MIoT instance JSON keeps services, properties, ranges, value lists and action inputs")
    func miotSpec() throws {
        let data = try Self.fixture("miot_spec_light.json")
        let spec = try JSONDecoder().decode(MiotDeviceSpec.self, from: data)

        #expect(spec.shortName == "light")
        #expect(spec.description == "Light")
        let service = try #require(spec.service(iid: 2))
        #expect(service.shortName == "light")

        let on = try #require(service.property(named: "on"))
        #expect(on.format == "bool")
        #expect(on.isReadable && on.isWritable)
        #expect(on.rangeMin == nil && on.valueList == nil)

        let brightness = try #require(service.property(named: "brightness"))
        #expect(brightness.isIntegerFormat)
        #expect(brightness.unit == "percentage")
        #expect(brightness.rangeMin == 1)
        #expect(brightness.rangeMax == 100)
        #expect(brightness.rangeStep == 1)

        let colorTemperature = try #require(service.property(named: "color-temperature"))
        #expect(colorTemperature.rangeMin == 2700)
        #expect(colorTemperature.rangeMax == 6500)

        let mode = try #require(service.property(named: "mode"))
        #expect(mode.valueList?.map(\.value) == [0, 1])
        #expect(mode.description(forValue: 1) == "Sleep")
        #expect(mode.description(forValue: 42) == nil)

        #expect(service.action(named: "toggle")?.inputProperties == [])
        #expect(service.action(named: "set-brightness")?.inputProperties == [2])
    }

    @Test("MIoT instance index keeps the highest released version per model")
    func miotInstanceIndex() throws {
        let index = MiotSpecStore.parseInstanceIndex(try Self.fixture("miot_instance_index.json"))
        #expect(index == [
            "contract.light.ceiling": "urn:miot-spec-v2:device:light:0000A001:contract-light:3",
            "contract.plug.v1": "urn:miot-spec-v2:device:outlet:0000A002:contract-plug:2",
        ])
    }

    // MARK: - Home Assistant WebSocket

    @Test("HA WebSocket message sequence yields stable device fields")
    func homeAssistantMessages() throws {
        let document = try Self.decode("ha_websocket_messages.json")
        guard case .object(let root) = document,
              case .array(let messages)? = root["messages"] else {
            Issue.record("fixture is missing its messages array")
            return
        }

        var snapshot = HAHomeSnapshot()
        var homes: [SynthesizedHome] = []
        for message in messages {
            guard case .object(let object) = message else {
                Issue.record("fixture message is not an object")
                continue
            }
            if let home = try snapshot.receive(object) {
                homes.append(home)
            }
        }

        // Initial registries, the state_changed event, and the 1001 refresh each publish once.
        #expect(homes.count == 3)
        let initial = try #require(homes.first)
        #expect(initial.devices.map(\.id).sorted() == ["dev-light-01", "dev-thermo-02"])

        let light = try #require(initial.devices.first { $0.id == "dev-light-01" })
        #expect(light.name == "Contract Ceiling Light")
        #expect(light.roomName == "Living Room")
        guard case .light(let lightSpec) = light.kind else {
            Issue.record("expected a light")
            return
        }
        #expect(lightSpec.entityId == "light.ceiling")
        #expect(lightSpec.isOn)
        #expect(lightSpec.brightnessPercent == 50)
        #expect(lightSpec.availableEffects == ["Reading"])

        let thermometer = try #require(initial.devices.first { $0.id == "dev-thermo-02" })
        #expect(thermometer.roomName == "Study")
        guard case .sensor(let sensorSpec) = thermometer.kind else {
            Issue.record("expected a sensor")
            return
        }
        #expect(sensorSpec.temperature == 23.5)
        #expect(sensorSpec.humidity == 45)
        #expect(sensorSpec.battery == 87)

        // Hidden entities never synthesize a card.
        #expect(!initial.devices.contains { $0.id == "dev-hidden-03" })

        let afterEvent = try #require(homes.dropFirst().first)
        let lightAfterEvent = try #require(afterEvent.devices.first { $0.id == "dev-light-01" })
        guard case .light(let offSpec) = lightAfterEvent.kind else {
            Issue.record("expected a light after state_changed")
            return
        }
        #expect(!offSpec.isOn)

        let refreshed = try #require(homes.last)
        let lightRefreshed = try #require(refreshed.devices.first { $0.id == "dev-light-01" })
        guard case .light(let refreshedSpec) = lightRefreshed.kind else {
            Issue.record("expected a light after refresh")
            return
        }
        #expect(refreshedSpec.isOn)
        #expect(refreshedSpec.brightnessPercent == 100)
    }
}
