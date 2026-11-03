import Foundation
import Testing
@testable import MijiaCore

/// #189: Mi light-group members fold into the group card on screen, while every other action
/// still sees the full device set.
@MainActor
struct LightGroupFoldTests {
    private static let owners = ["123": "group.living", "456": "group.living", "789": "group.living"]

    private func light(
        _ id: String,
        name: String,
        roomId: String,
        roomName: String,
        isOn: Bool,
        isOnline: Bool = true
    ) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: roomId, roomName: roomName, model: "yeelink.light.ceiling22",
            isOnline: isOnline, kind: .light(LightSpec(entityId: "miot:\(id):2", isOn: isOn))
        )
    }

    private func makeHome(groupOnline: Bool = true, groupOn: Bool = false) -> SynthesizedHome {
        var home = SynthesizedHome(
            rooms: [
                RoomArea(id: "ke_ting", name: "客厅", sortOrder: 1),
                RoomArea(id: "shu_fang", name: "书房", sortOrder: 2),
            ],
            devices: [
                light("group.living", name: "客厅灯组", roomId: "ke_ting", roomName: "客厅",
                      isOn: groupOn, isOnline: groupOnline),
                light("123", name: "吸顶灯", roomId: "ke_ting", roomName: "客厅", isOn: true),
                light("456", name: "落地灯", roomId: "ke_ting", roomName: "客厅", isOn: true),
                light("789", name: "书房灯", roomId: "shu_fang", roomName: "书房", isOn: true),
                light("999", name: "走廊灯", roomId: "ke_ting", roomName: "客厅", isOn: true),
            ]
        )
        home.lightGroupOwners = Self.owners
        return home
    }

    private func makeStore(
        _ home: SynthesizedHome,
        suite: String = "test.lightgroup.\(UUID().uuidString)"
    ) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        try await store.waitForInitialSnapshot()
        return (store, mock)
    }

    private func ids(_ devices: [SmartDevice]) -> Set<String> {
        Set(devices.map(\.id))
    }

    @Test("Grouped member lights fold only while their group card is visible; the preference persists")
    func foldsVisibleGroupMembers() async throws {
        let suite = "test.lightgroup.\(UUID().uuidString)"
        let (store, _) = try await makeStore(makeHome(), suite: suite)
        defer { store.userDefaults.removePersistentDomain(forName: suite) }

        #expect(store.hideGroupedLights, "hide grouped lights is on by default")
        #expect(ids(store.visibleDevices) == ["group.living", "999"])
        // The filtered set stays complete: all-off, scenes, search and the assistant read it.
        #expect(ids(store.filteredDevices) == ["group.living", "123", "456", "789", "999"])
        #expect(store.activeDeviceCount == 4)
        #expect(PanelSearch.results("吸顶", devices: store.devices, hiddenIds: store.hiddenDeviceIds).map(\.id) == ["123"])

        store.hideGroupedLights = false
        #expect(ids(store.visibleDevices) == ["group.living", "123", "456", "789", "999"])
        #expect(store.userDefaults.object(forKey: "hide_grouped_lights") as? Bool == false)

        let reloaded = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(!reloaded.hideGroupedLights)
    }

    @Test("A hidden group card leaves its member lights visible")
    func hiddenGroupLeavesMembers() async throws {
        let (store, _) = try await makeStore(makeHome())
        store.hideDevice("group.living")
        #expect(ids(store.visibleDevices) == ["123", "456", "789", "999"])
    }

    @Test("An offline group card leaves its online member lights visible")
    func offlineGroupLeavesMembers() async throws {
        let (store, _) = try await makeStore(makeHome(groupOnline: false))
        store.hideOfflineDevices = true
        #expect(ids(store.visibleDevices) == ["123", "456", "789", "999"])
    }

    @Test("An offline group card never folds members even while offline devices are shown")
    func visibleOfflineGroupDoesNotFold() async throws {
        let (store, _) = try await makeStore(makeHome(groupOnline: false))
        #expect(!store.hideOfflineDevices)
        #expect(ids(store.filteredDevices).contains("group.living"))
        #expect(ids(store.visibleDevices) == ["group.living", "123", "456", "789", "999"])
    }

    @Test("A room or kind cut that drops the group card keeps its members visible")
    func filteredGroupLeavesMembers() async throws {
        let (store, _) = try await makeStore(makeHome())
        #expect(store.selectRoom("shu_fang"))
        #expect(ids(store.visibleDevices) == ["789"])
        #expect(ids(store.filteredDevices) == ["789"])

        _ = store.selectRoom(nil)
        store.selectKind(.light)
        #expect(ids(store.visibleDevices) == ["group.living", "999"])
    }

    @Test("A stale owner whose group card is not in the list never hides the light")
    func ownerWithoutGroupCardDoesNotFold() async throws {
        var home = makeHome()
        home.lightGroupOwners = ["999": "group.gone", "123": "group.living"]
        let (store, _) = try await makeStore(home)
        #expect(ids(store.visibleDevices) == ["group.living", "456", "789", "999"])
    }

    @Test("All Off still targets folded members and the group card")
    func allOffTargetsEveryMember() async throws {
        let (store, mock) = try await makeStore(makeHome(groupOn: true))
        #expect(ids(store.visibleDevices) == ["group.living", "999"])
        #expect(ids(store.allOffTargets) == ["group.living", "123", "456", "789", "999"])

        store.turnAllOff()
        for _ in 0..<100 {
            if await mock.executedCommands.count >= 5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await mock.executedCommands
        let written = Set(sent.compactMap { command -> String? in
            if case .setLightPower(let entityId, let isOn) = command, !isOn { return entityId }
            return nil
        })
        #expect(written == ["miot:group.living:2", "miot:123:2", "miot:456:2", "miot:789:2", "miot:999:2"])
        #expect(ids(store.visibleDevices) == ["group.living", "999"])
    }

    @Test("A refreshed owner map changes the folded results")
    func refreshingOwnersRefolds() async throws {
        let (store, mock) = try await makeStore(makeHome())
        #expect(ids(store.visibleDevices) == ["group.living", "999"])

        var next = makeHome()
        next.lightGroupOwners = ["123": "group.living"]
        await mock.updateSnapshot(next)
        for _ in 0..<200 {
            if ids(store.visibleDevices) == ["group.living", "456", "789", "999"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ids(store.visibleDevices) == ["group.living", "456", "789", "999"])
    }
}
