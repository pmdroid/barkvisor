import Foundation
import Testing
@testable import BarkVisorCore

@Suite struct VirtUIErrorTests {
    // MARK: - errorDescription

    @Test func allErrorsHaveDescriptions() throws {
        let errors: [BarkVisorError] = [
            .qemuNotFound("not found"),
            .firmwareNotFound("missing"),
            .unknownVMType("bad-type"),
            .diskCreateFailed("failed"),
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
            .invalidArgument("bad"),
            .timeout("timed out"),
            .badRequest("bad request"),
            .notFound("not found"),
            .notFound(),
            .unauthorized("unauthorized"),
            .unauthorized(),
            .forbidden("forbidden"),
            .conflict("conflict"),
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

    @Test func allErrorsHaveMachineReadableCodes() {
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
            (.timeout(""), "timeout"),
        ]

        for (error, expectedCode) in expectations {
            #expect(error.code == expectedCode, "Wrong code for \(error)")
        }
    }

    // MARK: - httpStatus

    @Test func httpStatusCodes() {
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
        #expect(BarkVisorError.preconditionFailed("").httpStatus == 412)

        // Domain errors default to 500
        #expect(BarkVisorError.qemuNotFound("").httpStatus == 500)
        #expect(BarkVisorError.diskCreateFailed("").httpStatus == 500)
        #expect(BarkVisorError.monitorError("").httpStatus == 500)
        #expect(BarkVisorError.internalError("").httpStatus == 500)
    }

    // MARK: - sanitizedDescription

    @Test func sanitizedDescriptionStripsAbsolutePaths() {
        let error = BarkVisorError.diskCreateFailed(
            "Failed to create disk at /Users/alice/Library/data/disk.qcow2",
        )
        let sanitized = error.sanitizedDescription
        #expect(
            !sanitized.contains("/Users/alice"), "Should strip filesystem paths: \(sanitized)",
        )
        #expect(sanitized.contains("<path>"), "Should replace paths with <path>: \(sanitized)")
    }

    @Test func sanitizedDescriptionPreservesNonPathMessages() {
        let error = BarkVisorError.badRequest("Name is required")
        #expect(error.sanitizedDescription == "Name is required")
    }

    @Test func notFoundDefaultDescription() {
        let error = BarkVisorError.notFound()
        #expect(error.errorDescription == "Not found")
    }

    @Test func unauthorizedDefaultDescription() {
        let error = BarkVisorError.unauthorized()
        #expect(error.errorDescription == "Unauthorized")
    }
}
