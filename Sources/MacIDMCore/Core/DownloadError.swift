import Foundation

public enum DownloadError: Error, LocalizedError, Equatable, Sendable {
    case badResponse
    case rangeNotSupported
    case linkExpired(Int)
    case http(Int)
    case diskFull
    case incomplete
    case sizeMismatch(expected: Int64, actual: Int64)

    public var errorDescription: String? {
        switch self {
        case .badResponse: return "The server sent an invalid response."
        case .rangeNotSupported: return "The server does not support resuming."
        case .linkExpired(let code): return "The link has expired or access was denied (HTTP \(code)). Paste a refreshed URL to continue."
        case .http(let code): return "Server error (HTTP \(code))."
        case .diskFull: return "The disk is full. Free some space and resume."
        case .incomplete: return "The connection closed before the data was complete."
        case .sizeMismatch(let e, let a): return "Size mismatch: expected \(e) bytes, got \(a)."
        }
    }

    public static func isRetryable(_ error: Error) -> Bool {
        if let e = error as? DownloadError {
            switch e {
            case .incomplete, .badResponse: return true
            case .http(let code): return code >= 500 || code == 408 || code == 429
            default: return false
            }
        }
        if let e = error as? URLError {
            return e.code != .cancelled && e.code != .badURL && e.code != .unsupportedURL
        }
        return false
    }

    /// Turns file-system errors such as ENOSPC into `.diskFull`.
    public static func map(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return DownloadError.diskFull }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return DownloadError.diskFull }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) {
            return DownloadError.diskFull
        }
        return error
    }
}
