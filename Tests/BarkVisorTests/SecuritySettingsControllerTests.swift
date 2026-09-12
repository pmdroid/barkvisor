import Foundation
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

struct SecuritySettingsControllerTests {
    @Test func `update refuses env-locked writes`() {
        do {
            _ = try SecuritySettingsPolicy.validatedMode(
                raw: "loopback",
                acknowledged: false,
                envLocked: true,
                hasProvisionedAdmin: true,
            )
            Issue.record("expected env-locked conflict")
        } catch let error as BarkVisorError {
            guard case .conflict = error else {
                Issue.record("expected conflict, got \(error)")
                return
            }
        } catch {
            Issue.record("expected BarkVisorError, got \(error)")
        }
    }

    @Test func `disabled requires acknowledgement`() {
        do {
            _ = try SecuritySettingsPolicy.validatedMode(
                raw: "disabled",
                acknowledged: false,
                envLocked: false,
                hasProvisionedAdmin: true,
            )
            Issue.record("expected acknowledgement failure")
        } catch let error as BarkVisorError {
            guard case .badRequest = error else {
                Issue.record("expected badRequest, got \(error)")
                return
            }
        } catch {
            Issue.record("expected BarkVisorError, got \(error)")
        }
    }

    @Test func `known modes persist when unlocked`() throws {
        #expect(
            try SecuritySettingsPolicy.validatedMode(
                raw: "secure",
                acknowledged: false,
                envLocked: false,
                hasProvisionedAdmin: true,
            ) == .secure,
        )
        #expect(
            try SecuritySettingsPolicy.validatedMode(
                raw: "loopback",
                acknowledged: false,
                envLocked: false,
                hasProvisionedAdmin: true,
            ) == .loopback,
        )
        #expect(
            try SecuritySettingsPolicy.validatedMode(
                raw: "disabled",
                acknowledged: true,
                envLocked: false,
                hasProvisionedAdmin: true,
            ) == .disabled,
        )
    }

    @Test func `secure is refused until an admin exists`() {
        do {
            _ = try SecuritySettingsPolicy.validatedMode(
                raw: "secure",
                acknowledged: false,
                envLocked: false,
                hasProvisionedAdmin: false,
            )
            Issue.record("expected missing-admin failure")
        } catch let error as BarkVisorError {
            guard case .preconditionFailed = error else {
                Issue.record("expected preconditionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected BarkVisorError, got \(error)")
        }
        #expect(
            (try? SecuritySettingsPolicy.validatedMode(
                raw: "loopback",
                acknowledged: false,
                envLocked: false,
                hasProvisionedAdmin: false,
            )) == .loopback,
        )
    }

    @Test func `unknown mode is rejected`() {
        do {
            _ = try SecuritySettingsPolicy.validatedMode(
                raw: "wide-open",
                acknowledged: true,
                envLocked: false,
                hasProvisionedAdmin: true,
            )
            Issue.record("expected unknown mode failure")
        } catch let error as BarkVisorError {
            guard case .badRequest = error else {
                Issue.record("expected badRequest, got \(error)")
                return
            }
        } catch {
            Issue.record("expected BarkVisorError, got \(error)")
        }
    }

    @Test func `non-admin cannot read or write security settings`() async throws {
        var env = Environment(name: "testing", arguments: ["barkvisor-test"])
        env.commandInput = CommandInput(arguments: ["barkvisor-test"])
        let app = try await Application.make(env)
        app.logger.logLevel = .error
        do {
            let req = Request(
                application: app,
                method: .GET,
                url: URI(string: "/api/settings/security"),
                on: app.eventLoopGroup.next(),
            )
            req.authenticatedUser = AuthenticatedUser(
                userId: "user-1",
                username: "viewer",
                authMethod: "jwt",
                apiKeyId: nil,
                role: UserRole.inference.rawValue,
            )
            do {
                _ = try SecuritySettingsController.requireAdmin(req)
                Issue.record("expected forbidden for inference")
            } catch let error as BarkVisorError {
                guard case .forbidden = error else {
                    Issue.record("expected forbidden, got \(error)")
                    try? await app.asyncShutdown()
                    return
                }
            }
            try? await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}
