import Foundation

/// ONE rule for every sharing route: a request is built only against a real origin, or not at all.
///
/// The defect this exists to prevent was measured on the capture-allowance client: `URL(string: "" + path)`
/// SUCCEEDS as a relative URL, so bare concatenation hands the transport a request with nowhere to
/// go. The request is still issued, is still answered by the test transport, and reaches the caller
/// as an ordinary transport failure — which makes "this build has no origin, so nothing was asked"
/// indistinguishable from "something was asked and failed". Those have different retry rules and
/// different operational meaning, so the distinction has to be made before the transport is touched.
enum VoiceSharingOrigin {
    /// The absolute URL for `path` at `origin`, or nil when the origin cannot be dialed.
    /// Nil is never defaulted to something plausible: an unconfigured build asks nobody.
    static func url(origin: String, path: String) -> URL? {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let originURL = URL(string: trimmed),
              let scheme = originURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = originURL.host, !host.isEmpty else { return nil }
        return URL(string: trimmed + path)
    }
}
