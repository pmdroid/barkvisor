import Foundation

/// Local Library row as Home metadata. No file path — blobs stay on the Device.
public struct HomeLibraryDeviceImage: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var imageType: String
    public var arch: String
    public var status: String
    public var sizeBytes: Int64?
    public var sourceUrl: String?
    public var error: String?
    public var sha256: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        imageType: String,
        arch: String,
        status: String,
        sizeBytes: Int64?,
        sourceUrl: String?,
        error: String?,
        sha256: String?,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.name = name
        self.imageType = imageType
        self.arch = arch
        self.status = status
        self.sizeBytes = sizeBytes
        self.sourceUrl = sourceUrl
        self.error = error
        self.sha256 = sha256
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from image: VMImage) {
        self.init(
            id: image.id,
            name: image.name,
            imageType: image.imageType,
            arch: image.arch,
            status: image.status,
            sizeBytes: image.sizeBytes,
            sourceUrl: image.sourceUrl,
            error: image.error,
            sha256: image.sha256,
            createdAt: image.createdAt,
            updatedAt: image.updatedAt,
        )
    }
}

/// One Device's copy of a Home Library image.
public struct HomeLibraryCopy: Codable, Sendable, Equatable {
    public var hostId: String
    public var imageId: String
    public var status: String

    public init(hostId: String, imageId: String, status: String) {
        self.hostId = hostId
        self.imageId = imageId
        self.status = status
    }
}

/// Deduped Home Library row. `copies` is for prefetch, not a Device column.
public struct HomeLibraryImage: Codable, Sendable, Equatable {
    public var libraryKey: String
    public var id: String
    public var name: String
    public var imageType: String
    public var arch: String
    public var status: String
    public var sizeBytes: Int64?
    public var sourceUrl: String?
    public var error: String?
    public var sha256: String?
    public var createdAt: String
    public var updatedAt: String
    public var copies: [HomeLibraryCopy]
    public var sourceHostIds: [String]

    public init(
        libraryKey: String,
        id: String,
        name: String,
        imageType: String,
        arch: String,
        status: String,
        sizeBytes: Int64?,
        sourceUrl: String?,
        error: String?,
        sha256: String?,
        createdAt: String,
        updatedAt: String,
        copies: [HomeLibraryCopy],
        sourceHostIds: [String],
    ) {
        self.libraryKey = libraryKey
        self.id = id
        self.name = name
        self.imageType = imageType
        self.arch = arch
        self.status = status
        self.sizeBytes = sizeBytes
        self.sourceUrl = sourceUrl
        self.error = error
        self.sha256 = sha256
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.copies = copies
        self.sourceHostIds = sourceHostIds
    }
}

public struct HomeLibraryList: Codable, Sendable, Equatable {
    public var images: [HomeLibraryImage]

    public init(images: [HomeLibraryImage]) {
        self.images = images
    }
}

public struct HomeLibraryPrefetchRequest: Codable, Sendable, Equatable {
    public var libraryKey: String
    public var hostId: String

    public init(libraryKey: String, hostId: String) {
        self.libraryKey = libraryKey
        self.hostId = hostId
    }
}

public struct HomeLibraryPrefetchResponse: Codable, Sendable, Equatable {
    public var libraryKey: String
    public var hostId: String
    public var image: HomeLibraryDeviceImage

    public init(libraryKey: String, hostId: String, image: HomeLibraryDeviceImage) {
        self.libraryKey = libraryKey
        self.hostId = hostId
        self.image = image
    }
}

/// Copy a ready image onto this Device from a paired Device (agent plane).
public struct ImagePrefetchRequest: Codable, Sendable, Equatable {
    public var sourceHostId: String
    public var sourceImageId: String
    public var name: String
    public var imageType: String
    public var arch: String
    public var sourceUrl: String?
    public var sha256: String?

    public init(
        sourceHostId: String,
        sourceImageId: String,
        name: String,
        imageType: String,
        arch: String,
        sourceUrl: String? = nil,
        sha256: String? = nil,
    ) {
        self.sourceHostId = sourceHostId
        self.sourceImageId = sourceImageId
        self.name = name
        self.imageType = imageType
        self.arch = arch
        self.sourceUrl = sourceUrl
        self.sha256 = sha256
    }
}

/// Merge per-Device Library listings. Checksum identity; never content-addressed storage.
public enum HomeLibraryCatalog {
    public static func key(for image: HomeLibraryDeviceImage) -> String {
        let sha = image.sha256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sha.isEmpty {
            return "sha256:\(sha)"
        }
        let src = image.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let size = image.sizeBytes, !src.isEmpty {
            return "\(image.imageType):\(image.arch):\(image.name):\(size):\(src)"
        }
        return "id:\(image.id)"
    }

    public static func merge(
        _ batches: [(hostId: String, images: [HomeLibraryDeviceImage])],
    ) -> [HomeLibraryImage] {
        var merged: [String: HomeLibraryImage] = [:]
        for batch in batches {
            for image in batch.images {
                upsert(&merged, hostId: batch.hostId, image: image)
            }
        }
        return merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func sourceCopy(
        of image: HomeLibraryImage,
        excluding targetHostId: String,
    ) -> HomeLibraryCopy? {
        image.copies.first { $0.status == "ready" && $0.hostId != targetHostId }
    }

    public static func copy(of image: HomeLibraryImage, hostId: String) -> HomeLibraryCopy? {
        image.copies.first { $0.hostId == hostId }
    }

    private static func readyHostIds(_ copies: [HomeLibraryCopy]) -> [String] {
        copies.filter { $0.status == "ready" }.map(\.hostId)
    }

    private static func upsert(
        _ merged: inout [String: HomeLibraryImage],
        hostId: String,
        image: HomeLibraryDeviceImage,
    ) {
        let key = key(for: image)
        let copy = HomeLibraryCopy(hostId: hostId, imageId: image.id, status: image.status)
        guard var existing = merged[key] else {
            merged[key] = makeRow(key: key, image: image, copies: [copy])
            return
        }
        if image.status == "ready", existing.status != "ready" {
            existing = makeRow(key: key, image: image, copies: existing.copies)
        }
        if let index = existing.copies.firstIndex(where: { $0.hostId == hostId }) {
            existing.copies[index] = copy
        } else {
            existing.copies.append(copy)
        }
        existing.sourceHostIds = readyHostIds(existing.copies)
        merged[key] = existing
    }

    private static func makeRow(
        key: String,
        image: HomeLibraryDeviceImage,
        copies: [HomeLibraryCopy],
    ) -> HomeLibraryImage {
        HomeLibraryImage(
            libraryKey: key,
            id: image.id,
            name: image.name,
            imageType: image.imageType,
            arch: image.arch,
            status: image.status,
            sizeBytes: image.sizeBytes,
            sourceUrl: image.sourceUrl,
            error: image.error,
            sha256: image.sha256,
            createdAt: image.createdAt,
            updatedAt: image.updatedAt,
            copies: copies,
            sourceHostIds: readyHostIds(copies),
        )
    }
}
