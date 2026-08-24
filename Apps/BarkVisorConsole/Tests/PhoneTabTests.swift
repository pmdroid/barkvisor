import Foundation
import Testing
@testable import BarkVisorConsole

struct PhoneTabTests {
    @Test func `models tab matches Mac Ollama route and round trips`() {
        #expect(PhoneTab.models.rawValue == "models")
        #expect(AppRoute.models.title == "Ollama")
        #expect(AppRoute.models.symbol == "cube")
        #expect(PhoneTab.models.appRoute == .models)
        #expect(PhoneTab(route: .models) == .models)
        #expect(PhoneTab(route: .dashboard) == .home)
        #expect(PhoneTab(route: .workloads) == nil)
        #expect(PhoneTab.restored("models") == .models)
        #expect(PhoneTab.restored("library") == .library)
        #expect(PhoneTab.restored(nil) == .home)
        #expect(PhoneTab.restored("nope") == .home)
        for tab in PhoneTab.allCases {
            #expect(PhoneTab.restored(tab.rawValue) == tab)
            #expect(PhoneTab(route: tab.appRoute) == tab)
        }
        #expect(PhoneTab.allCases.contains(.models))
        #expect(Set(PhoneTab.allCases.map(\.rawValue)).count == PhoneTab.allCases.count)
    }

    @Test func `openPhoneTab routing includes models refresh`() {
        #expect(PhoneTab.models.appRoute == .models)
        #expect(PhoneTab.chat.appRoute == .chat)
        #expect(PhoneTab.library.appRoute == .library)
        #expect(PhoneTab.settings.appRoute == .settings)
        #expect(PhoneTab.home.appRoute == .dashboard)
        #expect(PhoneTab.devices.appRoute == .devices)
    }
}
