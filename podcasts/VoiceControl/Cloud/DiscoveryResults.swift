import Foundation

/// Item 5 (iOS half), slice 2 — the negotiated `search_results_v1` renderer.
///
/// Only clients that advertise `search_results_v1` receive `event: result`
/// (`docs/specs/cloud-assistant.md` → "Structured discovery result"). Rendering
/// never initiates playback: selection goes through `DiscoverySelectionHandler`,
/// which keeps provider IDs out of player commands and routes discovery-only
/// items through catalog resolution.

/// One bounded evidence item as sent to the client. Provider IDs are opaque
/// secondary identifiers — never player keys.
struct DiscoveryEvidenceItem: Equatable {
    let evidenceId: String
    let source: String
    let podcastId: String?
    let episodeId: String?
    let providerPodcastId: String?
    let providerEpisodeId: String?
    let title: String?
    let text: String?
    let speaker: String?
    let sourceUrl: String?
    let playable: Bool
    let seekable: Bool

    /// No Auris episode UUID: the item can be described/discovered but not played.
    var isDiscoveryOnly: Bool { episodeId == nil }

    /// Timed jumps require an identified, aligned episode.
    var canSeek: Bool { !isDiscoveryOnly && seekable }
}

struct DiscoveryResult: Equatable {
    enum Scope: String, Equatable {
        case library
        case global
        case currentEpisode = "current_episode"
    }

    static let supportedKind = "episode_results"

    let kind: String
    let scope: Scope
    let items: [DiscoveryEvidenceItem]
    let nextCursor: String?

    /// Parses a `result` event payload. Returns nil for unknown kinds (forward
    /// compatibility) and malformed payloads — the stream continues either way.
    static func parse(json: String) -> DiscoveryResult? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String,
              kind == supportedKind,
              let scopeRaw = object["scope"] as? String,
              let scope = Scope(rawValue: scopeRaw),
              let itemsRaw = object["items"] as? [[String: Any]]
        else {
            return nil
        }

        let items = itemsRaw.compactMap { item(from: $0) }
        return DiscoveryResult(
            kind: kind,
            scope: scope,
            items: items,
            nextCursor: object["next_cursor"] as? String
        )
    }

    private static func item(from object: [String: Any]) -> DiscoveryEvidenceItem? {
        guard let evidenceId = object["evidence_id"] as? String,
              let source = object["source"] as? String
        else {
            return nil
        }
        return DiscoveryEvidenceItem(
            evidenceId: evidenceId,
            source: source,
            podcastId: object["podcast_id"] as? String,
            episodeId: object["episode_id"] as? String,
            providerPodcastId: object["provider_podcast_id"] as? String,
            providerEpisodeId: object["provider_episode_id"] as? String,
            title: object["title"] as? String,
            text: object["text"] as? String,
            speaker: object["speaker"] as? String,
            sourceUrl: object["source_url"] as? String,
            playable: object["playable"] as? Bool ?? false,
            seekable: object["seekable"] as? Bool ?? false
        )
    }
}

/// Presentable model for the discovery result states the client must render.
struct DiscoveryResultsViewModel: Equatable {
    enum State: Equatable {
        /// One or more results.
        case items
        /// A successful no-match result.
        case noMatch
        /// The server reported the required evidence as unavailable
        /// (`retrieval_unavailable`) — distinct from "no match".
        case unavailable
    }

    struct Row: Equatable {
        let evidenceId: String
        let title: String?
        let subtitle: String?
        let isDiscoveryOnly: Bool
        let canSeek: Bool
        let episodeId: String?
        let providerPodcastId: String?
        let providerEpisodeId: String?
    }

    let state: State
    let scopeLabel: String
    let rows: [Row]

    init(result: DiscoveryResult) {
        state = result.items.isEmpty ? .noMatch : .items
        scopeLabel = Self.label(for: result.scope)
        rows = result.items.map { item in
            Row(
                evidenceId: item.evidenceId,
                title: item.title,
                subtitle: Self.subtitle(for: item),
                isDiscoveryOnly: item.isDiscoveryOnly,
                canSeek: item.canSeek,
                episodeId: item.episodeId,
                providerPodcastId: item.providerPodcastId,
                providerEpisodeId: item.providerEpisodeId
            )
        }
    }

    private init(state: State, scopeLabel: String, rows: [Row]) {
        self.state = state
        self.scopeLabel = scopeLabel
        self.rows = rows
    }

    static func unavailable(scope: DiscoveryResult.Scope) -> DiscoveryResultsViewModel {
        DiscoveryResultsViewModel(state: .unavailable, scopeLabel: label(for: scope), rows: [])
    }

    private static func label(for scope: DiscoveryResult.Scope) -> String {
        switch scope {
        case .library: return "Your library"
        case .global: return "Global"
        case .currentEpisode: return "This episode"
        }
    }

    private static func subtitle(for item: DiscoveryEvidenceItem) -> String? {
        switch (item.speaker, item.source) {
        case let (speaker?, _): return speaker
        case (nil, "web"): return "Web"
        default: return nil
        }
    }
}

/// What selecting a rendered row does. Never derived from provider IDs for
/// player commands: those require the Auris episode UUID.
enum DiscoverySelectionAction: Equatable {
    /// Play/seek the identified Auris episode (`seekable` false ⇒ no timed jump).
    case play(episodeId: String, seekable: Bool)
    /// Discovery-only: resolve through the catalog first.
    case resolveThroughCatalog(providerPodcastId: String?, providerEpisodeId: String?)
    /// Nothing actionable (missing identity).
    case unavailable
}

struct DiscoverySelectionHandler {
    func action(for row: DiscoveryResultsViewModel.Row) -> DiscoverySelectionAction {
        if let episodeId = row.episodeId {
            return .play(episodeId: episodeId, seekable: row.canSeek)
        }
        if row.providerPodcastId != nil || row.providerEpisodeId != nil {
            return .resolveThroughCatalog(
                providerPodcastId: row.providerPodcastId,
                providerEpisodeId: row.providerEpisodeId
            )
        }
        return .unavailable
    }
}

/// Renders structured discovery results in the UI. Injecting a presenter is what
/// makes advertising `search_results_v1` truthful.
protocol DiscoveryResultsPresenting: AnyObject {
    func present(_ model: DiscoveryResultsViewModel)
}
