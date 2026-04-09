import XCTest
@testable import BarkVisorCore

final class VirtUIErrorTests: XCTestCase {
    // MARK: - errorDescription

    func testAllErrorsHaveDescriptions() throws {
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
            XCTAssertNotNil(error.errorDescription, "Missing description for \(error)")
            XCTAssertFalse(
                try XCTUnwrap(error.errorDescription?.isEmpty), "Empty description for \(error)",
            )
        }
    }

    // MARK: - code

    func testAllErrorsHaveMachineReadableCodes() {
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
            XCTAssertEqual(error.code, expectedCode, "Wrong code for \(error)")
        }
    }

    // MARK: - httpStatus

    func testHTTPStatusCodes() {
        XCTAssertEqual(BarkVisorError.badRequest("").httpStatus, 400)
        XCTAssertEqual(BarkVisorError.invalidArgument("").httpStatus, 400)
        XCTAssertEqual(BarkVisorError.invalidPortForward("").httpStatus, 400)
        XCTAssertEqual(BarkVisorError.unknownVMType("").httpStatus, 400)
        XCTAssertEqual(BarkVisorError.unauthorized().httpStatus, 401)
        XCTAssertEqual(BarkVisorError.forbidden("").httpStatus, 403)
        XCTAssertEqual(BarkVisorError.notFound().httpStatus, 404)
        XCTAssertEqual(BarkVisorError.repositoryNotFound("").httpStatus, 404)
        XCTAssertEqual(BarkVisorError.conflict("").httpStatus, 409)
        XCTAssertEqual(BarkVisorError.vmAlreadyRunning("").httpStatus, 409)
        XCTAssertEqual(BarkVisorError.preconditionFailed("").httpStatus, 412)

        // Domain errors default to 500
        XCTAssertEqual(BarkVisorError.qemuNotFound("").httpStatus, 500)
        XCTAssertEqual(BarkVisorError.diskCreateFailed("").httpStatus, 500)
        XCTAssertEqual(BarkVisorError.monitorError("").httpStatus, 500)
        XCTAssertEqual(BarkVisorError.internalError("").httpStatus, 500)
    }

    // MARK: - sanitizedDescription

    func testSanitizedDescriptionStripsAbsolutePaths() {
        let error = BarkVisorError.diskCreateFailed(
            "Failed to create disk at /Users/alice/Library/data/disk.qcow2",
        )
        let sanitized = error.sanitizedDescription
        XCTAssertFalse(
            sanitized.contains("/Users/alice"), "Should strip filesystem paths: \(sanitized)",
        )
        XCTAssertTrue(sanitized.contains("<path>"), "Should replace paths with <path>: \(sanitized)")
    }

    func testSanitizedDescriptionPreservesNonPathMessages() {
        let error = BarkVisorError.badRequest("Name is required")
        XCTAssertEqual(error.sanitizedDescription, "Name is required")
    }

    func testNotFoundDefaultDescription() {
        let error = BarkVisorError.notFound()
        XCTAssertEqual(error.errorDescription, "Not found")
    }

    func testUnauthorizedDefaultDescription() {
        let error = BarkVisorError.unauthorized()
        XCTAssertEqual(error.errorDescription, "Unauthorized")
    }
}
