import CryptoKit
import Foundation
import PocketCastsUtils

/// Persists the committed playback↔reference time mapping next to the audio
/// file on disk so that re-opening a transcript for a previously-fingerprinted
/// downloaded episode skips the audio decode + match pipeline entirely.
///
/// The cache is *all-or-nothing*: it's loaded only when the cached mapping
/// covers (by `fullCoverageThreshold`) the whole reference timeline, both
/// the reference and audio files' on-disk identity (size+mtime) are
/// unchanged, the reference fingerprint bytes hash to the same value, and
/// a content sample hash of the audio file matches. Anything less and the
/// cache is ignored — partial-cache short-circuits are how the prior
/// POC-546 attempt trapped the timing manager in `.preparing`.
enum FingerprintMappingCache {

    struct LoadResult {
        let entries: [FingerprintTimingManager.TimeMappingEntry]
        let referenceDuration: Double
        /// The stored mapping is otherwise intact but was built against an Auris reference the
        /// caller does not hold yet. Distinct from "no usable cache": the caller should wait for
        /// the fetch and ask again rather than start fingerprinting an episode it may already
        /// have mapped. Only set when no identity was supplied at all — a *mismatched* identity
        /// is a real rejection and stays nil.
        var pendingAurisIdentity: Bool = false
    }

    /// What identifies the Auris reference a mapping was built against: its format and the
    /// bytes themselves. Both are needed — the format says which scheme, the hash says which
    /// payload within that scheme.
    struct AurisReferenceIdentity {
        let format: String
        let hash: String

        init(format: String, payload: Data) {
            self.format = format
            self.hash = sha256(payload)
        }
    }

    private struct CachedMapping: Codable {
        let schemaVersion: Int
        /// The Auris reference format these entries were matched against. Recorded
        /// separately from `referenceHash`, which covers the *transcript* reference:
        /// a mapping can be perfectly current for that file and still have been built
        /// against an endpoint reference whose hashes are no longer the ones we match.
        let aurisFormat: String?
        /// sha256 of the Auris payload itself, recorded only when an Auris reference was in
        /// use. The format alone cannot tell two v3 payloads apart, and the endpoint can
        /// re-emit the same episode with different hashes while still calling it v3.
        let aurisHash: String?
        let referenceHash: String
        let referenceByteSize: UInt64
        let referenceMTime: Double
        let audioByteSize: UInt64
        let audioMTime: Double
        let audioContentHash: String
        let referenceDuration: Double
        let entries: [CachedEntry]

        struct CachedEntry: Codable {
            let p: Double
            let r: Double
            let s: Float
        }
    }

