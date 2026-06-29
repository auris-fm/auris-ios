enum EarconId: String, CaseIterable, Equatable {
    case wakeWord = "wake_word"
    case success = "success"
    case nextEpisode = "next_episode"
    case confirmRequired = "confirm_required"
    case error = "error"
    case listeningStart = "listening_start"
}
