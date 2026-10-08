import Foundation
import PocketCastsUtils

/// Item 5 (iOS half), slice 3 — fires the optional prefetch hint on playback
/// start, best effort.
///
/// Prefetch is an optimisation, never a requirement (`cloud-assistant.md`):
/// this hook observes `playbackStarted`, resolves the current episode, and hands
/// the request to `CloudPrefetchClient.schedulePrefetch`, which returns
/// immediately. Nothing here blocks playback, inspects the result, or retries.
final class CloudPrefetchHook {
    static let shared = CloudPrefetchHook()

    private let baseURLProvider: () -> String
    private let userIdProvider: () -> String
    private let currentEpisodeProvider: () -> (episodeId: String, podcastId: String?)?
    private let clientFactory: (String, String) -> CloudPrefetchClient
    /// Scheduling seam: production uses the client's fire-and-forget
    /// `schedulePrefetch`; tests record the request instead.
    private let scheduler: (CloudPrefetchClient, String, String?) -> Void
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private(set) var prefetchCount = 0

    init(
        baseURLProvider: @escaping () -> String = { CloudConfig.shared.baseUrl },
        userIdProvider: @escaping () -> String = { CloudIdentity.shared.userId },
        currentEpisodeProvider: @escaping () -> (episodeId: String, podcastId: String?)? = {
            guard let episode = PlaybackManager.shared.currentEpisode else { return nil }
            return (episode.uuid, episode.parentIdentifier())
        },
        clientFactory: @escaping (String, String) -> CloudPrefetchClient = {
            CloudPrefetchClient(baseURL: $0, userId: $1, tokenProvider: CloudTokenProviderRouter.provider())
        },
        scheduler: @escaping (CloudPrefetchClient, String, String?) -> Void = { client, episodeId, podcastId in
            client.schedulePrefetch(episodeId: episodeId, podcastId: podcastId)
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.baseURLProvider = baseURLProvider
        self.userIdProvider = userIdProvider
        self.currentEpisodeProvider = currentEpisodeProvider
        self.clientFactory = clientFactory
        self.scheduler = scheduler
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: Constants.Notifications.playbackStarted,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handlePlaybackStarted()
        }
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    /// Best effort: unconfigured cloud, no current episode, or an unknown
    /// identity all mean "skip", never "fail".
    func handlePlaybackStarted() {
        let baseURL = baseURLProvider()
        guard !baseURL.isEmpty else { return }
        let userId = userIdProvider()
        guard !userId.isEmpty, let episode = currentEpisodeProvider() else { return }
        prefetchCount += 1
        scheduler(clientFactory(baseURL, userId), episode.episodeId, episode.podcastId)
        FileLog.shared.addMessage(
            "[CloudPrefetch] hint scheduled for \(episode.episodeId) (best effort, no retry)"
        )
    }
}
