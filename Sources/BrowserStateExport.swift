import Foundation

/// Helpers for `browser.state.save`: which cookies belong to the page, and a private file write.
enum BrowserStateExport {
    /// True when a cookie's domain belongs to the page's site: the cookie applies to the page
    /// host (equal or parent domain) or is scoped to a subdomain of it.
    static func cookieMatchesSite(_ cookieDomain: String, _ pageHost: String) -> Bool {
        let host = pageHost.lowercased()
        guard !host.isEmpty else { return false }
        var domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain) || domain.hasSuffix("." + host)
    }

    /// Writes `data` to a new 0600 temp file next to `path`, fsyncs it, then renames it over
    /// `path`, so the file is never observable with wider permissions or half written.
    static func writePrivateFile(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let tempPath = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = Darwin.open(tempPath, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var succeeded = false
        defer {
            if !succeeded { _ = Darwin.unlink(tempPath) }
        }
        var writeError: Int32 = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    writeError = errno
                    return
                }
                offset += n
            }
        }
        if writeError == 0, Darwin.fsync(fd) != 0 { writeError = errno }
        if Darwin.close(fd) != 0, writeError == 0 { writeError = errno }
        if writeError != 0 { throw POSIXError(POSIXErrorCode(rawValue: writeError) ?? .EIO) }
        guard Darwin.rename(tempPath, path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        succeeded = true
    }
}
