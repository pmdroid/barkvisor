import Foundation

struct FolderEntry: Decodable, Identifiable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool?

    var id: String { "\(name):\(path)" }
}

struct BrowseCreateFolderBody: Encodable {
    var parent: String
    var name: String
}
