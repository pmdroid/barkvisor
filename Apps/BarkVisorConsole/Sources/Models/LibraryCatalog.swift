import Foundation

enum LibraryCatalog {
    static let emptyLibraryCopy = "Download an image from the catalog below."
    static let emptyCatalogCopy = "No catalog images. Sync repositories in the web UI."
    static let failedCatalogCopy = "Couldn't load catalog images. Pull to refresh."

    #if os(iOS)
    static let preferSelfDevice = true
    #else
    static let preferSelfDevice = false
    #endif

    static func targetDevice(
        devices: [HomeDeviceHealthSnapshot],
        selectedID: String?,
        preferSelf: Bool,
    ) -> HomeDeviceHealthSnapshot? {
        if preferSelf, let selfDevice = devices.first(where: \.isSelf) {
            return selfDevice
        }
        if let selectedID, let match = devices.first(where: { $0.hostId == selectedID }) {
            return match
        }
        return devices.first(where: \.isSelf) ?? devices.first
    }

    static func imageRepositories(_ repos: [ImageRepository]) -> [ImageRepository] {
        repos.filter { $0.repoType == "images" }
    }

    static func libraryImage(for catalog: CatalogImage, in images: [LibraryImage]) -> LibraryImage? {
        images.first { $0.sourceUrl == catalog.downloadUrl }
    }

    static func groups(
        repos: [ImageRepository],
        imagesByRepo: [String: [CatalogImage]],
    ) -> [CatalogGroup] {
        imageRepositories(repos).compactMap { repo in
            let images = (imagesByRepo[repo.id] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            guard !images.isEmpty else { return nil }
            return CatalogGroup(repo: repo, images: images)
        }
    }

    /// `failed` keeps the previous row; a successful empty fetch drops it.
    static func mergeCatalogImages(
        previous: [String: [CatalogImage]],
        loads: [String: CatalogRepoLoad],
    ) -> CatalogImagesMerge {
        var map: [String: [CatalogImage]] = [:]
        var anyFetched = false
        var anyFailed = false
        for (id, load) in loads {
            switch load {
            case let .fetched(images):
                anyFetched = true
                if !images.isEmpty { map[id] = images }
            case .failed:
                anyFailed = true
                if let kept = previous[id], !kept.isEmpty { map[id] = kept }
            }
        }
        return CatalogImagesMerge(
            imagesByRepo: map,
            fetchFailed: anyFailed && !anyFetched,
        )
    }

    static func emptyCatalogMessage(fetchFailed: Bool) -> String {
        fetchFailed ? failedCatalogCopy : emptyCatalogCopy
    }

    static func downloadState(local: LibraryImage?, starting: Bool) -> CatalogDownloadState {
        if let local {
            switch local.status {
            case "downloading": return .downloading
            case "decompressing": return .decompressing
            case "ready": return .ready
            case "error":
                if starting { return .starting }
                return .failed(local.error)
            default: break
            }
        }
        if starting { return .starting }
        return .available
    }

    static func sizeLabel(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct CatalogGroup: Identifiable, Hashable {
    var repo: ImageRepository
    var images: [CatalogImage]
    var id: String { repo.id }
}

enum CatalogRepoLoad: Equatable {
    case fetched([CatalogImage])
    case failed
}

struct CatalogImagesMerge: Equatable {
    var imagesByRepo: [String: [CatalogImage]]
    var fetchFailed: Bool
}

enum CatalogDownloadState: Equatable {
    case available
    case starting
    case downloading
    case decompressing
    case ready
    case failed(String?)

    var isBusy: Bool {
        switch self {
        case .starting, .downloading, .decompressing: true
        default: false
        }
    }

    var buttonTitle: String {
        switch self {
        case .available: "Download"
        case .starting: "Starting"
        case .downloading: "Downloading"
        case .decompressing: "Decompressing"
        case .ready: "In Library"
        case .failed: "Retry"
        }
    }
}