    static func load(
        audioFilePath: String,
        referenceFilePath: String,
        referenceData: Data,
        aurisReference: AurisReferenceIdentity? = nil
    ) -> LoadResult? {
        let path = mappingPath(forAudioFilePath: audioFilePath)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let cached = try? JSONDecoder().decode(CachedMapping.self, from: data) else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: failed to decode cache at \(path) — discarding"
            )
            return nil
        }
        guard cached.schemaVersion == FingerprintConstants.mappingCacheSchemaVersion else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: schema version mismatch at \(path) — discarding"
            )
            return nil
        }
        guard let refAttrs = fileAttributes(at: referenceFilePath),
              refAttrs.size == cached.referenceByteSize,
              abs(refAttrs.mtime - cached.referenceMTime) < 1.0 else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: reference file changed at \(referenceFilePath) — discarding cache"
            )
            return nil
        }
        guard cached.referenceHash == sha256(referenceData) else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: reference hash mismatch at \(path) — discarding"
            )
            return nil
        }
        guard let audioAttrs = fileAttributes(at: audioFilePath),
              audioAttrs.size == cached.audioByteSize,
              abs(audioAttrs.mtime - cached.audioMTime) < 1.0 else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: audio file changed at \(audioFilePath) — discarding cache"
            )
            return nil
        }
        guard contentSampleHash(at: audioFilePath) == cached.audioContentHash else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: audio content hash mismatch at \(audioFilePath) — discarding cache"
            )
            return nil
        }
        guard let last = cached.entries.last,
              cached.referenceDuration > 0,
              last.r / cached.referenceDuration >= FingerprintConstants.fullCoverageThreshold else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: partial coverage at \(path) — ignoring (will run full stream)"
            )
            return nil
        }
        // Checked last, so a stale or corrupt file is rejected on its own merits and never
        // reported as merely waiting for a reference.
        //
        // The recorded identity must describe the reference the caller holds NOW, in both
        // directions. A mapping built with an Auris reference cannot be reused when the caller
        // holds none — offline, or the endpoint unavailable — because its entries came from a
        // reference that can no longer be confirmed. Comparing only when a reference is present
        // would let exactly that case through. A transcript-only mapping records no identity
        // and is unaffected.
        if cached.aurisFormat != nil || cached.aurisHash != nil {
            guard let auris = aurisReference else {
                // Nothing held yet: the fetch may still be in flight. Everything else about this
                // mapping checks out, so tell the caller to wait rather than re-fingerprint an
                // episode it may already have mapped.
                FileLog.shared.addMessage(
                    "FingerprintMappingCache: mapping at \(path) awaits its Auris reference"
                )
                return LoadResult(entries: [], referenceDuration: 0, pendingAurisIdentity: true)
            }
            guard cached.aurisFormat == auris.format, cached.aurisHash == auris.hash else {
                FileLog.shared.addMessage(
                    "FingerprintMappingCache: Auris reference changed (format "
                        + "'\(cached.aurisFormat ?? "none")', hash '\(cached.aurisHash ?? "none")' "
                        + "at \(path) — discarding"
                )
                return nil
            }
        }
        FileLog.shared.addMessage(
            "FingerprintMappingCache: loaded \(cached.entries.count) cached mappings from \(path)"
        )
        return LoadResult(
            entries: cached.entries.map {
                FingerprintTimingManager.TimeMappingEntry(
                    playbackTime: $0.p,
                    referenceTime: $0.r,
                    score: $0.s
                )
            },
            referenceDuration: cached.referenceDuration
        )
    }

    static func save(
        _ entries: [FingerprintTimingManager.TimeMappingEntry],
        audioFilePath: String,
        referenceFilePath: String,
        referenceData: Data,
        referenceDuration: Double,
        aurisReference: AurisReferenceIdentity? = nil
    ) {
        guard let last = entries.last,
              referenceDuration > 0,
              last.referenceTime / referenceDuration >= FingerprintConstants.fullCoverageThreshold else {
            return
        }
        guard let audioAttrs = fileAttributes(at: audioFilePath) else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: cannot stat audio at \(audioFilePath) — skipping save"
            )
            return
        }
        guard let refAttrs = fileAttributes(at: referenceFilePath) else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: cannot stat reference at \(referenceFilePath) — skipping save"
            )
            return
        }
        guard let audioContentHash = contentSampleHash(at: audioFilePath) else {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: cannot hash audio content at \(audioFilePath) — skipping save"
            )
            return
        }
        let path = mappingPath(forAudioFilePath: audioFilePath)
        let cached = CachedMapping(
            schemaVersion: FingerprintConstants.mappingCacheSchemaVersion,
            aurisFormat: aurisReference?.format,
            aurisHash: aurisReference?.hash,
            referenceHash: sha256(referenceData),
            referenceByteSize: refAttrs.size,
            referenceMTime: refAttrs.mtime,
            audioByteSize: audioAttrs.size,
            audioMTime: audioAttrs.mtime,
            audioContentHash: audioContentHash,
            referenceDuration: referenceDuration,
            entries: entries.map {
                CachedMapping.CachedEntry(p: $0.playbackTime, r: $0.referenceTime, s: $0.score)
            }
        )
        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            FileLog.shared.addMessage(
                "FingerprintMappingCache: saved \(entries.count) mappings to \(path)"
            )
        } catch {
            FileLog.shared.addMessage(
                "FingerprintMappingCache: failed to save to \(path) — \(error.localizedDescription)"
            )
        }
    }

    static func mappingPath(forAudioFilePath audioPath: String) -> String {
        (audioPath as NSString).deletingPathExtension + ".map.fp.json"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileAttributes(at path: String) -> (size: UInt64, mtime: Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        guard size > 0, mtime > 0 else { return nil }
        return (size, mtime)
    }

    private static let contentSampleSize = 65_536

    private static func contentSampleHash(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: contentSampleSize)
        guard !data.isEmpty else { return nil }
        return sha256(data)
    }
}
