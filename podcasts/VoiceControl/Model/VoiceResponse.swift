enum VoiceResponse: Equatable {
    case silent
    case earcon(EarconId)
    case spoken(String)
    case combined(earcon: EarconId, spokenText: String)
}
