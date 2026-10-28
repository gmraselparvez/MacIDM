import Foundation

public struct ProbeResult: Equatable, Sendable {
    public var finalURL: URL
    public var totalSize: Int64?
    public var acceptsRanges: Bool
    public var suggestedFileName: String
    public var etag: String?
    public var lastModified: String?
    public var mimeType: String?
}

public struct ProbeService: Sendable {
    public let session: URLSession
    public let userAgent: String

    public init(session: URLSession, userAgent: String) {
        self.session = session
        self.userAgent = userAgent
    }

    /// `HEAD` first; if it fails or doesn't confirm range support, a `GET` with `Range: bytes=0-0`.
    public func probe(_ url: URL, headers: [String: String] = [:]) async throws -> ProbeResult {
        var head = makeRequest(url, headers: headers)
        head.httpMethod = "HEAD"
        var headResult: ProbeResult?
        if let (_, response) = try? await session.data(for: head),
           let http = response as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 410 { throw DownloadError.linkExpired(http.statusCode) }
            if (200..<300).contains(http.statusCode) {
                headResult = result(from: http, requested: url)
            }
        }
        if let r = headResult, r.acceptsRanges, r.totalSize != nil { return r }

        var get = makeRequest(url, headers: headers)
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: get)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }
        switch http.statusCode {
        case 206:
            var r = result(from: http, requested: url)
            r.acceptsRanges = true
            if let cr = http.value(forHTTPHeaderField: "Content-Range"), let total = Self.totalFromContentRange(cr) {
                r.totalSize = total
            } else {
                r.totalSize = headResult?.totalSize
                r.acceptsRanges = r.totalSize != nil
            }
            return r
        case 200..<300:
            var r = result(from: http, requested: url)
            r.acceptsRanges = false
            if r.totalSize == nil { r.totalSize = headResult?.totalSize }
            return r
        case 403, 410:
            throw DownloadError.linkExpired(http.statusCode)
        default:
            if let headResult { return headResult }
            throw DownloadError.http(http.statusCode)
        }
    }

    func makeRequest(_ url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Raw bytes only: compressed responses can't be split into byte ranges.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    func result(from http: HTTPURLResponse, requested: URL) -> ProbeResult {
        let finalURL = http.url ?? requested
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        let ranges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false
        let mime = http.mimeType
        return ProbeResult(
            finalURL: finalURL,
            totalSize: length,
            acceptsRanges: ranges,
            suggestedFileName: FileNaming.fileName(
                contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"),
                url: finalURL, mimeType: mime),
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            mimeType: mime)
    }

    /// Parses the total from `bytes 0-0/12345`; nil for `*`.
    public static func totalFromContentRange(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
