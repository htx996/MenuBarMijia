import Foundation
import Testing
@testable import MijiaCore

struct MiAccountsProviderTests {
    private static let cn = MiAccount(session: MiSession(
        userId: "10010001", cUserId: "c-cn", ssecurity: "ssec", serviceToken: "tok-cn", region: "cn"
    ))
    private static let de = MiAccount(session: MiSession(
        userId: "20020002", cUserId: "c-de", ssecurity: "ssec", serviceToken: "tok-de", region: "de"
    ))

    private static func makeProvider(
        _ accounts: [MiAccount],
        cnAPI: StubMiCloudAPI,
        deAPI: StubMiCloudAPI,
        selectedHomeLoader: @escaping @Sendable () -> String? = { nil }
    ) -> MiAccountsProvider {
        let factory: MiCloudProvider.APIFactory = { session in
            if session.region == "de" { return deAPI }
            return cnAPI
        }
        return MiAccountsProvider(
            accounts: accounts,
            apiFactory: factory,
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            followUpDelay: .milliseconds(10),
            selectedHomeLoader: selectedHomeLoader
        )
    }

    @Test("Two accounts in different regions list their devices and homes independently")
    func twoAccountsListIndependently() async throws {
        let cnApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "cn-light", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light"], homeId: "home-cn", homeName: "国内家")],
            values: [
                MiotFixtures.key("cn-light", 2, 1): .bool(true),
                MiotFixtures.key("cn-light", 2, 2): .number(60),
            ]
        )
        let deApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "de-plug", name: "卧室插座", model: "cuco.plug.v3", isOnline: true)],
            rooms: [MiRoom(id: "r-de", name: "卧室", dids: ["de-plug"], homeId: "home-de", homeName: "海外家")],
            values: [MiotFixtures.key("de-plug", 2, 1): .bool(false)]
        )
        let provider = Self.makeProvider([Self.cn, Self.de], cnAPI: cnApi, deAPI: deApi)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        let merged = await log.wait { events in await events.snapshots.contains { $0.devices.count == 2 } }
        #expect(merged)
        let snapshots = await log.snapshots
        let snapshot = try #require(snapshots.first { $0.devices.count == 2 })
        let devices = Dictionary(uniqueKeysWithValues: snapshot.devices.map { ($0.id, $0) })
        #expect(devices["cn-light"]?.accountId == Self.cn.id)
        #expect(devices["cn-light"]?.accountLabel == Self.cn.maskedUserId)
        #expect(devices["de-plug"]?.accountId == Self.de.id)
        #expect(devices["de-plug"]?.accountLabel == Self.de.maskedUserId)
        #expect(snapshot.homes.map(\.id) == [Self.cn.id + "/home-cn", Self.de.id + "/home-de"])
        let roomIds = Set(snapshot.rooms.map(\.id))
        #expect(roomIds.count == 2)
        let prefixedRooms = roomIds.allSatisfy { $0.hasPrefix(Self.cn.id + "/") || $0.hasPrefix(Self.de.id + "/") }
        let roomsCoverDevices = snapshot.devices.allSatisfy { roomIds.contains($0.roomId) }
        #expect(prefixedRooms)
        #expect(roomsCoverDevices)
        #expect(await cnApi.deviceListCalls > 0)
        #expect(await deApi.deviceListCalls > 0)
        await provider.shutdown()
    }

    @Test("A command routes to the account that owns the device")
    func commandRoutesToOwningAccount() async throws {
        let cnApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "cn-light", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light"], homeId: "home-cn", homeName: "国内家")],
            values: [MiotFixtures.key("cn-light", 2, 1): .bool(true)]
        )
        let deApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "de-plug", name: "卧室插座", model: "cuco.plug.v3", isOnline: true)],
            rooms: [MiRoom(id: "r-de", name: "卧室", dids: ["de-plug"], homeId: "home-de", homeName: "海外家")],
            values: [MiotFixtures.key("de-plug", 2, 1): .bool(false)]
        )
        let provider = Self.makeProvider([Self.cn, Self.de], cnAPI: cnApi, deAPI: deApi)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        let merged = await log.wait { events in await events.snapshots.contains { $0.devices.count == 2 } }
        #expect(merged)
        try await provider.execute(.setSwitch(entityId: "miot:de-plug:2", isOn: true))
        #expect(await deApi.setPropsCalls == [
            [MiotPropWrite(did: "de-plug", siid: 2, piid: 1, value: .bool(true))],
        ])
        #expect(await cnApi.setPropsCalls.isEmpty)
        await provider.shutdown()
    }

    @Test("One expired account does not stop the other")
    func expiredAccountDoesNotStopTheOther() async throws {
        let cnApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "cn-light", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light"], homeId: "home-cn", homeName: "国内家")],
            values: [MiotFixtures.key("cn-light", 2, 1): .bool(true)]
        )
        let deApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "de-plug", name: "卧室插座", model: "cuco.plug.v3", isOnline: true)],
            rooms: [MiRoom(id: "r-de", name: "卧室", dids: ["de-plug"], homeId: "home-de", homeName: "海外家")],
            values: [:],
            failure: .sessionExpired
        )
        let provider = Self.makeProvider([Self.cn, Self.de], cnAPI: cnApi, deAPI: deApi)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        let droppedExpired = await log.wait { events in
            guard await deApi.deviceListCalls > 0 else { return false }
            guard let latest = await events.snapshots.last else { return false }
            let ids = latest.devices.map(\.id)
            return ids.contains("cn-light") && !ids.contains("de-plug")
        }
        #expect(droppedExpired)
        #expect(await cnApi.deviceListCalls > 0)
        #expect(await deApi.deviceListCalls > 0)
        let connected = await log.wait { events in await events.statuses.contains(.connected) }
        #expect(connected)
        await provider.shutdown()
    }

    @Test("The same did from two accounts appears once")
    func duplicateDidAppearsOnce() async throws {
        let values: [MiotPropKey: JSONValue] = [MiotFixtures.key("shared", 2, 1): .bool(true)]
        let cnApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "shared", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["shared"], homeId: "home-cn", homeName: "国内家")],
            values: values
        )
        let deApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "shared", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)],
            rooms: [MiRoom(id: "r-de", name: "客厅", dids: ["shared"], homeId: "home-de", homeName: "海外家")],
            values: values
        )
        let provider = Self.makeProvider([Self.cn, Self.de], cnAPI: cnApi, deAPI: deApi)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        // Two stamped homes mean both accounts have reported, so the merge is final for this assertion.
        let merged = await log.wait { events in await events.snapshots.contains { $0.homes.count == 2 } }
        #expect(merged)
        let snapshots = await log.snapshots
        let snapshot = try #require(snapshots.last { $0.homes.count == 2 })
        #expect(snapshot.devices.count == 1)
        #expect(snapshot.devices.first?.id == "shared")
        #expect(snapshot.devices.first?.accountId == Self.cn.id)

        try await provider.execute(.setSwitch(entityId: "miot:shared:2", isOn: false))
        #expect(await cnApi.setPropsCalls.count == 1)
        #expect(await deApi.setPropsCalls.isEmpty)
        await provider.shutdown()
    }

    @Test("Selected home filters inside the right account")
    func selectedHomeFiltersInsideAccount() async throws {
        let cnApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "cn-light", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light"], homeId: "home-cn", homeName: "国内家")],
            values: [MiotFixtures.key("cn-light", 2, 1): .bool(true)]
        )
        let deApi = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(did: "de-in", name: "卧室灯", model: "yeelink.light.ceiling22", isOnline: true),
                MiDeviceRecord(did: "de-out", name: "厨房灯", model: "yeelink.light.ceiling22", isOnline: true),
            ],
            rooms: [
                MiRoom(id: "r-de-1", name: "卧室", dids: ["de-in"], homeId: "home-de", homeName: "海外家"),
                MiRoom(id: "r-de-2", name: "厨房", dids: ["de-out"], homeId: "home-other", homeName: "度假屋"),
            ],
            values: [
                MiotFixtures.key("de-in", 2, 1): .bool(true),
                MiotFixtures.key("de-out", 2, 1): .bool(true),
            ]
        )
        let provider = Self.makeProvider(
            [Self.cn, Self.de],
            cnAPI: cnApi,
            deAPI: deApi,
            selectedHomeLoader: { Self.de.id + "/home-de" }
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }

        let filtered = await log.wait { events in
            guard await cnApi.deviceListCalls > 0, await deApi.deviceListCalls > 0 else { return false }
            guard let latest = await events.snapshots.last else { return false }
            let ids = latest.devices.map(\.id)
            return latest.homes.count == 3 && ids == ["de-in"]
        }
        #expect(filtered)
        let snapshots = await log.snapshots
        let snapshot = try #require(snapshots.last)
        #expect(snapshot.devices.map(\.id) == ["de-in"])
        #expect(snapshot.rooms.map(\.id) == [Self.de.id + "/wo_shi"])
        #expect(snapshot.homes.map(\.id) == [
            Self.cn.id + "/home-cn",
            Self.de.id + "/home-de",
            Self.de.id + "/home-other",
        ])
        await provider.shutdown()
    }

    @Test("Split-key switch command routes by parent did to the owning account")
    func splitKeyCommandRoutesToOwningAccount() async throws {
        let cnApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "cn-light", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light"], homeId: "home-cn", homeName: "国内家")],
            values: [MiotFixtures.key("cn-light", 2, 1): .bool(true)]
        )
        let deApi = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(did: "100", name: "双键开关", model: "lemesh.switch.sw2f12", isOnline: true),
                MiDeviceRecord(
                    did: "100.s2",
                    name: "筒灯",
                    model: "lemesh.switch.sw2f12",
                    isOnline: true,
                    splitParentDid: "100",
                    splitSiid: 2
                ),
                MiDeviceRecord(
                    did: "100.s3",
                    name: "氛围灯",
                    model: "lemesh.switch.sw2f12",
                    isOnline: true,
                    splitParentDid: "100",
                    splitSiid: 3
                ),
            ],
            rooms: [MiRoom(id: "r-de", name: "卧室", dids: ["100", "100.s2", "100.s3"], homeId: "home-de", homeName: "海外家")],
            values: [
                MiotFixtures.key("100", 2, 1): .bool(false),
                MiotFixtures.key("100", 3, 1): .bool(true),
            ]
        )
        let provider = Self.makeProvider([Self.cn, Self.de], cnAPI: cnApi, deAPI: deApi)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        let merged = await log.wait { events in
            await events.snapshots.contains { snap in
                let ids = Set(snap.devices.map(\.id))
                return ids.contains("100.s2") && ids.contains("100.s3") && !ids.contains("100")
            }
        }
        #expect(merged)

        try await provider.execute(.setSwitch(entityId: "miot:100:3", isOn: false))
        #expect(await deApi.setPropsCalls == [
            [MiotPropWrite(did: "100", siid: 3, piid: 1, value: .bool(false))],
        ])
        #expect(await cnApi.setPropsCalls.isEmpty)
        await provider.shutdown()
    }

    @Test("Waking from sleep keeps closesAwayGap false until every active account polls")
    func wakeFromSleepWaitsForAllAccountsBeforeClosingAwayGap() async throws {
        let cnApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "cn-light", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true)],
            rooms: [MiRoom(id: "r-cn", name: "客厅", dids: ["cn-light"], homeId: "home-cn", homeName: "国内家")],
            values: [MiotFixtures.key("cn-light", 2, 1): .bool(true)]
        )
        let deApi = StubMiCloudAPI(
            devices: [MiDeviceRecord(did: "de-plug", name: "卧室插座", model: "cuco.plug.v3", isOnline: true)],
            rooms: [MiRoom(id: "r-de", name: "卧室", dids: ["de-plug"], homeId: "home-de", homeName: "海外家")],
            values: [MiotFixtures.key("de-plug", 2, 1): .bool(false)]
        )
        let provider = Self.makeProvider([Self.cn, Self.de], cnAPI: cnApi, deAPI: deApi)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        let initialReady = await log.wait { events in
            await events.snapshots.contains { $0.devices.count == 2 && $0.closesAwayGap }
        }
        #expect(initialReady)

        // Pause polling (Mac sleeps), then hold DE's wake poll until CN has already reported.
        await provider.setPollingContext(PollingContext(panelVisible: false, systemActive: false, lowPower: false))
        let (deStream, deCont) = AsyncStream<Void>.makeStream()
        await deApi.setGetPropsHook {
            var iter = deStream.makeAsyncIterator()
            _ = await iter.next()
        }
        let cnCallsBeforeWake = await cnApi.getPropsCalls.count
        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: true, lowPower: false))

        let cnReportedAfterWake = await log.wait { _ in
            await cnApi.getPropsCalls.count > cnCallsBeforeWake
        }
        #expect(cnReportedAfterWake)
        // Give the merged snapshot from CN's wake poll a turn to arrive; DE is still blocked.
        let partialWakeSnapshot = await log.wait { events in
            guard let latest = await events.snapshots.last else { return false }
            return !latest.closesAwayGap
        }
        #expect(partialWakeSnapshot)

        await deApi.setGetPropsHook(nil)
        deCont.yield(())
        deCont.finish()

        let bothReportedAfterWake = await log.wait { events in
            guard let latest = await events.snapshots.last else { return false }
            return latest.closesAwayGap
        }
        #expect(bothReportedAfterWake)
        await provider.shutdown()
    }

    @Test("Light-group owners merge across accounts only for cards that survived the merge")
    func groupOwnersMergeAcrossAccounts() async throws {
        let cnApi = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(did: "group.cn", name: "客厅灯组", model: "yeelink.light.ceiling22", isOnline: true),
                MiDeviceRecord(did: "cn-light", name: "客厅灯", model: "yeelink.light.ceiling22", isOnline: true),
            ],
            rooms: [],
            values: [MiotFixtures.key("cn-light", 2, 1): .bool(true)]
        )
        let deApi = StubMiCloudAPI(
            devices: [
                MiDeviceRecord(did: "group.de", name: "卧室灯组", model: "yeelink.light.ceiling22", isOnline: true),
                MiDeviceRecord(did: "de-light", name: "卧室灯", model: "yeelink.light.ceiling22", isOnline: true),
            ],
            rooms: [],
            values: [MiotFixtures.key("de-light", 2, 1): .bool(true)]
        )
        await cnApi.setGroupMembers(["group.cn": ["cn-light", "dropped-light"]])
        await deApi.setGroupMembers(["group.de": ["de-light"]])

        let provider = Self.makeProvider([Self.cn, Self.de], cnAPI: cnApi, deAPI: deApi)
        let (log, task) = consume(provider)
        defer { task.cancel() }

        let mapped = await log.wait { events in
            await events.snapshots.last?.lightGroupOwners == ["cn-light": "group.cn", "de-light": "group.de"]
        }
        #expect(mapped)
        await provider.shutdown()
    }
}
