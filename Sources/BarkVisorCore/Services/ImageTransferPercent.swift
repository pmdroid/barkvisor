public enum ImageTransferPercent {
    public static func current(status: String?, lastProgress: ImageProgressEvent?) -> Int? {
        switch status {
        case "downloading", "decompressing", "uploading":
            return lastProgress?.percent
        default:
            return nil
        }
    }
}
