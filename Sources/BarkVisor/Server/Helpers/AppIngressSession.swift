import BarkVisorCore
import Vapor

enum AppIngressSession {
    static func encodeLogin(_ body: LoginResponse, on request: Vapor.Request) throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(body, as: .json)
        setCookie(response, token: body.token, request: request)
        return response
    }

    static func encodeComplete(_ body: SetupController.CompleteResponse, on request: Vapor.Request)
        throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(body, as: .json)
        if let token = body.token, !token.isEmpty {
            setCookie(response, token: token, request: request)
        }
        return response
    }

    static func clear(_ response: Response) {
        var cookie = HTTPCookies.Value(string: "")
        cookie.maxAge = 0
        cookie.path = "/"
        cookie.isHTTPOnly = true
        cookie.sameSite = .lax
        cookie.expires = Date(timeIntervalSince1970: 0)
        response.cookies[AppIngress.cookieName] = cookie
    }

    static func setCookie(_ response: Response, token: String, request: Vapor.Request) {
        var cookie = HTTPCookies.Value(string: token)
        cookie.path = "/"
        cookie.isHTTPOnly = true
        cookie.sameSite = .lax
        cookie.maxAge = 2 * 60 * 60
        cookie.isSecure = request.url.scheme == "https"
        response.cookies[AppIngress.cookieName] = cookie
    }
}
