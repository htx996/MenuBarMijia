import AppKit
import SwiftUI
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
private final class TestStatusBarButton: NSStatusBarButton {
    var performClickCount = 0
    var onPerformClick: (() -> Void)?

    override func performClick(_ sender: Any?) {
        performClickCount += 1
        onPerformClick?()
    }
}

@MainActor
private final class TestStatusItem: NSStatusItem {
    let testButton = TestStatusBarButton()
    override var button: NSStatusBarButton? { testButton }
}

/// #56: the control center is hosted by an app-owned `NSStatusItem` + `NSPanel` instead of the
/// `MenuBarExtra` scene. These tests drive the real AppKit objects — window creation, show/hide,
/// outside-click closing, sizing and positioning — with an in-memory home and no network.
///
/// `swift test` does not run the app, so the `Settings` scene, SwiftUI lifecycle and the menu bar
/// itself are out of reach; those remain manual acceptance on a Mac.
@MainActor
@Suite(.serialized)
struct MenuBarPanelControllerTests {
    private func makeStore() async throws -> (HomeStore, String) {
        let suite = "test.panel.controller.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<200 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.devices.isEmpty, "MockHomeProvider should deliver a snapshot right away")
        return (store, suite)
    }

    private func makeExpiredMiSessionStore() async throws -> (HomeStore, String) {
        let suite = "test.panel.controller.expired.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(HomeBackend.xiaomiCloud.rawValue, forKey: "home_backend")
        let session = MiSession(
            userId: "42",
            cUserId: "c",
            ssecurity: "c2VjcmV0",
            serviceToken: "tok",
            expiresAt: Date().addingTimeInterval(-60)
        )
        #expect(MiSessionStore.save(session, defaults: defaults))
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<200 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.miSessionShowsExpired)
        return (store, suite)
    }

    private func makeController(store: HomeStore) -> MenuBarPanelController {
        // `swift test` does not launch an app; AppKit still needs its shared application object
        // before a status item or a window can exist.
        _ = NSApplication.shared
        let controller = MenuBarPanelController()
        controller.presentsActively = false
        controller.install(with: store)
        return controller
    }

    @Test("Installing creates one status item with a button and uninstall releases it")
    func installCreatesStatusItem() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let item = try #require(controller.statusItem)
        #expect(item.button != nil)
        #expect(controller.panelWindow == nil, "the panel window is created lazily on first open")
        #expect(controller.isPanelVisible == false)

        controller.uninstall()
        #expect(controller.statusItem == nil)
        #expect(controller.panelWindow == nil)
    }

    @Test("Status context menu has live mode, source status, Settings, updates, and Quit in both languages")
    func statusContextMenuStructureAndLocalization() {
        let controller = MenuBarPanelController()

        func verify(language: AppLanguage, titles: [String], connectionTitles: [String]) {
            L10n.$overrideLanguage.withValue(language) {
                let menu = controller.makeStatusContextMenu()
                #expect(menu.items.count == 5)
                guard menu.items.count == 5 else { return }
                #expect(menu.items.map(\.title) == titles)
                #expect(menu.items[3].isSeparatorItem)

                let connections = menu.items[0]
                let submenu = connections.submenu
                #expect(submenu != nil)
                guard let submenu else { return }
                #expect(submenu.items.map(\.title) == connectionTitles)
                #expect(submenu.items.count == 7)
                guard submenu.items.count == 7 else { return }
                #expect(submenu.items[2].isSeparatorItem)
                #expect(submenu.items[5].isSeparatorItem)

                let modeItems = Array(submenu.items.prefix(2))
                #expect(modeItems.map { $0.representedObject as? String } == [
                    "homeAssistant",
                    "demo",
                ])
                for item in modeItems {
                    #expect(item.target === controller)
                    #expect(item.action == NSSelectorFromString("switchBackendFromStatusMenu:"))
                }
                for item in submenu.items[3...4] {
                    #expect(item.isEnabled == false)
                    #expect(item.action == nil)
                }
                #expect(submenu.items[6].target === controller)
                #expect(
                    submenu.items[6].action
                        == NSSelectorFromString("openConnectionSettingsFromStatusMenu:")
                )

                let actions = [
                    #selector(MenuBarPanelController.openSettingsFromStatusMenu(_:)),
                    #selector(MenuBarPanelController.openUpdatesFromStatusMenu(_:)),
                    #selector(MenuBarPanelController.quitFromStatusMenu(_:)),
                ]
                for (item, action) in zip([menu.items[1], menu.items[2], menu.items[4]], actions) {
                    #expect(item.target === controller)
                    #expect(item.action == action)
                }
            }
        }

        verify(
            language: .zhHans,
            titles: ["家居连接", "设置…", "检查更新…", "", "退出 MenuBarMijia"],
            connectionTitles: [
                "实时连接",
                "演示模式",
                "",
                "Home Assistant",
                "米家云端直连",
                "",
                "打开连接设置…",
            ]
        )
        verify(
            language: .zhHant,
            titles: ["家居連線", "設定…", "檢查更新…", "", "退出 MenuBarMijia"],
            connectionTitles: [
                "實時連線",
                "演示模式",
                "",
                "Home Assistant",
                "米家雲端直連",
                "",
                "開啟連線設定…",
            ]
        )
        verify(
            language: .en,
            titles: ["Connections", "Settings…", "Check for Updates…", "", "Quit MenuBarMijia"],
            connectionTitles: [
                "Live Connections",
                "Demo Mode",
                "",
                "Home Assistant",
                "Xiaomi Cloud Direct",
                "",
                "Open Connection Settings…",
            ]
        )
    }

    @Test("Connections submenu distinguishes live mode from the included live sources")
    func statusContextMenuReflectsConnectionState() throws {
        let cases: [(MenuBarPanelController.StatusConnectionMenuState, [NSControl.StateValue])] = [
            (
                .init(
                    homeBackend: .homeAssistant,
                    hasHASource: true,
                    hasMiSource: true,
                    preferredLiveBackend: .homeAssistant
                ),
                [.on, .off, .on, .on]
            ),
            (
                .init(
                    homeBackend: .xiaomiCloud,
                    hasHASource: false,
                    hasMiSource: true,
                    preferredLiveBackend: .xiaomiCloud
                ),
                [.on, .off, .off, .on]
            ),
            (
                .init(
                    homeBackend: .demo,
                    hasHASource: true,
                    hasMiSource: true,
                    preferredLiveBackend: .homeAssistant
                ),
                [.off, .on, .off, .off]
            ),
        ]
        let controller = MenuBarPanelController()

        for (state, expectedStates) in cases {
            let menu = controller.makeStatusContextMenu(connectionState: state)
            let submenu = try #require(menu.items[0].submenu)
            let states = [submenu.items[0], submenu.items[1], submenu.items[3], submenu.items[4]]
                .map(\.state)
            #expect(states == expectedStates)
        }
    }

    @Test("Status context menu routes backends, Settings pages, and Quit to their owners")
    func statusContextMenuActionRouting() throws {
        let controller = MenuBarPanelController()
        var selectedBackends: [HomeBackend] = []
        controller.switchHomeBackend = { selectedBackends.append($0) }

        let state = MenuBarPanelController.StatusConnectionMenuState(
            homeBackend: .xiaomiCloud,
            hasHASource: false,
            hasMiSource: true,
            preferredLiveBackend: .xiaomiCloud
        )
        let submenu = try #require(
            controller.makeStatusContextMenu(connectionState: state).items[0].submenu
        )
        let switchSelector = NSSelectorFromString("switchBackendFromStatusMenu:")
        #expect(controller.responds(to: switchSelector))
        guard controller.responds(to: switchSelector) else { return }

        let modeItems = Array(submenu.items.prefix(2))
        let expectedBackends: [HomeBackend] = [.xiaomiCloud, .demo]
        for (item, expectedBackend) in zip(modeItems, expectedBackends) {
            _ = controller.perform(switchSelector, with: item)
            #expect(selectedBackends.last == expectedBackend)
        }

        for malformedPayload in [nil, "unknown", 7] as [Any?] {
            let item = NSMenuItem()
            item.representedObject = malformedPayload
            _ = controller.perform(switchSelector, with: item)
            #expect(selectedBackends == [.xiaomiCloud, .demo])
        }

        var requestedTabs: [SettingsTab?] = []
        controller.showSettings = { requestedTabs.append($0) }

        let connectionSettingsSelector = NSSelectorFromString(
            "openConnectionSettingsFromStatusMenu:"
        )
        #expect(controller.responds(to: connectionSettingsSelector))
        guard controller.responds(to: connectionSettingsSelector) else { return }
        _ = controller.perform(connectionSettingsSelector, with: submenu.items[6])

        controller.openSettingsFromStatusMenu(nil)
        controller.openUpdatesFromStatusMenu(nil)
        #expect(requestedTabs == [.connection, nil, .about])

        var didRequestTermination = false
        controller.terminateApplication = { didRequestTermination = true }
        controller.quitFromStatusMenu(nil)
        #expect(didRequestTermination)
    }

    @Test("Secondary status-item click presents one menu and suppresses trailing primary events")
    func secondaryStatusItemClickPresentsMenuOnly() {
        let speech = SpeechInputController.shared
        let previousDraft = speech.draft
        let wasListening = speech.isListening
        let wasHoldToTalk = speech.isHoldToTalk
        speech.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
        defer {
            speech.setPreviewState(
                isListening: wasListening,
                isHoldToTalk: wasHoldToTalk,
                draft: previousDraft
            )
        }

        let controller = MenuBarPanelController()
        var presentedMenus: [NSMenu] = []
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = {
            presentedMenus.append($0)
            eventNumber = 101
        }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        controller.handleStatusItemEvent(eventType: .rightMouseUp, pressedMouseButtons: 0)
        // macOS 26 can deliver the compatibility selector and a trailing synthetic primary click
        // for the same physical secondary click. Neither may present twice or toggle the panel.
        controller.handleStatusItemNativeLongPressEvent(
            eventType: .rightMouseDown,
            pressedMouseButtons: 0x2
        )
        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(presentedMenus.count == 1)
        #expect(presentedMenus[0].items.count == 5)
        #expect(toggleCount == 0)
        #expect(controller.isPanelVisible == false)
        #expect(controller.isStatusItemPressActive == false)
        #expect(speech.isListening == false)
        #expect(speech.isHoldToTalk == false)
    }

    @Test("First physical primary click after dismissing the context menu toggles the panel")
    func primaryClickAfterContextMenuDismissalToggles() {
        let controller = MenuBarPanelController()
        var presentedMenuCount = 0
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in
            presentedMenuCount += 1
            // AppKit returns from its modal menu loop while handling the mouse-up that dismissed it.
            eventNumber = 101
        }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        // The mouse-up that dismissed AppKit's modal menu is forwarded once more to the status item.
        // It closes the menu only and must not toggle the panel.
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 0)

        // The out-of-process menu-bar host can deliver the user's next real short click as only a
        // mouse-up. Its distinct event number identifies it as a new click, which must open the
        // panel immediately instead of forcing a third click.
        eventNumber = 102
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(presentedMenuCount == 1)
        #expect(toggleCount == 1)
    }

    @Test("Monitor-started first click after menu dismissal toggles despite an early button mouse-up")
    func monitorStartedPostMenuClickToggles() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in eventNumber = 101 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        // The dismissal mouse-up itself only closes the menu.
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 0)

        // The host forwards the user's next physical down to the mouse monitor but not to the
        // button, and its short click ends with a button mouse-up before the 30 ms hold tick.
        eventNumber = 102
        controller.beginHoldDetectionFromMonitor()
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(toggleCount == 1, "the pending post-menu click must not be discarded as a hold")
        #expect(controller.isStatusItemPressActive == false)

        // Consuming the fallback keeps a later stray mouse-up from toggling a second time.
        eventNumber = 103
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 1)
    }

    @Test("Monitor-started press without a pending menu click does not toggle the panel")
    func monitorStartedPressWithoutPendingClickDoesNotToggle() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        controller.statusItemEventNumber = { 200 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.beginHoldDetectionFromMonitor()
        #expect(controller.isStatusItemPressActive)

        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(toggleCount == 0)
        #expect(controller.isStatusItemPressActive == false)
    }

    @Test("Keyboard current events never reach the mouse-only eventNumber accessor")
    func statusEventNumberRejectsNonMouseEvents() throws {
        let keyDown = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        #expect(MenuBarPanelController.statusEventNumber(for: keyDown) == nil)
        #expect(MenuBarPanelController.statusEventNumber(for: nil) == nil)

        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 42,
            clickCount: 1,
            pressure: 0
        ))
        #expect(MenuBarPanelController.statusEventNumber(for: mouseUp) == 42)
    }

    @Test("Native primary hold after menu dismissal cannot reuse the release as a panel click")
    func nativePrimaryHoldClearsPostMenuClickFallback() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in eventNumber = 101 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)

        // macOS 26 can accept a native hold without forwarding its primary mouse-down. Model the
        // timer seeing the release before the button's later mouse-up callback.
        eventNumber = 102
        controller.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0
        )
        #expect(controller.isStatusItemPressActive == false)

        eventNumber = 103
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(toggleCount == 0)
    }

    @Test("Primary status-item click still toggles and native primary hold stays on hold-to-talk path")
    func primaryStatusItemGesturesRemainUnchanged() {
        let controller = MenuBarPanelController()
        var toggleCount = 0
        var presentedMenuCount = 0
        controller.statusItemToggle = { toggleCount += 1 }
        controller.statusContextMenuPresenter = { _ in presentedMenuCount += 1 }

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        #expect(controller.isStatusItemPressActive)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 1)
        #expect(controller.isStatusItemPressActive == false)

        let holdController = MenuBarPanelController()
        holdController.statusItemToggle = { toggleCount += 1 }
        holdController.statusContextMenuPresenter = { _ in presentedMenuCount += 1 }
        holdController.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        #expect(holdController.isStatusItemPressActive)
        #expect(presentedMenuCount == 0)
        holdController.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(holdController.isStatusItemPressActive == false)
        #expect(toggleCount == 1, "releasing a primary hold must not toggle the panel")
    }

    @Test("Primary click keeps the status item highlighted while its panel is visible")
    func primaryStatusItemHighlightTracksPanelVisibility() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let statusItem = TestStatusItem()
        let controller = MenuBarPanelController(statusItem: statusItem)
        controller.presentsActively = false
        controller.install(with: store)
        defer { controller.uninstall() }
        let button = statusItem.testButton

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        #expect(button.cell?.isHighlighted == true)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible)
        #expect(button.cell?.isHighlighted == true)

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isPanelVisible == false)
        #expect(button.cell?.isHighlighted == false)
    }

    @Test("Primary long press stays highlighted until release")
    func primaryLongPressHighlightsUntilRelease() {
        let statusItem = TestStatusItem()
        let controller = MenuBarPanelController(statusItem: statusItem)
        let button = statusItem.testButton
        controller.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        #expect(button.cell?.isHighlighted == true)

        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)

        #expect(button.cell?.isHighlighted == false)
    }

    @Test("Secondary menu highlights while open and its closing right click leaves no highlight")
    func secondaryMenuHighlightTracksPresentation() {
        let statusItem = TestStatusItem()
        let controller = MenuBarPanelController(statusItem: statusItem)
        let button = statusItem.testButton
        var highlightedWhileMenuWasOpen = false
        var eventNumber: Int? = 100
        controller.statusItemEventNumber = { eventNumber }
        controller.statusContextMenuPresenter = { _ in
            highlightedWhileMenuWasOpen = button.cell?.isHighlighted == true
            eventNumber = 101
        }

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)

        #expect(highlightedWhileMenuWasOpen)
        #expect(button.cell?.isHighlighted == false)

        // The menu-bar host highlights the status button before dispatching the right click that
        // just dismissed the menu. The duplicate-suppression branch must release that highlight.
        button.highlight(true)
        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)

        #expect(button.cell?.isHighlighted == false)
    }

    @Test("Native status menu is attached before exactly one status-button click")
    func nativeStatusMenuUsesStatusItemPresentation() {
        let statusItem = TestStatusItem()
        let menu = NSMenu()
        var attachedMenuDuringClick: NSMenu?
        statusItem.testButton.onPerformClick = {
            attachedMenuDuringClick = statusItem.menu
        }

        MenuBarPanelController.presentStatusMenu(menu, on: statusItem)

        #expect(statusItem.testButton.performClickCount == 1)
        #expect(attachedMenuDuringClick === menu)
        #expect(statusItem.menu == nil)
    }

    @Test("Clearing the status-item highlight resets the AppKit button cell")
    func clearingStatusItemHighlightResetsButtonCell() {
        let button = NSButton()
        button.highlight(true)
        #expect(button.cell?.isHighlighted == true)

        MenuBarPanelController.clearStatusItemHighlight(on: button)

        #expect(button.cell?.isHighlighted == false)
    }

    @Test("Secondary click during a primary hold leaves release tracking active")
    func secondaryClickDuringPrimaryHoldKeepsReleaseTracking() {
        let controller = MenuBarPanelController()
        var presentedMenuCount = 0
        var toggleCount = 0
        controller.statusContextMenuPresenter = { _ in presentedMenuCount += 1 }
        controller.statusItemToggle = { toggleCount += 1 }

        controller.handleStatusItemNativeLongPressEvent(
            eventType: .leftMouseDown,
            pressedMouseButtons: 0x1
        )
        #expect(controller.isStatusItemPressActive)

        controller.handleStatusItemEvent(eventType: .rightMouseDown, pressedMouseButtons: 0x2)
        #expect(presentedMenuCount == 0, "a modal menu must not consume the hold's release")
        #expect(controller.isStatusItemPressActive)

        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(controller.isStatusItemPressActive == false)

        controller.handleStatusItemEvent(eventType: .leftMouseDown, pressedMouseButtons: 0x1)
        controller.handleStatusItemEvent(eventType: .leftMouseUp, pressedMouseButtons: 0)
        #expect(toggleCount == 1)
    }

    @Test("Secondary hit testing excludes the neighboring status item")
    func secondaryHitTestingExcludesNeighboringStatusItem() {
        let statusRect = NSRect(x: 100, y: 900, width: 80, height: 24)
        let inside = NSPoint(x: statusRect.maxX - 1, y: statusRect.midY)
        let neighboringPoint = NSPoint(x: statusRect.maxX + 3, y: statusRect.midY)

        #expect(MenuBarPanelController.isStatusItemHit(
            statusRect: statusRect,
            point: inside,
            eventType: .rightMouseDown
        ))
        #expect(MenuBarPanelController.isStatusItemHit(
            statusRect: statusRect,
            point: neighboringPoint,
            eventType: .rightMouseDown
        ) == false)
        #expect(MenuBarPanelController.isStatusItemHit(
            statusRect: statusRect,
            point: neighboringPoint,
            eventType: .leftMouseDown
        ))
    }

    @Test("Recreating the status item at launch finish keeps a single working item")
    func recoverStatusItemKeepsOneItem() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.recoverStatusItemIfNeeded()
        controller.recoverStatusItemIfNeeded()

        let item = try #require(controller.statusItem)
        #expect(item.button != nil)
        let expectedSymbol = SpeechInputController.shared.isListening ? "waveform" : store.menuBarSymbolName
        #expect(controller.labelSymbol == expectedSymbol)
    }

    @Test("Status item button carries the summary as tooltip and accessibility label")
    func statusItemShowsSummary() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let button = try #require(controller.statusItem?.button)
        controller.syncStatusItem()

        let summary = MenuBarStatusSummary.text(for: store)
        #expect(button.toolTip == summary)
        #expect(button.accessibilityLabel() == summary)
        let expectedTitle = try #require(store.menuBarText)
        #expect(button.attributedTitle.string.trimmingCharacters(in: .whitespaces) == expectedTitle)
    }

    @Test("Listening shows the waveform icon and the transcript instead of the store text")
    func listeningLabelMirrorsSpeech() async throws {
        let speech = SpeechInputController.shared
        let previousDraft = speech.draft
        let wasListening = speech.isListening
        let draft = "把书房的吸顶灯亮度调暗一点"
        speech.setPreviewState(isListening: true, isHoldToTalk: true, draft: draft)
        defer { speech.setPreviewState(isListening: wasListening, isHoldToTalk: false, draft: previousDraft) }

        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let button = try #require(controller.statusItem?.button)
        controller.syncStatusItem()

        // 13 characters: the button shows the last ten, as the SwiftUI label did.
        #expect(button.attributedTitle.string.trimmingCharacters(in: .whitespaces) == "的吸顶灯亮度调暗一点")
        #expect(controller.labelSymbol == "waveform")
    }

    @Test("Speech label trims whitespace and caps the transcript at ten characters")
    func speechLabelFormatting() {
        #expect(MenuBarPanelController.speechLabel("   ") == "聆听中…")
        #expect(MenuBarPanelController.speechLabel("开灯") == "开灯")
        // Twelve characters: only the last ten fit in the menu bar.
        #expect(MenuBarPanelController.speechLabel("一二三四五六七八九十十一") == "三四五六七八九十十一")
        #expect(MenuBarPanelController.speechLabel("  关灯  ") == "关灯")
    }

    @Test("statusBarImage loads house.slash and falls back when a symbol name is unknown")
    func statusBarImageFallback() {
        #expect(MenuBarPanelController.statusBarImage(symbolName: "house.slash") != nil)
        #expect(MenuBarPanelController.statusBarImage(symbolName: "nonexistent.symbol.for.test.181") != nil)
    }

    @Test("Showing the panel creates a key-capable 376 pt window and marks it visible")
    func showPanelCreatesVisibleWindow() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        var didShow = false
        let token = NotificationCenter.default.addObserver(
            forName: MenuBarPanelController.didShowNotification,
            object: nil,
            queue: nil
        ) { _ in
            didShow = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.showPanel()

        let panel = try #require(controller.panelWindow)
        #expect(controller.isPanelVisible)
        #expect(didShow)
        #expect(panel.isVisible)
        #expect(panel.canBecomeKey, "arrow keys and text fields need a key panel")
        #expect(panel.canBecomeMain == false)
        #expect(abs(panel.frame.width - MenuBarPanelController.panelWidth) < 1)
        #expect(panel.contentView is NSHostingView<ControlCenterPanel>)

        let expectedHeight = MenuBarPanelController.preferredContentSize().height
        #expect(abs(panel.frame.height - expectedHeight) < 1)
    }

    @Test("Hiding orders the window out, keeps the SwiftUI tree and posts the hide notification")
    func hidePanelKeepsContent() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView as? NSHostingView<ControlCenterPanel>)

        var didHide = false
        let token = NotificationCenter.default.addObserver(
            forName: MenuBarPanelController.didHideNotification,
            object: nil,
            queue: nil
        ) { _ in
            didHide = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.hidePanel()

        #expect(didHide)
        #expect(controller.isPanelVisible == false)
        #expect(panel.isVisible == false)
        #expect(panel.contentView === hosting, "the SwiftUI tree survives a close")
        #expect(controller.panelWindow === panel, "the window is reused, not recreated")
    }

    @Test("Toggle switches between visible and hidden while preserving the same SwiftUI tree")
    func toggleCyclesVisibility() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.togglePanel()
        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView as? NSHostingView<ControlCenterPanel>)
        #expect(controller.isPanelVisible)

        controller.togglePanel()
        #expect(controller.isPanelVisible == false)
        #expect(panel.contentView === hosting)

        controller.togglePanel()
        #expect(controller.isPanelVisible)
        #expect(panel.contentView === hosting)
    }

    @Test("An expired Mi session paints house.slash in the status item")
    func expiredMiSessionUsesSlashedIcon() async throws {
        let (store, suite) = try await makeExpiredMiSessionStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.syncStatusItem()

        let button = try #require(controller.statusItem?.button)
        #expect(store.menuBarSymbolName == "house.slash")
        #expect(controller.labelSymbol == "house.slash")
        #expect(button.image != nil, "the slashed-house symbol must exist on the deployment target")
    }

    @Test("The panel window is the only window recognised as the control center")
    func isPanelWindowMatchesOnlyThePanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { other.orderOut(nil) }

        let statusWindow = controller.statusItem?.button?.window
        #expect(controller.isPanelWindow(panel))
        #expect(controller.isPanelWindow(other) == false)
        #expect(controller.isPanelWindow(nil) == false)
        #expect(controller.isPanelWindow(statusWindow) == false, "the status item window is not the panel")
    }

    @Test("Panel tracks the panel-height preference and stays 376 wide")
    func panelSizingFollowsPreference() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let previous = UserDefaults.standard.string(forKey: PanelHeight.storageKey)
        UserDefaults.standard.set(PanelHeight.compact.rawValue, forKey: PanelHeight.storageKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: PanelHeight.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PanelHeight.storageKey)
            }
        }
        // The controller reads the preference through `UserDefaults.standard`, like the panel's
        // `@AppStorage`, so the window starts at the compact height.

        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)

        let compact = PanelHeight.compact.points
        let screenHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        // `preferredContentSize()` caps the preference to 24 pt below the visible frame.
        #expect(abs(panel.frame.height - min(compact, screenHeight - 24)) < 1)

        controller.updatePanelSize(width: MenuBarPanelController.panelWidth, height: 320)
        #expect(abs(panel.frame.height - 320) < 1)
        #expect(abs(panel.frame.width - MenuBarPanelController.panelWidth) < 1)
    }

    @Test("GrokBall sidecar stays outside the 376 pt panel and expands without changing it")
    func grokBallSidecarKeepsPanelWidthStable() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        #expect(store.enableGrokBall == false)
        controller.showPanel()
        #expect(controller.grokBallSidecarWindow?.isVisible == false)

        store.enableGrokBall = true
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let sidecar = try #require(controller.grokBallSidecarWindow)
        #expect(abs(panel.frame.width - 376) < 1)
        #expect(abs(sidecar.frame.width - GrokBallSidecarPlacement.collapsedWidth) < 1)
        #expect(sidecar.frame.minX >= panel.frame.maxX || sidecar.frame.maxX <= panel.frame.minX)
        #expect(controller.isPanelWindow(sidecar))

        let initialFrame = panel.frame
        store.toggleGrokBallStage()
        controller.showPanel()
        #expect(abs(panel.frame.width - 376) < 1)
        #expect(panel.frame == initialFrame)
        #expect(abs(sidecar.frame.width - GrokBallSidecarPlacement.expandedWidth) < 1)
        #expect(sidecar.frame.height >= GrokBallSidecarPlacement.expandedHeight - 1)

        controller.hidePanel()
        #expect(sidecar.isVisible == false)
        #expect(store.isGrokBallStageExpanded == false)
    }

    @Test("Expanded sidecar chooses the far edge and flips when the right side cannot fit")
    func grokBallSidecarFlipsAtScreenEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let rightParent = NSRect(x: 300, y: 300, width: 376, height: 420)
        let right = GrokBallSidecarPlacement.resolve(parent: rightParent, visible: visible, expanded: true)
        #expect(right.side == .right)
        #expect(right.frame.minX >= rightParent.maxX)

        let edgeParent = NSRect(x: 600, y: 300, width: 376, height: 420)
        let left = GrokBallSidecarPlacement.resolve(parent: edgeParent, visible: visible, expanded: true)
        #expect(left.side == .left)
        #expect(left.frame.maxX <= edgeParent.minX)

        for parent in [rightParent, edgeParent] {
            let collapsed = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: false)
            let expanded = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: true)
            #expect(collapsed.side == expanded.side)
            #expect(collapsed.frame.maxY == expanded.frame.maxY)
            let collapsedBallX = collapsed.side == .right ? collapsed.frame.minX + 42 : collapsed.frame.maxX - 42
            let expandedBallX = expanded.side == .right ? expanded.frame.minX + 42 : expanded.frame.maxX - 42
            #expect(collapsedBallX == expandedBallX)
            #expect(expanded.frame.minX >= visible.minX)
            #expect(expanded.frame.maxX <= visible.maxX)
            #expect(expanded.frame.minY >= visible.minY)
        }
    }

    @Test("Sidecar key status and clicks belong to the dashboard; an outside click closes both")
    func grokBallSidecarOutsideClickAndKeyOwnership() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let sidecar = try #require(controller.grokBallSidecarWindow)
        controller.handleOtherWindowBecameKey(sidecar)
        #expect(controller.isPanelVisible)
        let center = NSPoint(x: sidecar.frame.midX, y: sidecar.frame.midY)
        controller.handleMouseDown(in: sidecar, at: center)
        controller.handleMouseDown(in: nil, at: center)
        #expect(controller.isPanelVisible)
        controller.handleMouseDown(in: nil, at: NSPoint(x: -10_000, y: -10_000))
        #expect(controller.isPanelVisible == false)
        #expect(sidecar.isVisible == false)
    }

    @Test("Escape in the sidecar collapses suggestions first, then closes the dashboard")
    func grokBallSidecarEscapeClosesInOrder() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let sidecar = try #require(controller.grokBallSidecarWindow)
        store.toggleGrokBallStage()
        sidecar.cancelOperation(nil)
        #expect(store.isGrokBallStageExpanded == false)
        #expect(controller.isPanelVisible)
        sidecar.cancelOperation(nil)
        #expect(controller.isPanelVisible == false)
        #expect(sidecar.isVisible == false)

        controller.uninstall()
        #expect(controller.grokBallSidecarWindow == nil)
        #expect(sidecar.parent == nil)
        #expect(sidecar.contentView == nil)
    }

    @Test("Moving and resizing the parent keeps the side attachment aligned")
    func grokBallSidecarFollowsParentGeometry() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let sidecar = try #require(controller.grokBallSidecarWindow)
        let visible = try #require(panel.screen?.visibleFrame)
        store.toggleGrokBallStage()
        let movedFrame = NSRect(x: visible.minX + 20, y: visible.minY + 20, width: 376, height: 320)
        panel.setFrame(movedFrame, display: true)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: panel)
        let expected = GrokBallSidecarPlacement.resolve(parent: panel.frame, visible: visible, expanded: true)
        #expect(sidecar.frame == expected.frame)
        #expect(panel.frame.width == 376)
    }

    @Test("The English empty-state message fits the shallow recommendation row")
    func grokBallEnglishEmptyStateFitsShallowRow() throws {
        _ = NSApplication.shared
        let suite = "test.empty.ball.\(UUID().uuidString)"
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try #require(store.grokBallRadialSuggestions.isEmpty)
        L10n.$overrideLanguage.withValue(.en) {
            let hosting = NSHostingView(rootView: GrokBallSuggestions(store: store, columnCount: 4).body)
            hosting.frame = NSRect(x: 0, y: 0, width: 558, height: 44)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height <= 44)
        }
    }

    @Test("A shallow bottom gap keeps all four suggestions below the ball when a row fits")
    func grokBallUsesShallowBottomSpace() throws {
        let parent = NSRect(x: 312, y: 200, width: 376, height: 420)
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let center = NSPoint(x: 500, y: 135)
        let placement = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: true, ballCenter: center)
        let pills = try #require(placement.suggestionsFrame)
        #expect(placement.side == .below)
        #expect(pills.maxY < center.y - 36)
        #expect(visible.contains(placement.frame))
        #expect(!pills.intersects(parent))
    }

    @Test("Recommendations follow the ball outward on all four sides without moving its anchor")
    func grokBallSuggestionsFollowFreePlacement() throws {
        let parent = NSRect(x: 650, y: 600, width: 376, height: 420)
        let visible = NSRect(x: 0, y: 0, width: 2000, height: 1800)
        let cases: [(NSPoint, GrokBallSidecarPlacement.Side)] = [
            (NSPoint(x: 540, y: 810), .left), (NSPoint(x: 1130, y: 810), .right),
            (NSPoint(x: 838, y: 500), .below), (NSPoint(x: 838, y: 1120), .above),
        ]
        for (center, direction) in cases {
            let closed = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: false, ballCenter: center)
            let open = GrokBallSidecarPlacement.resolve(parent: parent, visible: visible, expanded: true, ballCenter: center)
            let pills = try #require(open.suggestionsFrame)
            #expect(open.side == direction)
            #expect(open.ballCenter == closed.ballCenter)
            #expect(visible.contains(open.frame))
            #expect(!pills.intersects(parent))
            switch direction {
            case .left: #expect(pills.maxX < center.x - 36)
            case .right: #expect(pills.minX > center.x + 36)
            case .above: #expect(pills.minY > center.y + 36)
            case .below: #expect(pills.maxY < center.y - 36)
            }
        }
    }

    @Test("Dragging the ball moves it freely without clicking or starting voice, and pills follow its side")
    func grokBallDragsWithoutActivating() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let sidecar = try #require(controller.grokBallSidecarWindow)
        let visible = try #require(panel.screen?.visibleFrame)
        panel.setFrame(NSRect(x: visible.midX - 188, y: visible.minY + 240, width: 376, height: 320), display: true)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        let mainFrame = panel.frame
        store.isShowingAssistantBar = false
        var origin = NSPoint(x: sidecar.frame.midX, y: sidecar.frame.midY)
        let left = NSPoint(x: mainFrame.minX - 70, y: mainFrame.midY)
        sendBallMouse(.leftMouseDown, at: origin, window: sidecar)
        sendBallMouse(.leftMouseDragged, at: left, window: sidecar)
        sendBallMouse(.leftMouseUp, at: left, window: sidecar)
        #expect(abs(sidecar.frame.midX - left.x) < 1)
        #expect(abs(sidecar.frame.midY - left.y) < 1)
        #expect(!store.isGrokBallStageExpanded)
        #expect(!store.isShowingAssistantBar)
        sendBallMouse(.leftMouseDown, at: left, window: sidecar)
        sendBallMouse(.leftMouseUp, at: left, window: sidecar)
        #expect(store.isGrokBallStageExpanded)
        #expect(sidecar.frame.maxX < mainFrame.minX)
        origin = left
        let below = NSPoint(x: mainFrame.midX, y: mainFrame.minY - 65)
        sendBallMouse(.leftMouseDown, at: origin, window: sidecar)
        sendBallMouse(.leftMouseDragged, at: below, window: sidecar)
        sendBallMouse(.leftMouseUp, at: below, window: sidecar)
        sendBallMouse(.leftMouseDown, at: below, window: sidecar)
        sendBallMouse(.leftMouseUp, at: below, window: sidecar)
        #expect(store.isGrokBallStageExpanded)
        #expect(sidecar.frame.maxY < mainFrame.minY)
        #expect(panel.frame == mainFrame)
    }

    @Test("Holding the ball enters voice without also toggling suggestions")
    func grokBallHoldStartsVoiceOnly() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.enableGrokBall = true
        let speech = SpeechInputController.shared
        let controller = makeController(store: store)
        defer { speech.stop(andSubmit: false, store: nil); controller.uninstall() }
        controller.showPanel()
        let sidecar = try #require(controller.grokBallSidecarWindow)
        let point = NSPoint(x: sidecar.frame.midX, y: sidecar.frame.midY)
        store.isShowingAssistantBar = false
        sendBallMouse(.leftMouseDown, at: point, window: sidecar)
        for _ in 0..<250 where !store.isShowingAssistantBar { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.isShowingAssistantBar)
        #expect(speech.isHoldToTalk)
        #expect(!store.isGrokBallStageExpanded)
        sendBallMouse(.leftMouseUp, at: point, window: sidecar)
        for _ in 0..<250 where speech.isHoldToTalk { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!speech.isHoldToTalk)
        #expect(!store.isGrokBallStageExpanded)
    }

    private func sendBallMouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        NSApp.sendEvent(event)
    }

    @Test("Sizing while the panel is closed does not create a window")
    func sizingBeforeOpenIsIgnored() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.updatePanelSize(width: MenuBarPanelController.panelWidth, height: 420)
        #expect(controller.panelWindow == nil)
    }

    @Test("The panel is placed under the menu bar of its screen and clamped on screen")
    func panelIsPositionedUnderTheMenuBar() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame

        if let visible {
            #expect(panel.frame.maxY <= visible.maxY + 1, "never above the visible frame")
            #expect(panel.frame.minY >= visible.minY - 1, "never below the screen")
            #expect(panel.frame.minX >= visible.minX - 1)
            #expect(panel.frame.maxX <= visible.maxX + 1)
        }
    }

    @Test("Another window taking key status closes the panel; the panel and its own children do not")
    func otherWindowBecameKeyClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)

        controller.handleOtherWindowBecameKey(panel)
        #expect(controller.isPanelVisible, "the panel itself is not 'another window'")

        // A context menu or sheet the panel spawned keeps it open.
        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { child.orderOut(nil) }
        panel.addChildWindow(child, ordered: .above)
        #expect(controller.isPanelWindow(child))
        controller.handleOtherWindowBecameKey(child)
        #expect(controller.isPanelVisible, "a panel-owned window must not dismiss the panel")

        let settingsLike = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { settingsLike.orderOut(nil) }

        controller.handleOtherWindowBecameKey(settingsLike)
        #expect(controller.isPanelVisible == false)
    }

    @Test("An outside mouse click closes the panel without an application deactivation")
    func outsideMouseClickClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let outside = NSPoint(x: panel.frame.minX - 20, y: panel.frame.midY)
        controller.handleMouseDown(in: panel, at: panel.frame.origin)
        #expect(controller.isPanelVisible, "panel controls keep working")
        if let button = controller.statusItem?.button, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            controller.handleMouseDown(in: window, at: NSPoint(x: frame.midX, y: frame.midY))
            #expect(controller.isPanelVisible, "the status button must toggle on release")
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: outside, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        NSApp.sendEvent(event)

        #expect(!controller.isPanelVisible)
        #expect(!store.pollingContext.panelVisible)

        controller.showPanel()
        NSApp.sendEvent(event)
        #expect(!controller.isPanelVisible, "outside clicks still work after reopening")
    }

    @Test("Losing key status to another app closes the panel, but dictation keeps it")
    func appDeactivationClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        #expect(controller.isPanelVisible)

        let speech = SpeechInputController.shared
        let previousDraft = speech.draft
        let wasListening = speech.isListening
        speech.setPreviewState(isListening: true, isHoldToTalk: true, draft: "开灯")
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible, "a TCC prompt must not close the panel mid-dictation")

        speech.setPreviewState(isListening: wasListening, isHoldToTalk: false, draft: previousDraft)
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible == false)
    }

    @Test("Showing the panel reports panel visibility to the store so polling can follow it")
    func showAndHideUpdatePollingContext() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        #expect(store.pollingContext.panelVisible)
        controller.hidePanel()
        #expect(store.pollingContext.panelVisible == false)
    }

    @Test("Keyboard shortcuts only take over inside the panel window")
    func keyboardHandlingIsPanelScoped() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        #expect(panel.canBecomeKey)
        #expect(controller.isPanelWindow(panel))
        // Settings is a different window, so ⌘,-style AppKit handling stays untouched there.
        #expect(controller.isPanelWindow(NSApp.keyWindow) == (NSApp.keyWindow === panel))
    }

    @Test("Dark appearance renders a dark panel background instead of light material")
    func classicDarkModeRendersDarkBackground() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let prevAppearance = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        defer {
            if let prevAppearance { UserDefaults.standard.set(prevAppearance, forKey: AppAppearance.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppAppearance.storageKey) }
        }

        UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: AppAppearance.storageKey)

        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()

        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView)
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        panel.displayIfNeeded()

        let size = hosting.bounds.size
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        // Sample background pixel in the outer top-left padding (x: 10, y: 6) where no header views render.
        let bgColor = try #require(bitmap.colorAt(x: 10, y: 6)?.usingColorSpace(.deviceRGB))
        let luminance = 0.2126 * bgColor.redComponent + 0.7152 * bgColor.greenComponent + 0.0722 * bgColor.blueComponent
        let effectiveName = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        #expect(effectiveName == .darkAqua)
        #expect(luminance < 0.35, "Classic dark mode panel background should be dark, got luminance \(luminance)")

        // Switching to forced light updates the panel's appearance right away.
        UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppAppearance.storageKey)
        controller.handlePreferencesChanged()
        #expect(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    @Test("Short global hotkey press toggles the panel; holding opens voice assistant without closing on release")
    func globalHotkeyShortPressAndLongHoldVoice() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        _ = NSApplication.shared
        let sharedController = MenuBarPanelController.shared
        let prevPresentsActively = sharedController.presentsActively
        sharedController.presentsActively = false
        sharedController.install(with: store)
        HotkeyAndNotificationManager.shared.attachStoreForTesting(store)
        defer {
            HotkeyAndNotificationManager.shared.attachStoreForTesting(nil)
            SpeechInputController.shared.stop(andSubmit: false, store: nil)
            SpeechInputController.shared.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
            sharedController.uninstall()
            sharedController.presentsActively = prevPresentsActively
        }

        // 1. Short tap (< threshold): toggles the panel open on release, without opening the voice bar.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.3)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered == false)
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown == false)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar == false)

        // Second short tap closes the panel.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.3)
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(sharedController.isPanelVisible == false)

        // 2. Long hold (>= threshold): opens the panel, presents the assistant bar, and starts Hold-to-Talk.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.03)
        try await Task.sleep(for: .milliseconds(70))
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar)
        #expect(SpeechInputController.shared.isHoldToTalk)

        // Releasing after a long hold finishes Hold-to-Talk instead of toggling the panel closed.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown == false)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered == false)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar)
    }

    @Test("Status item native long press opens voice assistant and suppresses trailing synthetic click")
    func statusItemLongPressOpensVoiceAndSuppressesTrailingClick() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let controller = makeController(store: store)
        defer {
            SpeechInputController.shared.stop(andSubmit: false, store: nil)
            SpeechInputController.shared.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
            controller.uninstall()
        }

        let item = try #require(controller.statusItem)
        if let targetIvar = class_getInstanceVariable(NSStatusItem.self, "_target") {
            let rawTarget = object_getIvar(item, targetIvar) as AnyObject?
            #expect(rawTarget === controller, "NSStatusItem->_target ivar must be set directly for _performSecondaryAction:type:")
        }
        let getLongSel = NSSelectorFromString("longPressAction")
        if item.responds(to: getLongSel),
           let method = class_getInstanceMethod(type(of: item), getLongSel) {
            typealias GetSelFn = @convention(c) (AnyObject, Selector) -> Selector?
            let imp = unsafeBitCast(method_getImplementation(method), to: GetSelFn.self)
            #expect(imp(item, getLongSel) == #selector(MenuBarPanelController.handleStatusItemNativeLongPress(_:)))
        }

        // Simulate macOS 26+ out-of-process menu bar secondary action (type 0 = long press on status item)
        let secondarySel = NSSelectorFromString("_performSecondaryAction:type:")
        if item.responds(to: secondarySel),
           let method = class_getInstanceMethod(type(of: item), secondarySel) {
            typealias PerformSecondaryFn = @convention(c) (AnyObject, Selector, AnyObject?, Int) -> Void
            let imp = unsafeBitCast(method_getImplementation(method), to: PerformSecondaryFn.self)
            imp(item, secondarySel, nil, 0)
        } else {
            controller.handleStatusItemNativeLongPress(item)
        }
        #expect(controller.isPanelVisible)
        #expect(store.isShowingAssistantBar)

        // A trailing synthetic click delivered right after releasing a long press must not close the panel
        controller.handleStatusItemPress()
        #expect(controller.isPanelVisible)
        #expect(store.isShowingAssistantBar)
    }

    @Test("Horizontal wheel monitor translates vertical mouse wheel and trackpad deltas into clamped horizontal scroll")
    func horizontalWheelMonitorScrollsAndClamps() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        scrollView.documentView = documentView

        // Rolling the mouse wheel down (negative deltaY) moves the horizontal strip right.
        let movedRight = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -2,
            hasPreciseDeltas: false
        )
        #expect(movedRight)
        #expect(scrollView.contentView.bounds.origin.x == 32)

        // Trackpad horizontal swipe right-to-left (negative deltaX) advances by exact points.
        let movedPrecise = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: -48,
            deltaY: -4,
            hasPreciseDeltas: true
        )
        #expect(movedPrecise)
        #expect(scrollView.contentView.bounds.origin.x == 80)

        // Clamps at maxOffsetX (640 - 240 = 400) and back at 0.
        _ = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -1000,
            hasPreciseDeltas: true
        )
        #expect(scrollView.contentView.bounds.origin.x == 400)

        _ = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: 1000,
            hasPreciseDeltas: true
        )
        #expect(scrollView.contentView.bounds.origin.x == 0)

        // Non-overflowing strip does not scroll.
        documentView.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        let movedWhenFitting = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -3,
            hasPreciseDeltas: false
        )
        #expect(!movedWhenFitting)
    }

    @Test("Room strip scrolls hidden rooms into view when selected or cycled")
    func classicSkinRoomStripScrollsToSelectedRoom() async throws {
        let rooms = [
            RoomArea(id: "r1", name: "书房", sortOrder: 0),
            RoomArea(id: "r2", name: "办公室", sortOrder: 1),
            RoomArea(id: "r3", name: "卧室", sortOrder: 2),
            RoomArea(id: "r4", name: "厨房", sortOrder: 3),
            RoomArea(id: "r5", name: "客厅", sortOrder: 4),
            RoomArea(id: "r6", name: "阳台", sortOrder: 5),
            RoomArea(id: "r7", name: "次卧", sortOrder: 6),
            RoomArea(id: "r8", name: "卫生间", sortOrder: 7)
        ]
        var base = DemoHomeProvider.defaultHome()
        base.rooms = rooms
        base.environmentReadings = []
        base.scenes = []

        let suite = "MenuBarPanelTests-rooms-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")
        defaults.set(false, forKey: "show_quick_actions_bar")

        let store = HomeStore(provider: MockHomeProvider(snapshot: base), defaultsSuiteName: suite)
        for _ in 0..<50 where store.rooms.count < rooms.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.rooms.count == rooms.count)

        let hosting = NSHostingView(
            rootView: ControlCenterPanel(store: store)
                .defaultAppStorage(defaults)
                .environment(\.reduceMotionOverride, true)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 376, height: 560)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        Self.pumpMainRunLoop()

        func findRoomScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView,
               let doc = sv.documentView,
               doc.bounds.width > sv.contentView.bounds.width + 20,
               sv.frame.height < 60 {
                return sv
            }
            for sub in view.subviews {
                if let found = findRoomScrollView(in: sub) {
                    return found
                }
            }
            return nil
        }

        let roomScrollView = try #require(findRoomScrollView(in: hosting))
        #expect(roomScrollView.contentView.bounds.origin.x < 1)

        store.selectRoom("r8")
        try await Task.sleep(for: .milliseconds(80))
        Self.pumpMainRunLoop()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        #expect(roomScrollView.contentView.bounds.origin.x > 40)

        store.selectRoom(nil)
        try await Task.sleep(for: .milliseconds(80))
        Self.pumpMainRunLoop()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        #expect(roomScrollView.contentView.bounds.origin.x < 1)
    }

    @Test("CameraLivePanelController attaches NSHostingView contentView and elevates above MenuBarPanel")
    func cameraLivePanelAttachesHostingViewAndOrdersAboveMenuBarPanel() async throws {
        let suite = "MenuBarPanelTests-camera-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer { cameraController.closePanel() }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)
        #expect(panel.isVisible)
        #expect(panel.contentView is NSHostingView<CameraLivePanelView>, "NSPanel initializes with a blank NSView; present(device:) must replace it with NSHostingView<CameraLivePanelView>")
        #expect(panel.level.rawValue > NSWindow.Level.statusBar.rawValue)
    }

    @Test("Closing the camera mini-window hides it at once and releases the stream")
    func cameraLivePanelCloseReleasesStreamImmediately() async throws {
        _ = NSApplication.shared
        let suite = "MenuBarPanelTests-camera-close-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer { cameraController.closePanel() }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)
        #expect(panel.isVisible)
        #expect(panel.canBecomeKey)

        panel.cancelOperation(nil)
        #expect(cameraController.isVisible == false)
        #expect(cameraController.videoPlayer == nil)

        var stopped = false
        for _ in 0..<40 {
            if await mock.stoppedCameraIDs.contains(camera.id) {
                stopped = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(stopped)
    }

    @Test("Picture in Picture reports a valid endless live time range")
    func cameraPictureInPictureLiveRangeIsValid() {
        let range = CameraPictureInPicture.livePlaybackTimeRange()
        #expect(range.isValid)
        #expect(range.duration.isPositiveInfinity)
    }


    @Test("TileResizeGestureMath maps 30pt horizontal and vertical translations across half, full, and panel (#115)")
    func tileResizeGestureMathThresholds() {
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 30, height: 30), isCompactGrid: true) == .half)
        #expect(TileResizeGestureMath.targetSize(startSize: .full, translation: CGSize(width: -30, height: -30), isCompactGrid: true) == .full)

        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 31, height: 0), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 0, height: 31), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 60, height: 60), isCompactGrid: true) == .panel)
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 65, height: 0), isCompactGrid: true) == .panel)
        #expect(TileResizeGestureMath.targetSize(startSize: .half, translation: CGSize(width: 0, height: 65), isCompactGrid: true) == .panel)

        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: -31, height: 0), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: 0, height: -31), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: -60, height: -60), isCompactGrid: true) == .half)
        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: -65, height: 0), isCompactGrid: true) == .half)
        #expect(TileResizeGestureMath.targetSize(startSize: .panel, translation: CGSize(width: 0, height: -65), isCompactGrid: true) == .half)

        #expect(TileResizeGestureMath.targetSize(startSize: .auto, translation: CGSize(width: 50, height: 0), isCompactGrid: true) == .full)
        #expect(TileResizeGestureMath.targetSize(startSize: .auto, translation: CGSize(width: 50, height: 0), isCompactGrid: false) == .panel)
        #expect(TileResizeGestureMath.targetSize(startSize: .auto, translation: CGSize(width: -50, height: 0), isCompactGrid: false) == .half)
    }

    @Test("TileResizeGestureMath computes release velocity from the last 100ms and projects a flick onto at most one step (#115)")
    func tileResizeGestureMathFlickProjection() {
        let now: TimeInterval = 100
        let fast = [
            TileResizeGestureMath.ResizeSample(offset: .zero, time: now - 0.08),
            TileResizeGestureMath.ResizeSample(offset: CGSize(width: 24, height: 16), time: now),
        ]
        let velocity = TileResizeGestureMath.releaseVelocity(fast, now: now)
        #expect(abs(velocity.width - 300) < 1)
        #expect(abs(velocity.height - 200) < 1)

        // A rested pointer yields no velocity, so a stationary release cannot fling.
        let rested = [
            TileResizeGestureMath.ResizeSample(offset: CGSize(width: 20, height: 10), time: now - 0.5),
            TileResizeGestureMath.ResizeSample(offset: CGSize(width: 20, height: 10), time: now - 0.4),
        ]
        #expect(TileResizeGestureMath.releaseVelocity(rested, now: now) == .zero)

        // Projection clamps to the threshold per axis: a 300pt/s flick adds ~one step.
        let projection = TileResizeGestureMath.projectedOffset(velocity: velocity)
        #expect(abs(projection.width - 29.7) < 0.001)
        #expect(abs(projection.height - 19.8) < 0.001)

        // A short sub-threshold drag plus its flick crosses the step at release.
        let shortDrag = TileResizeGestureMath.targetSize(
            startSize: .half,
            translation: CGSize(width: 20 + projection.width, height: 0),
            isCompactGrid: true
        )
        #expect(shortDrag == .full)

        // A slow drag projects nothing extra.
        let slow = TileResizeGestureMath.projectedOffset(velocity: CGSize(width: 100, height: -100))
        #expect(abs(slow.width - 9.9) < 0.001)
        #expect(abs(slow.height + 9.9) < 0.001)
    }

    @Test("Long-pressing a light card enters edit mode and bottom-right corner arc handle supports both drag resizing and tap cycling without reordering (#115)")
    func longPressOnLightCardEntersEditModeWithoutExpandingAndCyclesTileSizes() async throws {
        _ = NSApplication.shared
        let previousLanguage = L10n.currentLanguage
        L10n.currentLanguage = .zhHans
        let previousAppearance = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)

        let suite = "MenuBarPanelTests-resize-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            L10n.currentLanguage = previousLanguage
            if let previousAppearance {
                UserDefaults.standard.set(previousAppearance, forKey: AppAppearance.storageKey)
            }
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(AppLanguagePreference.zhHans.rawValue, forKey: "app_language")
        defaults.set(TemperatureUnitPreference.celsius.rawValue, forKey: TemperatureUnitPreference.storageKey)
        defaults.set(false, forKey: "show_quick_actions_bar")
        defaults.set(false, forKey: "automatically_checks_for_updates")
        defaults.set(true, forKey: "compact_grid_mode")

        let store = HomeStore(
            provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome(includeCamera: false)),
            defaultsSuiteName: suite
        )
        for _ in 0..<200 where store.devices.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let light = try #require(store.devices.first { dev in
            if case .light = dev.kind { return true }
            return false
        })
        let initialIsOn = light.isActiveOn

        let hosting = NSHostingView(
            rootView: ControlCenterPanel(store: store)
                .defaultAppStorage(defaults)
                .environment(\.reduceMotionOverride, true)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 376, height: 560)
        LayoutUIState.shared.cardGlobalFrames.removeAll()
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 120, width: 376, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        Self.pumpMainRunLoop()
        let card = try #require(LayoutUIState.shared.cardGlobalFrames[light.id])

        func sendMouse(_ type: NSEvent.EventType, at point: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return }
            NSApp.sendEvent(event)
        }

        // Long-press the card body. The kind row shifts the first card, so a fixed window point misses it.
        let longPressPoint = NSPoint(x: card.minX + 28, y: hosting.bounds.height - card.midY)
        sendMouse(.leftMouseDown, at: longPressPoint)
        try await Task.sleep(for: .milliseconds(550))
        Self.pumpMainRunLoop()
        sendMouse(.leftMouseUp, at: longPressPoint)
        try await Task.sleep(for: .milliseconds(150))
        Self.pumpMainRunLoop()

        #expect(store.expandedDeviceId == nil, "Releasing long-press must not trigger the card's expand-drawer button")
        #expect(store.devices.first(where: { $0.id == light.id })?.isActiveOn == initialIsOn)

        func handlePoint() -> NSPoint {
            if let g = LayoutUIState.shared.cardGlobalFrames[light.id] {
                return NSPoint(x: g.maxX - 6, y: hosting.bounds.height - g.maxY + 6)
            }
            return NSPoint(x: 176, y: 358)
        }
        func currentSizes() -> [String: TileSize] {
            DeviceLayoutPrefs.decode(defaults.string(forKey: DeviceLayoutPrefs.storageKey) ?? "{}")
        }
        func flushLayout() async throws {
            try await Task.sleep(for: .milliseconds(160))
            Self.pumpMainRunLoop()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            window.displayIfNeeded()
            Self.pumpMainRunLoop()
        }

        // 1. Outward drag on bottom-right corner arc handle: half -> full -> panel without reordering.
        let dragOutStart = handlePoint()
        sendMouse(.leftMouseDown, at: dragOutStart)
        try await Task.sleep(for: .milliseconds(30))
        Self.pumpMainRunLoop()

        let dragOutStep1 = NSPoint(x: dragOutStart.x + 60, y: dragOutStart.y)
        sendMouse(.leftMouseDragged, at: dragOutStep1)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .full, "Dragging handle right > 45pt must step half -> full")

        let dragOutStep2 = NSPoint(x: dragOutStart.x + 60, y: dragOutStart.y - 60)
        sendMouse(.leftMouseDragged, at: dragOutStep2)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .panel, "Continuing drag down > 45pt must step full -> panel")

        sendMouse(.leftMouseUp, at: dragOutStep2)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .panel)
        #expect(DeviceLayoutPrefs.decodeOrder(defaults.string(forKey: DeviceLayoutPrefs.orderKey) ?? "[]").isEmpty, "Handle drag must not trigger card reordering")

        // 2. Inward drag on bottom-right corner arc handle: panel -> full -> half without reordering.
        let dragInStart = handlePoint()
        sendMouse(.leftMouseDown, at: dragInStart)
        try await Task.sleep(for: .milliseconds(30))
        Self.pumpMainRunLoop()

        let dragInStep1 = NSPoint(x: dragInStart.x - 60, y: dragInStart.y)
        sendMouse(.leftMouseDragged, at: dragInStep1)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .full, "Dragging handle left < -45pt must step panel -> full")

        let dragInStep2 = NSPoint(x: dragInStart.x - 60, y: dragInStart.y + 60)
        sendMouse(.leftMouseDragged, at: dragInStep2)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .half, "Continuing drag up < -45pt must step full -> half")

        sendMouse(.leftMouseUp, at: dragInStep2)
        try await flushLayout()
        #expect(currentSizes()["all|\(light.id)"] == .half)
        #expect(DeviceLayoutPrefs.decodeOrder(defaults.string(forKey: DeviceLayoutPrefs.orderKey) ?? "[]").isEmpty, "Inward handle drag must not trigger card reordering")

        // 3. Light tap on bottom-right corner arc handle still cycles half -> full -> panel -> half.
        func tapHandle() async throws -> [String: TileSize] {
            let point = handlePoint()
            sendMouse(.leftMouseDown, at: point)
            try await Task.sleep(for: .milliseconds(40))
            Self.pumpMainRunLoop()
            sendMouse(.leftMouseUp, at: point)
            try await flushLayout()
            return currentSizes()
        }

        let sizes1 = try await tapHandle()
        #expect(sizes1["all|\(light.id)"] == .full)

        let sizes2 = try await tapHandle()
        #expect(sizes2["all|\(light.id)"] == .panel)

        let sizes3 = try await tapHandle()
        #expect(sizes3["all|\(light.id)"] == .half)
    }

    private static func pumpMainRunLoop(_ seconds: TimeInterval = 0.05) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }
}
