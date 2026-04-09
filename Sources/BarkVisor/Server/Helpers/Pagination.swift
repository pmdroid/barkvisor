import BarkVisorCore
import Vapor

extension Vapor.Request {
    /// Parse and clamp pagination parameters from query string.
    func pagination(defaultLimit: Int = 100, maxLimit: Int = 200) -> (limit: Int, offset: Int) {
        let limit = min(max(query[Int.self, at: "limit"] ?? defaultLimit, 1), maxLimit)
        let offset = max(query[Int.self, at: "offset"] ?? 0, 0)
        return (limit, offset)
    }
}
