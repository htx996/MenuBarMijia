import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #174 review: exercise the real IOKit power description path (owned vs borrowed CFDictionary)
/// and keep the battery reading range valid.
@MainActor
struct MacContextObserverTests {
    @Test("Power source read owns/releases IOKit values correctly and clamps the battery")
    func powerSourceRead() {
        let (source, percent) = MacContextObserver.readPowerState()
        #expect([MacPowerSource.ac, .battery, .unknown].contains(source))
        if let percent {
            #expect((0...100).contains(percent))
        }
    }
}
