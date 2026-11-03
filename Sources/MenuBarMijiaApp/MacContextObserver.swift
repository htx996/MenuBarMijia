import AppKit
import CoreAudio
import CoreGraphics
import CoreLocation
import CoreMediaIO
import CoreWLAN
import EventKit
import Foundation
import Intents
import IOKit.ps
import MijiaCore

// MARK: - Mac Context Observation (#174)

/// Injectable seam so `AutomationEngine` can be driven with deterministic snapshots in tests.
@MainActor
protocol MacContextProviding: AnyObject {
    func start(_ handler: @escaping @MainActor (MacContextSnapshot, Date) async -> Void)
    func stop()
}

/// Polls the public, permission-respecting Mac APIs behind the #174 triggers.
///
/// Signal sources and limits:
/// - Camera: CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` (no TCC prompt).
/// - Microphone: CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on input devices
///   (no TCC prompt; the microphone usage description is only for recording).
/// - Power/battery: IOKit.ps.
/// - Wi-Fi SSID: CoreWLAN. macOS hides the SSID unless Location permission is granted; without it
///   `isWiFiAuthorized` is false and Wi-Fi rules cannot fire.
/// - Focus: Intents `INFocusStatusCenter`. Requires Focus-status permission and only exposes
///   whether *some* Focus is active, not which one.
/// - Calendar: EventKit full access, queried at most every 30 s for events starting within the
///   next hour. All-day and declined events are ignored.
///
/// Polling (10 s) is deliberate: these APIs have no complete public notification set, and a stale
/// snapshot would make camera/AC/Wi-Fi transitions unreliable. The work is small and runs on the
/// main run loop.
@MainActor
final class MacContextObserver: MacContextProviding {
    private var handler: (@MainActor (MacContextSnapshot, Date) async -> Void)?
    private var timer: Timer?
    private var lastCalendarQuery = Date.distantPast
    private var cachedMeetings: [CalendarMeeting] = []
    private let eventStore = EKEventStore()
    private let locationManager = CLLocationManager()
    private static let refreshInterval: TimeInterval = 10
    private static let calendarQueryInterval: TimeInterval = 30
    private static let calendarLookahead: TimeInterval = 60 * 60

    func start(_ handler: @escaping @MainActor (MacContextSnapshot, Date) async -> Void) {
        self.handler = handler
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
    }

    private func tick() {
        let now = Date()
        let (powerSource, batteryPercent) = Self.readPowerState()
        let snapshot = MacContextSnapshot(
            cameraInUse: Self.cameraInUse(),
            microphoneInUse: Self.microphoneInUse(),
            powerSource: powerSource,
            batteryPercent: batteryPercent,
            wifiSSID: wifiSSID(),
            isWiFiAuthorized: isWiFiAuthorized,
            isFocusActive: focusActive(),
            isUserPresent: CGDisplayIsAsleep(CGMainDisplayID()) == 0,
            meetings: calendarMeetings(now: now)
        )
        guard let handler else { return }
        Task { @MainActor in
            await handler(snapshot, now)
        }
    }

    // MARK: - Power

    /// Internal (not private) so the observer smoke test exercises the real IOKit ownership path.
    static func readPowerState() -> (MacPowerSource, Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return (.unknown, nil)
        }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let source: MacPowerSource
        switch type {
        case kIOPSACPowerValue:
            source = .ac
        case kIOPSBatteryPowerValue:
            source = .battery
        default:
            source = .unknown
        }

        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for powerSource in list {
                guard let description = IOPSGetPowerSourceDescription(blob, powerSource)?
                    .takeUnretainedValue() as? [String: Any],
                    description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                else { continue }
                guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int,
                      maximum > 0 else { continue }
                percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            }
        }
        return (source, percent)
    }

    // MARK: - Camera (CoreMediaIO)

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return false }
        let capacity = Int(size) / MemoryLayout<CMIOObjectID>.size
        guard capacity > 0 else { return false }

        var devices = [CMIOObjectID](repeating: 0, count: capacity)
        var used: UInt32 = 0
        let status = devices.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address,
                0,
                nil,
                size,
                &used,
                buffer.baseAddress
            )
        }
        guard status == noErr else { return false }
        let count = min(capacity, Int(used) / MemoryLayout<CMIOObjectID>.size)
        return devices.prefix(count).contains { isRunningSomewhere($0) }
    }

    /// `kCMIODevicePropertyDeviceIsRunningSomewhere` is true when any process (including this one)
    /// has the device open, which is exactly the “camera in use” signal. It needs no TCC grant.
    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(device, &address, 0, nil, size, &size, &running) == noErr
            && running != 0
    }

    // MARK: - Microphone (CoreAudio)

    private static func microphoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return false }
        let capacity = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard capacity > 0 else { return false }

        var devices = [AudioDeviceID](repeating: 0, count: capacity)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return false }
        return devices.contains { device in
            hasInputChannels(device) && audioDeviceIsRunningSomewhere(device)
        }
    }

    private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func audioDeviceIsRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr
            && running != 0
    }

    // MARK: - Wi-Fi (CoreWLAN)

    private var isWiFiAuthorized: Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }

    private func wifiSSID() -> String? {
        guard isWiFiAuthorized else { return nil }
        return CWWiFiClient.shared().interface()?.ssid()
    }

    // MARK: - Focus (Intents)

    private func focusActive() -> Bool? {
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized else { return nil }
        return center.focusStatus.isFocused
    }

    // MARK: - Calendar (EventKit)

    private func calendarMeetings(now: Date) -> [CalendarMeeting] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        guard now.timeIntervalSince(lastCalendarQuery) >= Self.calendarQueryInterval else {
            return cachedMeetings.filter { $0.endDate > now }
        }
        lastCalendarQuery = now
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(Self.calendarLookahead),
            calendars: nil
        )
        cachedMeetings = eventStore.events(matching: predicate).compactMap { event in
            guard !event.isAllDay,
                  event.status != .canceled,
                  !Self.isDeclined(event),
                  let id = event.eventIdentifier,
                  let start = event.startDate,
                  let end = event.endDate else { return nil }
            return CalendarMeeting(
                id: id,
                title: event.title ?? "",
                startDate: start,
                endDate: end
            )
        }
        return cachedMeetings.filter { $0.endDate > now }
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }
}

// MARK: - Permission Requests (#174)

/// Requests only the permissions required by an enabled rule. The settings screen calls this after
/// a rule is added or toggled, and `AutomationEngine.start` calls it once at launch for rules that
/// already exist. Permissions are never requested merely because the app started.
@MainActor
enum MacContextPermissionRequester {
    private static var retainedEventStore: EKEventStore?
    private static var retainedLocationManager: CLLocationManager?

    static func requestPermissions(for rules: [AutomationRule]) {
        for permission in MacContextAutomation.requiredPermissions(for: rules) {
            request(permission)
        }
    }

    static func request(_ permission: AutomationPermission) {
        switch permission {
        case .focus:
            let center = INFocusStatusCenter.default
            guard center.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization { _ in }
        case .calendar:
            guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
            let store = EKEventStore()
            retainedEventStore = store
            store.requestFullAccessToEvents { _, _ in }
        case .location:
            let manager = retainedLocationManager ?? CLLocationManager()
            retainedLocationManager = manager
            guard manager.authorizationStatus == .notDetermined else { return }
            manager.requestWhenInUseAuthorization()
        }
    }
}
