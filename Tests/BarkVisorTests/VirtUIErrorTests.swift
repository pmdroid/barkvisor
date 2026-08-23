import Foundation
import Testing
@testable import BarkVisorCore

struct VirtUIErrorTests {
    // MARK: - errorDescription

    @Test func `all errors have descriptions`() throws {
        let errors: [BarkVisorError] = [
            .qemuNotFound("not found"),
            .firmwareNotFound("missing"),
            .unknownVMType("bad-type"),
            .diskCreateFailed("failed"),
            .insufficientDiskSpace(freeBytes: 100, neededBytes: 1_073_741_824),
            .cloudInitFailed("failed"),
            .monitorError("error"),
            .vmNotRunning("vm-1"),
            .vmAlreadyRunning("vm-1"),
            .ptyParseFailed,
            .processSpawnFailed("failed"),
            .repositoryNotFound("repo-1"),
            .repositorySyncFailed("failed"),
            .invalidPortForward("bad"),
            .decompressFailed("failed"),
            .downloadFailed("failed"),
            .bridgeNotReady("not ready"),
            .interfaceMissing("br0"),
            .bridgeHelperDenied("br0"),
            .invalidBridgeName("bad name"),
            .invalidArgument("bad"),
            .timeout("timed out"),
            .unsupportedFeature(.bridgedNetworking),
            .badRequest("bad request"),
            .notFound("not found"),
            .notFound(),
            .unauthorized("unauthorized"),
            .unauthorized(),
            .forbidden("forbidden"),
            .conflict("conflict"),
            .portInUse("port in use"),
            .preconditionFailed("precondition"),
            .internalError("internal"),
        ]

        for error in errors {
            #expect(error.errorDescription != nil, "Missing description for \(error)")
            let desc = try #require(error.errorDescription)
            #expect(!desc.isEmpty, "Empty description for \(error)")
        }
    }

    // MARK: - code

    @Test func `all errors have machine readable codes`() {
        let expectations: [(BarkVisorError, String)] = [
            (.qemuNotFound(""), "qemu_not_found"),
            (.firmwareNotFound(""), "firmware_not_found"),
            (.unknownVMType(""), "unknown_vm_type"),
            (.vmNotRunning(""), "vm_not_running"),
            (.vmAlreadyRunning(""), "vm_already_running"),
            (.ptyParseFailed, "pty_parse_failed"),
            (.badRequest(""), "bad_request"),
            (.notFound(), "not_found"),
            (.unauthorized(), "unauthorized"),
            (.forbidden(""), "forbidden"),
            (.conflict(""), "conflict"),
            (.portInUse(""), "port_in_use"),
            (.timeout(""), "timeout"),
            (.unsupportedFeature(.inAppUpdate), "in_app_update"),
        ]

        for (error, expectedCode) in expectations {
            #expect(error.code == expectedCode, "Wrong code for \(error)")
        }
    }

    // MARK: - httpStatus

    @Test func `http status codes`() {
        #expect(BarkVisorError.badRequest("").httpStatus == 400)
        #expect(BarkVisorError.invalidArgument("").httpStatus == 400)
        #expect(BarkVisorError.invalidPortForward("").httpStatus == 400)
        #expect(BarkVisorError.unknownVMType("").httpStatus == 400)
        #expect(BarkVisorError.unauthorized().httpStatus == 401)
        #expect(BarkVisorError.forbidden("").httpStatus == 403)
        #expect(BarkVisorError.notFound().httpStatus == 404)
        #expect(BarkVisorError.repositoryNotFound("").httpStatus == 404)
        #expect(BarkVisorError.conflict("").httpStatus == 409)
        #expect(BarkVisorError.vmAlreadyRunning("").httpStatus == 409)
        #expect(BarkVisorError.portInUse("").httpStatus == 409)
        #expect(BarkVisorError.portInUse("").code == "port_in_use")
        #expect(BarkVisorError.preconditionFailed("").httpStatus == 412)
        #expect(BarkVisorError.unsupportedFeature(.usbPassthrough).httpStatus == 422)
        #expect(BarkVisorError.interfaceMissing("br0").httpStatus == 422)
        #expect(BarkVisorError.interfaceMissing("br0").code == "interface_missing")
        #expect(BarkVisorError.bridgeHelperDenied("br0").httpStatus == 422)
        #expect(BarkVisorError.bridgeHelperDenied("br0").code == "bridge_acl")
        #expect(BarkVisorError.invalidBridgeName("x").httpStatus == 400)
        #expect(BarkVisorError.invalidBridgeName("x").code == "invalid_bridge")
        #expect(BarkVisorError.bridgeNotReady("not ready").httpStatus == 422)
        #expect(BarkVisorError.bridgeNotReady("not ready").code == "bridge_not_ready")

        // Domain errors default to 500
        #expect(BarkVisorError.qemuNotFound("").httpStatus == 500)
        #expect(BarkVisorError.diskCreateFailed("").httpStatus == 500)
        #expect(BarkVisorError.insufficientDiskSpace(freeBytes: 1, neededBytes: 2).httpStatus == 507)
        #expect(BarkVisorError.insufficientDiskSpace(freeBytes: 1, neededBytes: 2).code == "insufficient_disk_space")
        #expect(BarkVisorError.monitorError("").httpStatus == 500)
        #expect(BarkVisorError.internalError("").httpStatus == 500)
    }

    // MARK: - sanitizedDescription

    @Test func `sanitized description strips absolute paths`() {
        let error = BarkVisorError.diskCreateFailed(
            "Failed to create disk at /Users/alice/Library/data/disk.qcow2",
        )
        let sanitized = error.sanitizedDescription
        #expect(
            !sanitized.contains("/Users/alice"), "Should strip filesystem paths: \(sanitized)",
        )
        #expect(sanitized.contains("<path>"), "Should replace paths with <path>: \(sanitized)")
    }

    @Test func `sanitized description preserves non path messages`() {
        let error = BarkVisorError.badRequest("Name is required")
        #expect(error.sanitizedDescription == "Name is required")
    }

    @Test func `interface and acl preflight messages keep remediation`() {
        let missing = BarkVisorError.interfaceMissing("br0")
        #expect(missing.sanitizedDescription.contains("does not exist"))
        #expect(!missing.sanitizedDescription.contains("<path>"))
        let acl = BarkVisorError.bridgeHelperDenied("br0")
        #expect(acl.sanitizedDescription.contains("allow br0"))
        #expect(!acl.sanitizedDescription.contains("<path>"))
    }

    @Test func `not found default description`() {
        let error = BarkVisorError.notFound()
        #expect(error.errorDescription == "Not found")
    }

    @Test func `unauthorized default description`() {
        let error = BarkVisorError.unauthorized()
        #expect(error.errorDescription == "Unauthorized")
    }
}
