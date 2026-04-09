import BarkVisorCore
import Foundation
import Vapor

struct ValidateCloudInitRequest: Content {
    let userData: String
}

struct ValidateCloudInitResponse: Content {
    let valid: Bool
    let error: String?
}

struct CloudInitController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ci = routes.grouped("api", "cloud-init")
        ci.post("validate", use: validate)
    }

    @Sendable
    func validate(req: Vapor.Request) async throws -> ValidateCloudInitResponse {
        let body = try req.content.decode(ValidateCloudInitRequest.self)
        let trimmed = body.userData.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ValidateCloudInitResponse(valid: true, error: nil)
        }
        do {
            try CloudInitService.validateUserData(trimmed)
            return ValidateCloudInitResponse(valid: true, error: nil)
        } catch {
            let message =
                if let abort = error as? Abort {
                    abort.reason
                } else {
                    error.localizedDescription
                }
            return ValidateCloudInitResponse(valid: false, error: message)
        }
    }
}
