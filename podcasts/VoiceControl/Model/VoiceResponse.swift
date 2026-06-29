enum VoiceResponse: Equatable {
    case silent
    case earcon(EarconId)
    case spoken(String)
}
