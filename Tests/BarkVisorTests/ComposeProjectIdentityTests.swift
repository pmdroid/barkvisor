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

    @Test func `create rejects an ID that maps to an existing project`() {
        #expect(ComposeRuntime.composeProjectTaken(id: "app-a", existing: ["appha"]))
        #expect(!ComposeRuntime.composeProjectTaken(id: "app-a", existing: ["AppA"]))
    }
}
