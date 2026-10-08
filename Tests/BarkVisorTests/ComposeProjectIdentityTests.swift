import Testing
@testable import BarkVisorCore

struct ComposeProjectIdentityTests {
    @Test func `case and hyphen variants do not share a project`() {
        let names = [
            ComposeRuntime.composeProjectName(id: "app-a"),
            ComposeRuntime.composeProjectName(id: "appa"),
            ComposeRuntime.composeProjectName(id: "AppA"),
        ]
        #expect(Set(names).count == 3)
        #expect(names[0] != names[1])
        #expect(names[1] != names[2])
    }
}
