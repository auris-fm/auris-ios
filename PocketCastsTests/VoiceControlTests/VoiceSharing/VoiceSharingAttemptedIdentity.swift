import Foundation

/// Wire-level helpers shared by the upload controls.
enum VoiceSharingAttemptedIdentity {

    /// The one route a recording is sent to, for controls that count attempts.
    static let uploadPath = "/api/v1/voice-recordings"

    /// The total request length a `Content-Length` header declares, or nil when absent. The spec
    /// requires one, so a receiver can use this both to assert its presence and to know when the
    /// whole body has arrived.
    static func declaredContentLength(_ raw: Data) -> Int? {
        let bytes = [UInt8](raw)
        guard let headEnd = find([13, 10, 13, 10], in: bytes, from: 0) else { return nil }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)
            guard let bodyLength = Int(value) else { return nil }
            return headEnd + 4 + bodyLength
        }
        return nil
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in start...(haystack.count - needle.count) {
            if Array(haystack[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}