import Foundation

public enum FileMerger {
    /// Checks that segments, sorted by start, cover the file with no gaps or overlaps.
    public static func validate(_ segments: [Segment], expectedSize: Int64?) throws {
        let sorted = segments.sorted { $0.start < $1.start }
        var offset: Int64 = 0
        for seg in sorted where seg.downloaded > 0 || seg.length != 0 {
            guard seg.start == offset, seg.isComplete else {
                throw DownloadError.incomplete
            }
            offset += seg.downloaded
        }
        if let expectedSize, offset != expectedSize {
            throw DownloadError.sizeMismatch(expected: expectedSize, actual: offset)
        }
    }

    /// Concatenates part files in order into `destination` and verifies the final size.
    public static func merge(parts: [URL], into destination: URL, expectedSize: Int64?,
                             fileManager: FileManager = .default) throws {
        if parts.count == 1 {
            try fileManager.moveItem(at: parts[0], to: destination)
        } else {
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            do {
                let out = try FileHandle(forWritingTo: destination)
                defer { try? out.close() }
                for part in parts {
                    let input = try FileHandle(forReadingFrom: part)
                    defer { try? input.close() }
                    while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                        try out.write(contentsOf: chunk)
                    }
                }
            } catch {
                try? fileManager.removeItem(at: destination)
                throw DownloadError.map(error)
            }
        }
        if let expectedSize {
            let actual = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard actual == expectedSize else {
                throw DownloadError.sizeMismatch(expected: expectedSize, actual: actual)
            }
        }
    }
}
