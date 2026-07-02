import AVFoundation
import PocketCastsUtils

class NativeAudioCapture {
    let engine = AVAudioEngine()
    private let sampleRate = 16000.0
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        FileLog.shared.addMessage("[VoiceControl/Capture] Configuring audio session (playAndRecord, 16kHz, 20ms buffer)")
        try session.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth])
        try session.setMode(.spokenAudio)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setPreferredSampleRate(sampleRate)
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let converterFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw CaptureError.formatUnavailable }

        if inputFormat.sampleRate != sampleRate {
            guard let converter = AVAudioConverter(from: inputFormat, to: converterFormat) else {
                throw CaptureError.converterUnavailable
            }
            inputNode.installTap(onBus: 0, bufferSize: UInt32(sampleRate * 0.02), format: inputFormat) { [weak self] buffer, _ in
                let converted = self?.convert(buffer, with: converter, to: converterFormat) ?? []
                self?.onSamples?(converted)
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: UInt32(sampleRate * 0.02), format: converterFormat) { [weak self] buffer, _ in
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
                self?.onSamples?(samples)
            }
        }

        engine.prepare()
        try engine.start()
        FileLog.shared.addMessage("[VoiceControl/Capture] Audio engine started (input: \(inputFormat.sampleRate)Hz → \(sampleRate)Hz)")
    }

    func stop() {
        FileLog.shared.addMessage("[VoiceControl/Capture] Stopping audio engine")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> [Float] {
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 0.02))!
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, _ in buffer }
        return Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData?[0], count: Int(outputBuffer.frameLength)))
    }

    enum CaptureError: Error {
        case formatUnavailable
        case converterUnavailable
    }
}
