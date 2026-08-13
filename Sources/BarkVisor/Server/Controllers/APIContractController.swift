import BarkVisorCore
import Vapor

/// Public contract endpoints (PAS-78). No JWT — automation and the SPA
/// need the spec and version before login.
enum APIContractController {
    static func registerPublicRoutes(_ routes: any RoutesBuilder) {
        routes.get("api", "openapi.yaml", use: getOpenAPI)
        routes.get("api", "contract", use: getContract)
        routes.get("api", "workloadspec.schema.json", use: getWorkloadSpecSchema)
    }

    @Sendable
    static func getOpenAPI(req _: Vapor.Request) async throws -> Response {
        let yaml = try APIContract.specYAML()
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/yaml; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: yaml))
    }

    @Sendable
    static func getContract(req _: Vapor.Request) async throws -> APIContractSummary {
        APIContractSummary.current
    }

    @Sendable
    static func getWorkloadSpecSchema(req _: Vapor.Request) async throws -> Response {
        let json = try APIContract.workloadSpecSchemaJSON()
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/schema+json; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: json))
    }
}
