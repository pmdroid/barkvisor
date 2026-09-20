import Foundation

enum ComposeResources {
    static func validate(_ value: Any?) throws {
        guard let value else { return }
        guard let deployment = value as? [String: Any],
              Set(deployment.keys).isSubset(of: ["resources"])
        else { throw invalid() }
        guard let rawResources = deployment["resources"] else { return }
        guard let resources = rawResources as? [String: Any],
              Set(resources.keys).isSubset(of: ["limits", "reservations"])
        else { throw invalid() }
        for raw in resources.values {
            guard let settings = raw as? [String: Any],
                  Set(settings.keys).isSubset(of: ["cpus", "memory"])
            else { throw invalid() }
            for (key, rawValue) in settings {
                let text = String(describing: rawValue)
                if key == "cpus" {
                    guard let number = Double(text), number.isFinite, number >= 0 else { throw invalid() }
                } else {
                    guard text.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:[bBkKmMgG](?:[bB])?)?$"#, options: .regularExpression) != nil
                    else { throw invalid() }
                }
            }
        }
    }

    private static func invalid() -> BarkVisorError {
        .badRequest("unsupported compose feature: deploy")
    }
}
