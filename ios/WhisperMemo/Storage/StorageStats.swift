import Foundation

struct StorageStats {
    let recordingsBytes: Int64
    let recordingsCount: Int
    let queueBytes: Int64
    let queueCount: Int
    let totalBytes: Int64

    static func compute() -> StorageStats {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingsDir = docs.appendingPathComponent("recordings", isDirectory: true)
        let queueFile = docs.appendingPathComponent("upload_queue.json")

        let (rBytes, rCount) = directorySize(at: recordingsDir)
        let qBytes = fileSize(at: queueFile)
        // queueCount is decoded from the json — we compute via UploadQueue separately
        return StorageStats(
            recordingsBytes: rBytes,
            recordingsCount: rCount,
            queueBytes: qBytes,
            queueCount: 0, // filled in by caller
            totalBytes: rBytes + qBytes
        )
    }

    private static func directorySize(at url: URL) -> (Int64, Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return (0, 0) }
        var total: Int64 = 0
        var count = 0
        for case let item as URL in enumerator {
            guard let v = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true,
                  let size = v.fileSize else { continue }
            total += Int64(size)
            count += 1
        }
        return (total, count)
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = v.fileSize else { return 0 }
        return Int64(size)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: bytes)
    }
}
