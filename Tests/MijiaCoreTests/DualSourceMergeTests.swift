import Foundation
import Testing
@testable import MijiaCore

private func makeHome(
    rooms: [RoomArea] = [],
    devices: [SmartDevice],
    identities: [String: DeviceSourceIdentity] = [:]
) -> SynthesizedHome {
    var home = SynthesizedHome(rooms: rooms, devices: devices)
    home.deviceIdentities = identities
    return home
}

private func makeIdentity(
    dids: [String] = [],
    macs: [String] = [],
    uniqueIds: [String] = [],
    model: String,
    name: String,
    roomName: String,
    kind: DeviceKindTag
) -> DeviceSourceIdentity {
    DeviceSourceIdentity(
        dids: dids,
        macAddresses: macs,
        uniqueIds: uniqueIds,
        model: model,
        name: name,
        roomName: roomName,
        kindTag: kind
    )
}

private func makeLight(
    id: String,
    name: String,
    roomId: String,
    roomName: String,
    model: String = "yeelight.light",
    isOnline: Bool = true
) -> SmartDevice {
    SmartDevice(
        id: id,
        name: name,
        roomId: roomId,
        roomName: roomName,
        model: model,
        isOnline: isOnline,
        kind: .light(
            LightSpec(
                entityId: "light.\(id)",
                isOn: true,
                brightnessPercent: 80,
                colorTempKelvin: 4000
            )
        )
    )
}

private func makeSpeaker(
    id: String,
    name: String,
    roomId: String,
    roomName: String,
    isOnline: Bool = true,
    tts: Bool = false,
    directive: Bool = false
) -> SmartDevice {
    SmartDevice(
        id: id,
        name: name,
        roomId: roomId,
        roomName: roomName,
        model: "xiaomi.speaker",
        isOnline: isOnline,
        kind: .speaker(
            SpeakerSpec(
                mediaEntityId: "media_player.\(id)",
                state: "idle",
                volumePercent: 30,
                ttsNotifyEntityId: tts ? "notify.\(id)_play_text" : nil,
                directiveNotifyEntityId: directive ? "notify.\(id)_execute_text_directive" : nil
            )
        )
    )
}

