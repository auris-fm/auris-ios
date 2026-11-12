/// Identifies the consent, enrollment epoch and policy generation a recording was captured under.
/// The collector stamps every contribution with this; it is the only piece of the former capture
/// allowance that the capture path still needs.
struct VoiceSharingCaptureStamp: Equatable {
    let session: String?
    let epoch: String
    let policyGeneration: Int
}