struct DualSourceMergeTests {
    @Test("A shared did pairs two sources into one card and routes to Home Assistant on a tie")
    func didPairingDedupesAndRoutesToHomeAssistant() throws {
        let haLight = makeLight(id: "ha-living-light", name: "客厅灯", roomId: "living_room", roomName: "客厅")
        let miLight = makeLight(
            id: "123456789",
            name: "书房灯",
            roomId: "mi_room_2",
            roomName: "书房",
            model: "xiaomi.light"
        )
        let haIdentity = makeIdentity(
            dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_123456789"]),
            uniqueIds: ["xiaomi_home_123456789"],
            model: haLight.model,
            name: haLight.name,
            roomName: haLight.roomName,
            kind: .light
        )
        let miIdentity = makeIdentity(
            dids: ["123456789"],
            model: miLight.model,
            name: miLight.name,
            roomName: miLight.roomName,
            kind: .light
        )

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [haLight], identities: [haLight.id: haIdentity]),
            xiaomiCloud: makeHome(devices: [miLight], identities: [miLight.id: miIdentity])
        )

        #expect(result.home.devices.count == 1)
        let device = try #require(result.home.devices.first)
        #expect(device.id == "ha-living-light")
        #expect(result.routes[device.id]?.backend == .homeAssistant)
        #expect(result.routes[device.id]?.sourceDeviceID == "ha-living-light")
        #expect(result.canonical.canonicalID(forKeys: ["pair:ha-living-light|123456789"]) == "ha-living-light")
    }

    @Test("Light-group ownership follows canonical ids when both endpoints pair with HA")
    func lightGroupOwnersFollowCanonicalIDs() throws {
        let haGroup = makeLight(id: "ha-living-group", name: "客厅灯组", roomId: "living_room", roomName: "客厅")
        let miGroup = makeLight(
            id: "group.123",
            name: "客厅灯组",
            roomId: "mi_room_1",
            roomName: "客厅",
            model: "xiaomi.light"
        )
        let haMember = makeLight(id: "ha-living-ceiling", name: "客厅吸顶灯", roomId: "living_room", roomName: "客厅")
        let miMember = makeLight(
            id: "456789012",
            name: "客厅吸顶灯",
            roomId: "mi_room_1",
            roomName: "客厅",
            model: "xiaomi.light"
        )
        let haGroupIdentity = makeIdentity(
            dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_group.123"]),
            model: haGroup.model,
            name: haGroup.name,
            roomName: haGroup.roomName,
            kind: .light
        )
        let miGroupIdentity = makeIdentity(
            dids: ["group.123"],
            model: miGroup.model,
            name: miGroup.name,
            roomName: miGroup.roomName,
            kind: .light
        )
        let haMemberIdentity = makeIdentity(
            dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_456789012"]),
            model: haMember.model,
            name: haMember.name,
            roomName: haMember.roomName,
            kind: .light
        )
        let miMemberIdentity = makeIdentity(
            dids: ["456789012"],
            model: miMember.model,
            name: miMember.name,
            roomName: miMember.roomName,
            kind: .light
        )

        var miHome = makeHome(
            devices: [miGroup, miMember],
            identities: [miGroup.id: miGroupIdentity, miMember.id: miMemberIdentity]
        )
        miHome.lightGroupOwners = ["456789012": "group.123"]

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(
                devices: [haGroup, haMember],
                identities: [haGroup.id: haGroupIdentity, haMember.id: haMemberIdentity]
            ),
            xiaomiCloud: miHome
        )

        #expect(result.home.devices.map(\.id).sorted() == ["ha-living-ceiling", "ha-living-group"])
        #expect(result.home.lightGroupOwners == ["ha-living-ceiling": "ha-living-group"])
    }

    @Test("A normalized MAC address pairs devices that have no did")
    func macPairingDedupesDevicesWithoutDID() throws {
        let haLight = makeLight(id: "ha-desk-light", name: "书桌灯", roomId: "study", roomName: "书房")
        let miLight = makeLight(
            id: "556677889",
            name: "台灯",
            roomId: "mi_room_3",
            roomName: "次卧",
            model: "xiaomi.light"
        )
        let haIdentity = makeIdentity(
            macs: ["AA-BB-CC-DD-EE-FF"],
            model: haLight.model,
            name: haLight.name,
            roomName: haLight.roomName,
            kind: .light
        )
        let miIdentity = makeIdentity(
            macs: ["aa:bb:cc:dd:ee:ff"],
            model: miLight.model,
            name: miLight.name,
            roomName: miLight.roomName,
            kind: .light
        )

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [haLight], identities: [haLight.id: haIdentity]),
            xiaomiCloud: makeHome(devices: [miLight], identities: [miLight.id: miIdentity])
        )

        #expect(result.home.devices.count == 1)
        let device = try #require(result.home.devices.first)
        #expect(device.id == "ha-desk-light")
        #expect(result.routes[device.id]?.backend == .homeAssistant)
    }

    @Test("A Home Assistant entity unique id derived did pairs with a bare Mi did")
    func entityUniqueIDDerivedDIDPairsWithBareDID() throws {
        let haLight = makeLight(id: "ha-entry-light", name: "玄关灯", roomId: "entryway", roomName: "玄关")
        let miLight = makeLight(
            id: "246813579",
            name: "门厅灯",
            roomId: "mi_room_4",
            roomName: "走廊",
            model: "xiaomi.light"
        )
        let rawUniqueID = "246813579_2_1"
        let haIdentity = makeIdentity(
            dids: DeviceIdentityNormalizer.didCandidates(from: [rawUniqueID]),
            uniqueIds: [rawUniqueID],
            model: haLight.model,
            name: haLight.name,
            roomName: haLight.roomName,
            kind: .light
        )
        let miIdentity = makeIdentity(
            dids: ["246813579"],
            model: miLight.model,
            name: miLight.name,
            roomName: miLight.roomName,
            kind: .light
        )

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [haLight], identities: [haLight.id: haIdentity]),
            xiaomiCloud: makeHome(devices: [miLight], identities: [miLight.id: miIdentity])
        )

        #expect(result.home.devices.count == 1)
        let device = try #require(result.home.devices.first)
        #expect(device.id == "ha-entry-light")
        #expect(result.routes[device.id]?.backend == .homeAssistant)
    }

    @Test("A unique same-room same-model same-kind device pairs through the fallback key")
    func uniqueModelFallbackPairsDevices() throws {
        let haLight = makeLight(id: "ha-ceiling", name: "主灯", roomId: "living_room", roomName: "客厅")
        let miLight = makeLight(
            id: "112233445",
            name: "客厅吸顶灯",
            roomId: "mi_room_1",
            roomName: "客厅",
            model: "yeelight.light"
        )
        let haIdentity = makeIdentity(
            model: haLight.model,
            name: haLight.name,
            roomName: haLight.roomName,
            kind: .light
        )
        let miIdentity = makeIdentity(
            model: miLight.model,
            name: miLight.name,
            roomName: miLight.roomName,
            kind: .light
        )

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [haLight], identities: [haLight.id: haIdentity]),
            xiaomiCloud: makeHome(devices: [miLight], identities: [miLight.id: miIdentity])
        )

        #expect(result.home.devices.count == 1)
        let device = try #require(result.home.devices.first)
        #expect(device.id == "ha-ceiling")
        #expect(result.routes[device.id]?.backend == .homeAssistant)
        #expect(result.rooms.idsByName["客厅"] == "living_room")
    }

    @Test("Two same-model Home Assistant devices and one Mi device stay separate instead of guessing")
    func ambiguousModelFallbackDoesNotPair() throws {
        let firstLight = makeLight(id: "ha-light-one", name: "灯一", roomId: "living_room", roomName: "客厅")
        let secondLight = makeLight(id: "ha-light-two", name: "灯二", roomId: "living_room", roomName: "客厅")
        let miLight = makeLight(
            id: "667788990",
            name: "客厅灯",
            roomId: "mi_room_1",
            roomName: "客厅",
            model: "yeelight.light"
        )
        let identities = [
            firstLight.id: makeIdentity(
                model: firstLight.model,
                name: firstLight.name,
                roomName: firstLight.roomName,
                kind: .light
            ),
            secondLight.id: makeIdentity(
                model: secondLight.model,
                name: secondLight.name,
                roomName: secondLight.roomName,
                kind: .light
            ),
            miLight.id: makeIdentity(
                model: miLight.model,
                name: miLight.name,
                roomName: miLight.roomName,
                kind: .light
            )
        ]

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [firstLight, secondLight], identities: identities),
            xiaomiCloud: makeHome(devices: [miLight], identities: identities)
        )

        #expect(result.home.devices.count == 3)
        #expect(Set(result.home.devices.map(\.id)) == Set(["ha-light-one", "ha-light-two", "667788990"]))
        #expect(result.routes.count == 3)
    }

    @Test("A unique same-room same-name device pairs when the models differ")
    func sameNameFallbackPairsDevicesWithDifferentModels() throws {
        let haLight = makeLight(
            id: "ha-floor-light",
            name: "落地灯",
            roomId: "study",
            roomName: "书房",
            model: "vendor.floor.light"
        )
        let miLight = makeLight(
            id: "998877665",
            name: "落地灯",
            roomId: "mi_room_study",
            roomName: "书房",
            model: "xiaomi.floor.light"
        )
        let haIdentity = makeIdentity(
            model: haLight.model,
            name: haLight.name,
            roomName: haLight.roomName,
            kind: .light
        )
        let miIdentity = makeIdentity(
            model: miLight.model,
            name: miLight.name,
            roomName: miLight.roomName,
            kind: .light
        )

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [haLight], identities: [haLight.id: haIdentity]),
            xiaomiCloud: makeHome(devices: [miLight], identities: [miLight.id: miIdentity])
        )

        #expect(result.home.devices.count == 1)
        let device = try #require(result.home.devices.first)
        #expect(device.id == "ha-floor-light")
        #expect(result.routes[device.id]?.backend == .homeAssistant)
    }

    @Test("An online source beats an offline source with a richer capability score")
    func onlineBeatsOfflineWithHigherScore() throws {
        let haSpeaker = makeSpeaker(
            id: "ha-speaker",
            name: "客厅音箱",
            roomId: "living_room",
            roomName: "客厅",
            isOnline: false,
            tts: true,
            directive: true
        )
        let miSpeaker = makeSpeaker(
            id: "135792468",
            name: "小爱音箱",
            roomId: "mi_room_1",
            roomName: "书房",
            isOnline: true
        )
        let haIdentity = makeIdentity(
            dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_135792468"]),
            model: haSpeaker.model,
            name: haSpeaker.name,
            roomName: haSpeaker.roomName,
            kind: .speaker
        )
        let miIdentity = makeIdentity(
            dids: ["135792468"],
            model: miSpeaker.model,
            name: miSpeaker.name,
            roomName: miSpeaker.roomName,
            kind: .speaker
        )

        #expect(DeviceDeduplicator.capabilityScore(haSpeaker) > DeviceDeduplicator.capabilityScore(miSpeaker))

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [haSpeaker], identities: [haSpeaker.id: haIdentity]),
            xiaomiCloud: makeHome(devices: [miSpeaker], identities: [miSpeaker.id: miIdentity])
        )

        #expect(result.home.devices.count == 1)
        let device = try #require(result.home.devices.first)
        #expect(device.isOnline)
        #expect(result.routes[device.id]?.backend == .xiaomiCloud)
        #expect(result.routes[device.id]?.sourceDeviceID == "135792468")
    }

    @Test("A richer capability score wins when both sources are online")
    func richerCapabilityWinsOnlineTie() throws {
        let richHomeAssistant = makeSpeaker(
            id: "ha-rich-speaker",
            name: "客厅音箱",
            roomId: "living_room",
            roomName: "客厅",
            tts: true,
            directive: true
        )
        let basicMi = makeSpeaker(
            id: "111222333",
            name: "小爱音箱",
            roomId: "mi_room_1",
            roomName: "书房"
        )
        let first = DeviceDeduplicator.merge(
            homeAssistant: makeHome(
                devices: [richHomeAssistant],
                identities: [
                    richHomeAssistant.id: makeIdentity(
                        dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_111222333"]),
                        model: richHomeAssistant.model,
                        name: richHomeAssistant.name,
                        roomName: richHomeAssistant.roomName,
                        kind: .speaker
                    )
                ]
            ),
            xiaomiCloud: makeHome(
                devices: [basicMi],
                identities: [
                    basicMi.id: makeIdentity(
                        dids: ["111222333"],
                        model: basicMi.model,
                        name: basicMi.name,
                        roomName: basicMi.roomName,
                        kind: .speaker
                    )
                ]
            )
        )
        let firstDevice = try #require(first.home.devices.first)
        #expect(first.home.devices.count == 1)
        #expect(first.routes[firstDevice.id]?.backend == .homeAssistant)

        let basicHomeAssistant = makeSpeaker(
            id: "ha-basic-speaker",
            name: "客厅音箱",
            roomId: "living_room",
            roomName: "客厅"
        )
        let richMi = makeSpeaker(
            id: "444555666",
            name: "小爱音箱",
            roomId: "mi_room_1",
            roomName: "书房",
            tts: true,
            directive: true
        )
        #expect(DeviceDeduplicator.capabilityScore(richMi) > DeviceDeduplicator.capabilityScore(basicHomeAssistant))

        let second = DeviceDeduplicator.merge(
            homeAssistant: makeHome(
                devices: [basicHomeAssistant],
                identities: [
                    basicHomeAssistant.id: makeIdentity(
                        dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_444555666"]),
                        model: basicHomeAssistant.model,
                        name: basicHomeAssistant.name,
                        roomName: basicHomeAssistant.roomName,
                        kind: .speaker
                    )
                ]
            ),
            xiaomiCloud: makeHome(
                devices: [richMi],
                identities: [
                    richMi.id: makeIdentity(
                        dids: ["444555666"],
                        model: richMi.model,
                        name: richMi.name,
                        roomName: richMi.roomName,
                        kind: .speaker
                    )
                ]
            )
        )
        let secondDevice = try #require(second.home.devices.first)
        #expect(second.home.devices.count == 1)
        #expect(second.routes[secondDevice.id]?.backend == .xiaomiCloud)
    }

    @Test("Identical candidates tie to Home Assistant")
    func identicalCandidatesTieToHomeAssistant() throws {
        let haLight = makeLight(id: "ha-tie-light", name: "客厅灯", roomId: "living_room", roomName: "客厅")
        let miLight = makeLight(
            id: "777888999",
            name: "吸顶灯",
            roomId: "mi_room_1",
            roomName: "书房",
            model: "xiaomi.light"
        )
        #expect(DeviceDeduplicator.capabilityScore(haLight) == DeviceDeduplicator.capabilityScore(miLight))

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(
                devices: [haLight],
                identities: [
                    haLight.id: makeIdentity(
                        dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_777888999"]),
                        model: haLight.model,
                        name: haLight.name,
                        roomName: haLight.roomName,
                        kind: .light
                    )
                ]
            ),
            xiaomiCloud: makeHome(
                devices: [miLight],
                identities: [
                    miLight.id: makeIdentity(
                        dids: ["777888999"],
                        model: miLight.model,
                        name: miLight.name,
                        roomName: miLight.roomName,
                        kind: .light
                    )
                ]
            )
        )

        let device = try #require(result.home.devices.first)
        #expect(result.home.devices.count == 1)
        #expect(result.routes[device.id]?.backend == .homeAssistant)
    }

    @Test("A winner without a room borrows the other source's assigned room")
    func emptyWinnerRoomBorrowsTheOtherSourceRoom() throws {
        let haSpeaker = makeSpeaker(
            id: "ha-speaker",
            name: "小爱音箱",
            roomId: "other",
            roomName: "全屋",
            tts: true,
            directive: true
        )
        let miSpeaker = makeSpeaker(
            id: "321654987",
            name: "小爱音箱",
            roomId: "mi_room_1",
            roomName: "客厅",
            isOnline: false
        )
        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(
                devices: [haSpeaker],
                identities: [
                    haSpeaker.id: makeIdentity(
                        dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_321654987"]),
                        model: haSpeaker.model,
                        name: haSpeaker.name,
                        roomName: haSpeaker.roomName,
                        kind: .speaker
                    )
                ]
            ),
            xiaomiCloud: makeHome(
                devices: [miSpeaker],
                identities: [
                    miSpeaker.id: makeIdentity(
                        dids: ["321654987"],
                        model: miSpeaker.model,
                        name: miSpeaker.name,
                        roomName: miSpeaker.roomName,
                        kind: .speaker
                    )
                ]
            )
        )

        let device = try #require(result.home.devices.first)
        #expect(result.home.devices.count == 1)
        #expect(result.routes[device.id]?.backend == .homeAssistant)
        #expect(device.roomName == "客厅")
        #expect(device.roomId == "mi_room_1")
        #expect(result.rooms.idsByName["客厅"] == "mi_room_1")
    }

    @Test("Same-named rooms from both sources unify on the Home Assistant room id")
    func sameNamedRoomsUnifyOnHomeAssistantRoomID() throws {
        let haLight = makeLight(
            id: "ha-ceiling-light",
            name: "客厅主灯",
            roomId: "living_room",
            roomName: "客厅",
            model: "vendor.ceiling.light"
        )
        let miLight = makeLight(
            id: "555666777",
            name: "落地灯",
            roomId: "mi_room_1",
            roomName: "客厅",
            model: "xiaomi.floor.light"
        )

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(
                rooms: [RoomArea(id: "living_room", name: "客厅")],
                devices: [haLight]
            ),
            xiaomiCloud: makeHome(
                rooms: [RoomArea(id: "mi_room_1", name: "客厅")],
                devices: [miLight]
            )
        )

        #expect(result.home.devices.count == 2)
        #expect(result.rooms.idsByName["客厅"] == "living_room")
        #expect(result.rooms.displayNames["客厅"] == "客厅")
        #expect(result.home.rooms.count == 1)
        #expect(result.home.devices.allSatisfy({ $0.roomId == "living_room" }))
    }

    @Test("The canonical id uses the Mi id when only Mi preferences exist")
    func canonicalIDUsesMiIDWhenOnlyMiPreferencesExist() throws {
        let haLight = makeLight(id: "ha-canonical-light", name: "客厅灯", roomId: "living_room", roomName: "客厅")
        let miLight = makeLight(
            id: "888999000",
            name: "吸顶灯",
            roomId: "mi_room_1",
            roomName: "书房",
            model: "xiaomi.light"
        )

        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(
                devices: [haLight],
                identities: [
                    haLight.id: makeIdentity(
                        dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_888999000"]),
                        model: haLight.model,
                        name: haLight.name,
                        roomName: haLight.roomName,
                        kind: .light
                    )
                ]
            ),
            xiaomiCloud: makeHome(
                devices: [miLight],
                identities: [
                    miLight.id: makeIdentity(
                        dids: ["888999000"],
                        model: miLight.model,
                        name: miLight.name,
                        roomName: miLight.roomName,
                        kind: .light
                    )
                ]
            ),
            knownPreferenceIDs: [miLight.id]
        )

        let device = try #require(result.home.devices.first)
        #expect(result.home.devices.count == 1)
        #expect(device.id == "888999000")
        #expect(result.routes["888999000"] != nil)
        #expect(result.canonical.canonicalID(forKeys: ["pair:ha-canonical-light|888999000"]) == "888999000")
    }

    @Test("A paired canonical id survives either source disappearing")
    func canonicalIDSurvivesSourceDisappearance() throws {
        let haLight = makeLight(id: "ha-stable-light", name: "客厅灯", roomId: "living_room", roomName: "客厅")
        let miLight = makeLight(
            id: "999000111",
            name: "吸顶灯",
            roomId: "mi_room_1",
            roomName: "书房",
            model: "xiaomi.light"
        )
        let haHome = makeHome(
            devices: [haLight],
            identities: [
                haLight.id: makeIdentity(
                    dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_999000111"]),
                    model: haLight.model,
                    name: haLight.name,
                    roomName: haLight.roomName,
                    kind: .light
                )
            ]
        )
        let miHome = makeHome(
            devices: [miLight],
            identities: [
                miLight.id: makeIdentity(
                    dids: ["999000111"],
                    model: miLight.model,
                    name: miLight.name,
                    roomName: miLight.roomName,
                    kind: .light
                )
            ]
        )

        let both = DeviceDeduplicator.merge(homeAssistant: haHome, xiaomiCloud: miHome)
        let canonicalID = try #require(both.home.devices.first?.id)
        #expect(canonicalID == "ha-stable-light")

        let miOnly = DeviceDeduplicator.merge(
            homeAssistant: nil,
            xiaomiCloud: miHome,
            canonical: both.canonical,
            rooms: both.rooms
        )
        #expect(miOnly.home.devices.count == 1)
        #expect(miOnly.home.devices.first?.id == canonicalID)
        #expect(miOnly.routes[canonicalID]?.backend == .xiaomiCloud)
        #expect(miOnly.routes[canonicalID]?.sourceDeviceID == "999000111")

        let haOnly = DeviceDeduplicator.merge(
            homeAssistant: haHome,
            xiaomiCloud: nil,
            canonical: both.canonical,
            rooms: both.rooms
        )
        #expect(haOnly.home.devices.count == 1)
        #expect(haOnly.home.devices.first?.id == canonicalID)
        #expect(haOnly.routes[canonicalID]?.backend == .homeAssistant)
        #expect(haOnly.routes[canonicalID]?.sourceDeviceID == "ha-stable-light")
    }

    @Test("A fallback-only pair keeps its canonical id after a rename during source handoff")
    func fallbackPairCanonicalSurvivesRename() throws {
        let haLight = makeLight(
            id: "ha-renamed-floor-light",
            name: "落地灯",
            roomId: "study",
            roomName: "书房",
            model: "vendor.floor.light"
        )
        let miLight = makeLight(
            id: "777000111",
            name: "落地灯",
            roomId: "mi_room_study",
            roomName: "书房",
            model: "xiaomi.floor.light"
        )
        let haIdentity = makeIdentity(
            model: haLight.model,
            name: haLight.name,
            roomName: haLight.roomName,
            kind: .light
        )
        let miIdentity = makeIdentity(
            model: miLight.model,
            name: miLight.name,
            roomName: miLight.roomName,
            kind: .light
        )
        let both = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [haLight], identities: [haLight.id: haIdentity]),
            xiaomiCloud: makeHome(devices: [miLight], identities: [miLight.id: miIdentity])
        )
        let canonicalID = try #require(both.home.devices.first?.id)
        #expect(canonicalID == "ha-renamed-floor-light")

        let renamedMi = makeLight(
            id: "777000111",
            name: "阳台灯",
            roomId: "mi_room_balcony",
            roomName: "阳台",
            model: "xiaomi.balcony.light"
        )
        let renamedMiIdentity = makeIdentity(
            model: renamedMi.model,
            name: renamedMi.name,
            roomName: renamedMi.roomName,
            kind: .light
        )
        let miOnly = DeviceDeduplicator.merge(
            homeAssistant: nil,
            xiaomiCloud: makeHome(devices: [renamedMi], identities: [renamedMi.id: renamedMiIdentity]),
            canonical: both.canonical,
            rooms: both.rooms
        )
        #expect(miOnly.home.devices.first?.id == canonicalID)
        #expect(miOnly.routes[canonicalID]?.backend == .xiaomiCloud)

        let renamedHA = makeLight(
            id: "ha-renamed-floor-light",
            name: "阳台灯",
            roomId: "balcony",
            roomName: "阳台",
            model: "vendor.balcony.light"
        )
        let renamedHAIdentity = makeIdentity(
            model: renamedHA.model,
            name: renamedHA.name,
            roomName: renamedHA.roomName,
            kind: .light
        )
        let haOnly = DeviceDeduplicator.merge(
            homeAssistant: makeHome(devices: [renamedHA], identities: [renamedHA.id: renamedHAIdentity]),
            xiaomiCloud: nil,
            canonical: both.canonical,
            rooms: both.rooms
        )
        #expect(haOnly.home.devices.first?.id == canonicalID)
        #expect(haOnly.routes[canonicalID]?.backend == .homeAssistant)
    }

    @Test("Routes point at the winning source device for command dispatch")
    func routesPointAtWinningSourceDevice() throws {
        let haSpeaker = makeSpeaker(
            id: "ha-offline-speaker",
            name: "客厅音箱",
            roomId: "living_room",
            roomName: "客厅",
            isOnline: false,
            tts: true,
            directive: true
        )
        let miSpeaker = makeSpeaker(
            id: "222333444",
            name: "小爱音箱",
            roomId: "mi_room_1",
            roomName: "书房"
        )
        let result = DeviceDeduplicator.merge(
            homeAssistant: makeHome(
                devices: [haSpeaker],
                identities: [
                    haSpeaker.id: makeIdentity(
                        dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_222333444"]),
                        model: haSpeaker.model,
                        name: haSpeaker.name,
                        roomName: haSpeaker.roomName,
                        kind: .speaker
                    )
                ]
            ),
            xiaomiCloud: makeHome(
                devices: [miSpeaker],
                identities: [
                    miSpeaker.id: makeIdentity(
                        dids: ["222333444"],
                        model: miSpeaker.model,
                        name: miSpeaker.name,
                        roomName: miSpeaker.roomName,
                        kind: .speaker
                    )
                ]
            )
        )

        let device = try #require(result.home.devices.first)
        let route = try #require(result.routes[device.id])
        #expect(route.backend == .xiaomiCloud)
        #expect(route.sourceDeviceID == "222333444")
        #expect(route.sourceDevice == miSpeaker)
        #expect(result.home.deviceBackends[device.id] == .xiaomiCloud)
    }

    @Test("Active backends and device backends reflect the merged sources")
    func activeAndDeviceBackendsReflectSources() throws {
        let haLight = makeLight(id: "ha-backend-light", name: "客厅灯", roomId: "living_room", roomName: "客厅")
        let miLight = makeLight(
            id: "333444555",
            name: "吸顶灯",
            roomId: "mi_room_1",
            roomName: "书房",
            model: "xiaomi.light"
        )
        let haHome = makeHome(
            devices: [haLight],
            identities: [
                haLight.id: makeIdentity(
                    dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_333444555"]),
                    model: haLight.model,
                    name: haLight.name,
                    roomName: haLight.roomName,
                    kind: .light
                )
            ]
        )
        let miHome = makeHome(
            devices: [miLight],
            identities: [
                miLight.id: makeIdentity(
                    dids: ["333444555"],
                    model: miLight.model,
                    name: miLight.name,
                    roomName: miLight.roomName,
                    kind: .light
                )
            ]
        )

        let both = DeviceDeduplicator.merge(homeAssistant: haHome, xiaomiCloud: miHome)
        #expect(both.home.activeBackends == Set<HomeBackend>([.homeAssistant, .xiaomiCloud]))
        #expect(both.home.devices.count == 1)
        for device in both.home.devices {
            let route = try #require(both.routes[device.id])
            #expect(both.home.deviceBackends[device.id] == route.backend)
        }

        let miOnly = DeviceDeduplicator.merge(homeAssistant: nil, xiaomiCloud: miHome)
        #expect(miOnly.home.activeBackends == Set<HomeBackend>([.xiaomiCloud]))
        #expect(miOnly.home.deviceBackends.count == miOnly.home.devices.count)
        #expect(miOnly.home.deviceIdentities.isEmpty)
    }

    @Test("Same-room same-model sibling does not hijack canonical ID via fallback key")
    func siblingDoesNotHijackCanonicalID() throws {
        let haLightA = makeLight(id: "ha-light-a", name: "筒灯A", roomId: "living_room", roomName: "客厅", model: "yeelink.light.spot1")
        let haLightB = makeLight(id: "ha-light-b", name: "筒灯B", roomId: "living_room", roomName: "客厅", model: "yeelink.light.spot1")
        let miLightA = makeLight(id: "111000111", name: "筒灯A", roomId: "mi_living", roomName: "客厅", model: "yeelink.light.spot1")

        let haHome = makeHome(
            devices: [haLightA, haLightB],
            identities: [
                haLightA.id: makeIdentity(dids: ["111000111"], model: haLightA.model, name: haLightA.name, roomName: "客厅", kind: .light),
                haLightB.id: makeIdentity(dids: ["222000222"], model: haLightB.model, name: haLightB.name, roomName: "客厅", kind: .light),
            ]
        )
        let miHome = makeHome(
            devices: [miLightA],
            identities: [
                miLightA.id: makeIdentity(dids: ["111000111"], model: miLightA.model, name: miLightA.name, roomName: "客厅", kind: .light),
            ]
        )

        let first = DeviceDeduplicator.merge(
            homeAssistant: haHome,
            xiaomiCloud: miHome,
            knownPreferenceIDs: ["ha-light-a"]
        )
        #expect(Set(first.home.devices.map(\.id)) == Set(["ha-light-a", "ha-light-b"]))
        #expect(first.canonical.assignments["fallback-model:客厅|yeelink.light.spot1|light"] == nil)

        // Even if only Light B remains in a later HA-only snapshot, it keeps its own ID and never steals ha-light-a.
        let bOnlyHome = makeHome(
            devices: [haLightB],
            identities: [
                haLightB.id: makeIdentity(dids: ["222000222"], model: haLightB.model, name: haLightB.name, roomName: "客厅", kind: .light),
            ]
        )
        let second = DeviceDeduplicator.merge(
            homeAssistant: bOnlyHome,
            xiaomiCloud: nil,
            canonical: first.canonical
        )
        #expect(second.home.devices.map(\.id) == ["ha-light-b"])
    }

    @Test("DID hardware match pairs before shared gateway MAC address")
    func didPassRunsBeforeSharedGatewayMAC() throws {
        let sharedMAC = "aabbccddeeff"
        let haSubDevice = makeLight(id: "ha-sub-1", name: "子设备灯", roomId: "living_room", roomName: "客厅")
        let miSubDevice1 = makeLight(id: "888000111", name: "子设备灯", roomId: "mi_living", roomName: "客厅")
        let miSubDevice2 = makeLight(id: "888000222", name: "走廊灯", roomId: "mi_hall", roomName: "走廊")

        let haHome = makeHome(
            devices: [haSubDevice],
            identities: [
                haSubDevice.id: makeIdentity(
                    dids: ["888000111"],
                    macs: [sharedMAC],
                    model: haSubDevice.model,
                    name: haSubDevice.name,
                    roomName: "客厅",
                    kind: .light
                )
            ]
        )
        let miHome = makeHome(
            devices: [miSubDevice1, miSubDevice2],
            identities: [
                miSubDevice1.id: makeIdentity(
                    dids: ["888000111"],
                    macs: [sharedMAC],
                    model: miSubDevice1.model,
                    name: miSubDevice1.name,
                    roomName: "客厅",
                    kind: .light
                ),
                miSubDevice2.id: makeIdentity(
                    dids: ["888000222"],
                    macs: [sharedMAC],
                    model: miSubDevice2.model,
                    name: miSubDevice2.name,
                    roomName: "走廊",
                    kind: .light
                ),
            ]
        )

        let result = DeviceDeduplicator.merge(homeAssistant: haHome, xiaomiCloud: miHome)
        #expect(result.home.devices.count == 2)
        #expect(Set(result.home.devices.map(\.id)) == Set(["ha-sub-1", "888000222"]))
    }

    @Test("A source pin overrides the automatic winner while the pinned source is online")
    func pinnedSourceOverridesWinner() throws {
        let haLight = makeLight(id: "ha-pinned-light", name: "客厅灯", roomId: "living_room", roomName: "客厅")
        let miLight = makeLight(id: "555666777", name: "吸顶灯", roomId: "mi_room_1", roomName: "客厅", model: "xiaomi.light")
        let haHome = makeHome(
            devices: [haLight],
            identities: [
                haLight.id: makeIdentity(
                    dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_555666777"]),
                    model: haLight.model,
                    name: haLight.name,
                    roomName: haLight.roomName,
                    kind: .light
                )
            ]
        )
        let miHome = makeHome(
            devices: [miLight],
            identities: [
                miLight.id: makeIdentity(
                    dids: ["555666777"],
                    model: miLight.model,
                    name: miLight.name,
                    roomName: miLight.roomName,
                    kind: .light
                )
            ]
        )

        let automatic = DeviceDeduplicator.merge(homeAssistant: haHome, xiaomiCloud: miHome)
        let cardID = try #require(automatic.home.devices.first?.id)
        #expect(automatic.home.deviceBackends[cardID] == .homeAssistant)
        #expect(automatic.home.pairedDeviceIDs.contains(cardID))

        let pinned = DeviceDeduplicator.merge(
            homeAssistant: haHome,
            xiaomiCloud: miHome,
            pinnedBackends: [cardID: .xiaomiCloud]
        )
        #expect(pinned.home.deviceBackends[cardID] == .xiaomiCloud)
        #expect(pinned.routes[cardID]?.sourceDeviceID == miLight.id)
        #expect(pinned.routes[cardID]?.sourceDevice == miLight)
    }

    @Test("A pin falls back to the online source when the pinned source is offline")
    func pinFallsBackWhenPinnedSourceOffline() throws {
        let haLight = makeLight(
            id: "ha-offline-pinned",
            name: "客厅灯",
            roomId: "living_room",
            roomName: "客厅",
            isOnline: false
        )
        let miLight = makeLight(id: "555666778", name: "吸顶灯", roomId: "mi_room_1", roomName: "客厅", model: "xiaomi.light")
        let haHome = makeHome(
            devices: [haLight],
            identities: [
                haLight.id: makeIdentity(
                    dids: DeviceIdentityNormalizer.didCandidates(from: ["xiaomi_home_555666778"]),
                    model: haLight.model,
                    name: haLight.name,
                    roomName: haLight.roomName,
                    kind: .light
                )
            ]
        )
        let miHome = makeHome(
            devices: [miLight],
            identities: [
                miLight.id: makeIdentity(
                    dids: ["555666778"],
                    model: miLight.model,
                    name: miLight.name,
                    roomName: miLight.roomName,
                    kind: .light
                )
            ]
        )

        let automatic = DeviceDeduplicator.merge(homeAssistant: haHome, xiaomiCloud: miHome)
        let cardID = try #require(automatic.home.devices.first?.id)
        #expect(automatic.home.deviceBackends[cardID] == .xiaomiCloud)

        let pinned = DeviceDeduplicator.merge(
            homeAssistant: haHome,
            xiaomiCloud: miHome,
            pinnedBackends: [cardID: .homeAssistant]
        )
        #expect(pinned.home.deviceBackends[cardID] == .xiaomiCloud)
        #expect(pinned.routes[cardID]?.sourceDeviceID == miLight.id)
    }
}
